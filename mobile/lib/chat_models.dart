part of 'chat.dart';

String _modelConfirmationText(BuildContext context, Json result) {
  final warnings = result['warnings'];
  final target = result['target_model'];
  if (warnings is List && target is String && target.isNotEmpty) {
    final paragraphs = <String>[];
    for (final warning in warnings.whereType<Json>()) {
      final message = warning['message'];
      if (message is! String || message.trim().isEmpty) continue;
      final tokens = warning['kind'] == 'context_cache'
          ? RegExp(r'~([\d,]+)\s+tokens').firstMatch(message)?.group(1)
          : null;
      paragraphs.add(
        tokens == null
            ? message.trim()
            : context.strings.format(
                '此会话约有 {tokens} 个 token。切换到 {model} 后，下一次回复会重新读取完整上下文，无法复用已有的缓存，可能产生额外输入费用。',
                {'tokens': tokens, 'model': target},
              ),
      );
    }
    if (paragraphs.isNotEmpty) return paragraphs.join('\n\n');
  }
  return [result['confirm_message'], result['warning']]
      .whereType<String>()
      .map((value) => value.trim())
      .firstWhere(
        (value) => value.isNotEmpty,
        orElse: () => context.tr('网关要求确认这次模型切换。'),
      );
}

extension _ChatModels on _ChatPageState {
  bool get canChangeModel =>
      gatewayReady &&
      !busy &&
      !hydrating &&
      !readOnly &&
      (runtime != null
          ? modelControls?.runtime == runtime && modelControls?.stored == stored
          : stored == null && widget.id == null);

  bool get canChangeSpeed => !running && deferredModel == null;

  void updateSessionModelSettings(Json info) {
    final committed = info['committed_model'];
    final model = committed ?? info['model'];
    final provider = info['provider'] as String?;
    final matchesDeferred =
        model is String && deferredModel?.matches(model, provider) == true;
    // Legacy session.info can advertise the pending pick at the end of the old turn.
    if (!matchesDeferred || deferredModelTurn == null || committed is String) {
      if (model is String) updateContextModel(model);
      currentProvider = provider ?? currentProvider;
      if (matchesDeferred) deferredModel = null;
    }
    effort = info['reasoning_effort'] as String? ?? effort;
    speed = normalizeModelSpeed(info['service_tier']) ?? speed;
    if (deferredEffort == effort) deferredEffort = null;
  }

  bool sameModelAttachment(SessionModelControls? controls, int link) =>
      mounted &&
      canChangeModel &&
      linkRevision == link &&
      identical(controls, modelControls);

  bool validateModelSelection(SessionModelControls? controls, int link) {
    if (sameModelAttachment(controls, link)) return true;
    if (mounted && widget.gateway.usable) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.tr('会话已更新，请重新选择模型'))));
    }
    return false;
  }

  void restoreDraftModel() {
    if (widget.id != null) return;
    final wire = widget.draftModel;
    if (wire == null) return;
    effort = wire['effort'] as String?;
    speed = normalizeModelSpeed(wire['speed']);
    final id = wire['model'];
    final provider = wire['provider'];
    if (id is String && provider is String) {
      pickedModel = ModelChoice(id, provider);
      currentModel = id;
      currentProvider = provider;
    }
  }

  void saveDraftModel() => widget.onDraftModel?.call({
    'model': ?pickedModel?.id,
    'provider': ?pickedModel?.provider,
    'effort': ?effort,
    'speed': ?speed,
  });

  Future<void> rememberModelOptions(String? reasoning, String? tier) async {
    final model = currentModel;
    final provider = currentProvider;
    if (model == null ||
        provider == null ||
        provider.isEmpty ||
        (reasoning == null && tier == null)) {
      return;
    }
    final known = pickedModel;
    final key = known != null && known.matches(model, provider)
        ? known
        : ModelChoice(model, provider);
    try {
      await modelPreferences.update(
        key,
        (saved) => (
          favorite: saved.favorite,
          effort: reasoning ?? saved.effort,
          speed: tier ?? saved.speed,
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('无法保存模型偏好'))));
      }
    }
  }

  Future<void> applyReadyModelPreset() async {
    final preset = pendingModelPreset;
    if (preset == null ||
        !mounted ||
        !canChangeModel ||
        !canChangeSpeed ||
        opening ||
        modelStatus != null ||
        queueDraining ||
        unconfirmedSend != null ||
        applyingModelPreset ||
        !preset.model.matches(currentModel, currentProvider)) {
      return;
    }
    applyingModelPreset = true;
    pendingModelPreset = null;
    final controls = modelControls;
    final link = linkRevision;
    try {
      if (preset.effort != null) {
        await applyModelSetting(reasoning: preset.effort, fromPreset: true);
      }
      if (sameModelAttachment(controls, link) &&
          preset.speed != null &&
          preset.model.matches(currentModel, currentProvider)) {
        await applyModelSetting(tier: preset.speed, fromPreset: true);
      }
    } finally {
      applyingModelPreset = false;
      scheduleFollowupDrain();
    }
  }

  Future<bool> pickModel({
    bool reasoning = false,
    String? receiptCommand,
  }) async {
    if (!canChangeModel || modelStatus != null) return false;
    final controls = modelControls;
    final link = linkRevision;
    FocusManager.instance.primaryFocus?.unfocus();
    final selected = await showModalBottomSheet<ModelPickerResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      barrierColor: Colors.black.withValues(alpha: .26),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (_) => ModelPicker(
        gateway: widget.gateway,
        profile: widget.profile,
        runtime: runtime,
        selected: deferredModel?.id ?? currentModel,
        provider: deferredModel?.provider ?? currentProvider,
        effort: deferredEffort ?? effort,
        speed: speed,
        activity: modelActivity,
        showReasoningFirst: reasoning,
        hasDraftModel: runtime == null && pickedModel != null,
        hasDraftEffort: runtime == null && effort != null,
      ),
    );
    if (selected == null || !validateModelSelection(controls, link)) {
      return false;
    }
    if (selected.useProfileDefault && runtime == null) {
      updateSlash(() {
        pickedModel = null;
        currentModel = selected.model?.id;
        currentProvider = selected.model?.provider;
        speed = null;
      });
      saveDraftModel();
      return true;
    }
    if (selected.useProfileEffort && runtime == null) {
      updateSlash(() => effort = null);
      saveDraftModel();
      return true;
    }
    return applyModelSetting(
      model: selected.model,
      reasoning: selected.effort,
      tier: selected.speed,
      receiptCommand: receiptCommand,
    );
  }

  Future<bool> applyModelSetting({
    ModelChoice? model,
    String? reasoning,
    String? tier,
    bool fromPreset = false,
    String? receiptCommand,
  }) async {
    if (!mounted || !canChangeModel || modelStatus != null) return false;
    if (model == null && tier != null && !canChangeSpeed) {
      if (!fromPreset) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr(speedUnavailableReason(running)))),
        );
      }
      return false;
    }
    if (model != null) pendingModelPreset = null;
    final controls = modelControls;
    if (controls == null) {
      updateSlash(() {
        if (model != null) {
          final changed =
              pickedModel?.id != model.id ||
              pickedModel?.provider != model.provider;
          pickedModel = model;
          currentModel = model.id;
          currentProvider = model.provider;
          if (changed) {
            effort = reasoning;
            speed = tier;
          }
        } else {
          if (reasoning != null) effort = reasoning;
          if (tier != null) speed = tier;
        }
      });
      saveDraftModel();
      if (model == null && !fromPreset) {
        await rememberModelOptions(reasoning, tier);
      }
      return true;
    }
    final bundledEffort = model != null && widget.gateway.canonical;
    final afterModelEffort = bundledEffort ? null : reasoning;
    final link = linkRevision;
    var completedAtPick = completedTurns;
    bool stillAttached() => sameModelAttachment(controls, link);
    final pending = pendingModelPreset;
    if (pending != null && model == null && !fromPreset) {
      pendingModelPreset = (
        model: pending.model,
        effort: reasoning == null ? pending.effort : null,
        speed: tier == null ? pending.speed : null,
      );
    }
    updateSlash(() => modelStatus = model == null ? '正在应用设置…' : '正在检查模型…');
    try {
      var result = await controls.change(
        model: model,
        effort: reasoning,
        speed: model == null ? tier : null,
        stillAttached: stillAttached,
      );
      if (!mounted || !stillAttached()) return false;
      if (modelConfirmationRequired(result)) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: Text(context.tr('确认切换模型')),
            content: Text(_modelConfirmationText(context, result)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(context.tr('取消')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(context.tr('继续')),
              ),
            ],
          ),
        );
        if (ok != true || !validateModelSelection(controls, link)) return false;
        if (widget.gateway.canonical &&
            (result['confirm'] as String?)?.isNotEmpty != true) {
          throw GatewayError('网关未提供切换确认凭据');
        }
        updateSlash(() => modelStatus = '正在切换模型…');
        completedAtPick = completedTurns;
        result = await controls.change(
          model: model,
          effort: reasoning,
          speed: model == null ? tier : null,
          confirmation: result['confirm'] as String?,
          confirmed: true,
          stillAttached: stillAttached,
        );
        if (!mounted || !stillAttached()) return false;
      }
      if (modelConfirmationRequired(result)) {
        throw GatewayError('确认已失效，请重新选择模型');
      }
      if (modelVersion(result) case final receipt?
          when controls.isOlderVersion(receipt)) {
        return true;
      }
      final deferred =
          result['deferred'] == true || result['status'] == 'deferred';
      final reportedEffort =
          result['effort'] ??
          (model == null && reasoning != null && tier == null
              ? result['value']
              : null);
      final acceptedEffort =
          reportedEffort is String && reportedEffort.isNotEmpty
          ? reportedEffort
          : model == null
          ? reasoning
          : null;
      final reportedModel = result['model'] ?? result['value'];
      final appliedModel = reportedModel is String && reportedModel.isNotEmpty
          ? reportedModel
          : null;
      final reportedProvider = result['provider'];
      final acceptedTier = tier == null
          ? null
          : normalizeModelSpeed(result['value']) ?? tier;
      if (model != null && (afterModelEffort != null || tier != null)) {
        pendingModelPreset = (
          model: model,
          effort: afterModelEffort,
          speed: tier,
        );
      }
      updateSlash(() {
        if (deferred) {
          if (model != null) {
            deferredModelTurn = completedTurns > completedAtPick && running
                ? null
                : completedAtPick;
            deferredModel = model;
          }
          if (reasoning != null && (model == null || bundledEffort)) {
            deferredEffort = acceptedEffort ?? reasoning;
          }
        } else {
          if (model != null && appliedModel != null) {
            deferredModel = null;
            updateContextModel(appliedModel);
            currentProvider = reportedProvider is String
                ? reportedProvider
                : appliedModel == model.id
                ? model.provider
                : currentProvider;
            pickedModel = model.matches(appliedModel, currentProvider)
                ? model
                : null;
          }
          if (reasoning != null && (model == null || bundledEffort)) {
            deferredEffort = null;
            if (acceptedEffort != null) effort = acceptedEffort;
          }
          if (model == null && tier != null) {
            speed = acceptedTier;
          }
        }
      });
      if (deferred) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('设置将在下一轮回复时生效'))));
      }
      if (model == null && !fromPreset) {
        await rememberModelOptions(
          reasoning == null ? null : acceptedEffort,
          tier == null ? null : acceptedTier,
        );
      }
      if (result['warning'] case final String warning
          when mounted && stillAttached() && warning.trim().isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr(warning))));
      }
      if (receiptCommand != null && mounted && stillAttached()) {
        final strings = context.strings;
        final output = [
          if (model != null)
            strings.format('模型 {value}', {'value': appliedModel ?? model.id}),
          if (reasoning != null)
            strings.format('推理强度 {value}', {
              'value': acceptedEffort ?? reasoning,
            }),
          if (acceptedTier != null)
            strings.format('响应速度 {value}', {'value': acceptedTier}),
          if (deferred) strings.text('设置将在下一轮回复时生效'),
        ].join('\n');
        final target = await commandReceiptTarget();
        if (!stillAttached()) return false;
        await saveCommandReceipt(target, receiptCommand, output);
      }
      return true;
    } catch (e) {
      if (mounted && stillAttached()) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr(e.toString()))));
      }
      return false;
    } finally {
      if (mounted) {
        updateSlash(() => modelStatus = null);
        unawaited(applyReadyModelPreset());
        scheduleFollowupDrain();
        if (model != null && contextMeter.value == null) {
          unawaited(refreshContextUsage());
        }
      }
    }
  }
}
