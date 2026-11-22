import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'gateway.dart';
import 'model_preferences.dart';
import 'model_usage.dart';
import 'models.dart';

String compactModelName(String id) {
  final match = RegExp(
    r'^(?:openai/)?gpt-(\d+(?:\.\d+)?)-(sol|astra|terra)(?:-\d+k)?$',
    caseSensitive: false,
  ).firstMatch(id);
  if (match == null) return id;
  final variant = match[2]!.toLowerCase();
  return '${match[1]} ${variant[0].toUpperCase()}${variant.substring(1)}';
}

const _compactEffort = {
  'none': '关闭',
  'minimal': '最低',
  'low': '轻度',
  'medium': '中等',
  'high': '高强度',
  'xhigh': '极高',
  'max': '最大',
  'ultra': '超强',
};

String speedUnavailableReason(bool running) =>
    running ? '回复结束后可调整速度' : '模型生效后可调整速度';

typedef ModelActivity = ({bool running, bool modelPending});

class ModelControl extends StatelessWidget {
  const ModelControl({
    super.key,
    this.model,
    this.effort,
    this.speed,
    this.status,
    this.deferred = false,
    this.onPressed,
  });
  final String? model, effort, speed, status;
  final bool deferred;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).colorScheme;
    final title =
        (status == null ? null : context.tr(status!)) ??
        (model == null ? context.tr('选择模型') : compactModelName(model!));
    final detail = status != null
        ? null
        : [
            if (effort != null) _compactEffort[effort],
            if (speed == 'fast' || speed == 'ultrafast') speedLabels[speed],
          ].nonNulls.map(context.tr).join(' · ');
    return Tooltip(
      message: context.tr(deferred ? '设置将在下一轮回复时生效' : '模型与推理设置'),
      child: Semantics(
        label: model == null
            ? context.tr('选择模型')
            : context.strings.format("{model}模型设置", {"model": model!}),
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: palette.onSurface,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (detail?.isNotEmpty == true) ...[
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 1),
              Icon(
                deferred ? Icons.schedule_rounded : Icons.expand_more_rounded,
                size: 14,
                color: palette.onSurfaceVariant.withValues(alpha: .82),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef ModelPickerResult = ({
  ModelChoice? model,
  String? effort,
  String? speed,
  bool useProfileDefault,
  bool useProfileEffort,
});

class ModelPicker extends StatefulWidget {
  const ModelPicker({
    super.key,
    required this.gateway,
    required this.profile,
    this.runtime,
    this.selected,
    this.provider,
    this.effort,
    this.speed,
    this.activity,
    this.showReasoningFirst = false,
    this.hasDraftModel = false,
    this.hasDraftEffort = false,
  });
  final Gateway gateway;
  final String profile;
  final String? runtime, selected, provider, effort, speed;
  final ValueListenable<ModelActivity>? activity;
  final bool showReasoningFirst, hasDraftModel, hasDraftEffort;

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

enum _Section { models, reasoning }

enum _ModelAction { favorite, options }

class _ModelPickerState extends State<ModelPicker> {
  final search = TextEditingController();
  final scroll = ScrollController();
  ModelCatalog? catalog;
  late final preferences = ModelPreferences(widget.gateway, widget.profile);
  Map<String, ModelPreference> presets = {};
  ModelChoice? editing;
  late _Section section = widget.showReasoningFirst
      ? _Section.reasoning
      : _Section.models;
  bool loading = true, landscapeKeyboard = false;
  String query = '';
  String? error;
  Set<String>? sessionSpeedOptions;
  int speedOptionsRequest = 0;

  @override
  void initState() {
    super.initState();
    load(false);
    loadPreferences();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final compact =
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
    if (compact && !landscapeKeyboard) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && landscapeKeyboard && scroll.hasClients) scroll.jumpTo(0);
      });
    }
    landscapeKeyboard = compact;
  }

  @override
  void dispose() {
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> load(bool refresh) async {
    setState(() {
      loading = true;
      error = null;
    });
    if (widget.runtime case final runtime?
        when widget.activity?.value.modelPending != true) {
      unawaited(loadSpeedOptions(runtime));
    }
    try {
      final next = await ModelCatalog.load(
        widget.gateway,
        widget.profile,
        widget.runtime,
        refresh: refresh,
      );
      if (mounted) setState(() => catalog = next);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> loadSpeedOptions(String runtime) async {
    final request = ++speedOptionsRequest;
    try {
      final result = await widget.gateway.call('config.get', {
        'key': 'service_tier',
        'profile': widget.profile,
        'session_id': runtime,
      }, timeout: const Duration(seconds: 5));
      if (mounted &&
          request == speedOptionsRequest &&
          result['options'] is List) {
        setState(() {
          sessionSpeedOptions = (result['options'] as List)
              .map(normalizeModelSpeed)
              .nonNulls
              .toSet();
        });
      }
    } catch (error) {
      // The catalog remains usable when the session does not report tiers.
      if (error is! GatewayError && error is! TimeoutException) rethrow;
    }
  }

  ModelChoice? get current {
    final inventory = catalog;
    if (widget.selected == null) return inventory?.current;
    if (inventory == null) return null;
    final candidates = inventory.models.where(
      (model) => model.id == widget.selected,
    );
    final provider = widget.provider;
    if (provider?.isNotEmpty == true) {
      return candidates
          .where((model) => model.matches(widget.selected, provider))
          .firstOrNull;
    }
    if (inventory.current?.id == widget.selected) return inventory.current;
    return candidates.length == 1 ? candidates.first : null;
  }

  Future<void> loadPreferences() async {
    try {
      final saved = await preferences.read();
      if (mounted) setState(() => presets = saved);
    } catch (_) {
      // Model selection remains available if local storage is unavailable.
    }
  }

  ModelPreference preference(ModelChoice? model) => model == null
      ? noModelPreference
      : presets[ModelPreferences.keyFor(model)] ?? noModelPreference;

  Future<void> updatePreference(
    ModelChoice model,
    ModelPreference Function(ModelPreference) change,
  ) async {
    try {
      final next = await preferences.update(model, change);
      if (mounted) {
        setState(() => presets[ModelPreferences.keyFor(model)] = next);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('无法保存模型偏好'))));
      }
    }
  }

  bool isCurrent(ModelChoice model, ModelChoice? chosen) =>
      model.id == (chosen?.id ?? widget.selected) &&
      model.provider == (chosen?.provider ?? widget.provider);

  void modelAction(ModelChoice model, _ModelAction action) {
    if (action == _ModelAction.favorite) {
      updatePreference(
        model,
        (saved) => (
          favorite: !saved.favorite,
          effort: saved.effort,
          speed: saved.speed,
        ),
      );
      return;
    }
    selectSection(
      _Section.reasoning,
      model: isCurrent(model, current) ? null : model,
    );
  }

  void selectSection(_Section next, {ModelChoice? model}) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (scroll.hasClients) scroll.jumpTo(0);
    setState(() {
      editing = model;
      section = next;
    });
  }

  void pick({
    ModelChoice? model,
    String? effort,
    String? speed,
    bool useProfileDefault = false,
    bool useProfileEffort = false,
  }) {
    final saved = preference(model);
    Navigator.pop<ModelPickerResult>(context, (
      model: useProfileDefault ? catalog?.current : model,
      effort: model == null ? effort : model.supportedEffort(saved.effort),
      speed: model == null ? speed : model.supportedSpeed(saved.speed),
      useProfileDefault: useProfileDefault,
      useProfileEffort: useProfileEffort,
    ));
  }

  void setOption({String? effort, String? speed}) {
    final target = editing;
    if (target == null) {
      pick(effort: effort, speed: speed);
      return;
    }
    updatePreference(
      target,
      (saved) => (
        favorite: saved.favorite,
        effort: effort ?? saved.effort,
        speed: speed ?? saved.speed,
      ),
    );
  }

  bool matchesSearch(ModelChoice model, List<String> terms) {
    final keywords =
        '${model.id} ${compactModelName(model.id)} ${model.providerName} ${model.provider}'
            .toLowerCase();
    return terms.every(keywords.contains);
  }

  void submitSearch(String text) {
    final value = text.trim().toLowerCase();
    final models = catalog?.models;
    if (value.isEmpty || models == null) return;
    final terms = value.split(RegExp(r'\s+'));
    final match = models
        .where((model) => model.available && matchesSearch(model, terms))
        .take(2)
        .toList();
    if (match.length == 1) pick(model: match.single);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chosen = current;
    final configured = editing ?? chosen;
    final canReason = configured?.reasoning != false;
    final preset = preference(editing);
    final selectedSpeed =
        (editing == null ? widget.speed : preset.speed) ?? 'normal';
    final sessionOptions = editing == null ? sessionSpeedOptions : null;
    final offersFast =
        sessionOptions?.contains('fast') ?? configured?.fast == true;
    final offersUltrafast =
        sessionOptions?.contains('ultrafast') ?? configured?.ultrafast == true;
    final hasSpeed = offersFast || offersUltrafast || selectedSpeed != 'normal';
    final showReasoning =
        section == _Section.reasoning && (canReason || hasSpeed);
    final preferredHeight = showReasoning
        ? (canReason ? (hasSpeed ? 370.0 : 269.0) : 210.0) +
              (editing != null || widget.hasDraftEffort ? 54 : 0)
        : 585.0;
    final groups = <String, List<ModelChoice>>{};
    final favorites = <ModelChoice>[];
    final terms = query.split(RegExp(r'\s+'));
    for (final entry in catalog?.models ?? const <ModelChoice>[]) {
      if (!matchesSearch(entry, terms)) continue;
      if (preference(entry).favorite) {
        favorites.add(entry);
      } else {
        groups.putIfAbsent(entry.provider, () => []).add(entry);
      }
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 190),
              curve: Curves.easeOutCubic,
              height: math.min(
                preferredHeight,
                math.min(
                  box.maxHeight,
                  MediaQuery.sizeOf(context).height * .78,
                ),
              ),
              child: CustomScrollView(
                controller: scroll,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverList.list(
                    children: [
                      if (!landscapeKeyboard) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(22, 0, 12, 5),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  context.tr('模型设置'),
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -.5,
                                  ),
                                ),
                              ),
                              if (catalog?.codex == true)
                                IconButton(
                                  tooltip: context.tr("Codex 订阅额度"),
                                  onPressed: () =>
                                      Navigator.of(context).push<void>(
                                        MaterialPageRoute(
                                          builder: (_) => CodexUsagePage(
                                            gateway: widget.gateway,
                                            profile: widget.profile,
                                          ),
                                        ),
                                      ),
                                  icon: const Icon(
                                    Icons.insights_outlined,
                                    size: 20,
                                  ),
                                  color: colors.onSurfaceVariant,
                                ),
                              if (!showReasoning)
                                IconButton(
                                  tooltip: context.tr('刷新模型'),
                                  onPressed: loading ? null : () => load(true),
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 20,
                                  ),
                                  color: colors.onSurfaceVariant,
                                ),
                              IconButton(
                                tooltip: context.tr('关闭'),
                                onPressed: () => Navigator.pop(context),
                                icon: const Icon(Icons.close_rounded, size: 20),
                                color: colors.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                        if (canReason || hasSpeed)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: colors.outlineVariant,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  for (final item in _Section.values) ...[
                                    _PickerTab(
                                      active: section == item,
                                      label: item == _Section.models
                                          ? context.tr('模型')
                                          : context.tr('推理与速度'),
                                      onTap: () => selectSection(item),
                                    ),
                                    const SizedBox(width: 19),
                                  ],
                                ],
                              ),
                            ),
                          ),
                      ],
                      if (!showReasoning) ...[
                        Padding(
                          key: const ValueKey('model-search'),
                          padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                          child: TextField(
                            controller: search,
                            textInputAction: TextInputAction.search,
                            onSubmitted: submitSearch,
                            onChanged: (text) => setState(
                              () => query = text.trim().toLowerCase(),
                            ),
                            decoration: InputDecoration(
                              hintText: context.tr('搜索模型或提供商'),
                              isDense: true,
                              fillColor: Color.alphaBlend(
                                colors.onSurface.withValues(alpha: .045),
                                colors.surface,
                              ),
                              border: _searchBorder(),
                              enabledBorder: _searchBorder(),
                              focusedBorder: _searchBorder(
                                BorderSide(
                                  color: colors.primary.withValues(alpha: .55),
                                ),
                              ),
                              prefixIcon: const Icon(
                                Icons.search_rounded,
                                size: 20,
                              ),
                              suffixIcon: search.text.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: context.tr('清空搜索'),
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 17,
                                      ),
                                      onPressed: () {
                                        search.clear();
                                        setState(() => query = '');
                                      },
                                    ),
                            ),
                          ),
                        ),
                        if (widget.hasDraftModel && query.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            child: ListTile(
                              minTileHeight: 48,
                              leading: const Icon(
                                Icons.restart_alt_rounded,
                                size: 20,
                              ),
                              title: Text(context.tr('使用档案默认模型')),
                              onTap: () => pick(useProfileDefault: true),
                            ),
                          ),
                        if (loading)
                          const LinearProgressIndicator(minHeight: 2),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
                            child: Text(
                              context.tr(error!),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.error,
                                fontSize: 13,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                  if (!showReasoning)
                    if (groups.isEmpty && favorites.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: error != null
                            ? const SizedBox.shrink()
                            : Center(
                                child: Text(
                                  context.tr(loading ? '正在读取模型…' : '没有找到模型'),
                                  style: TextStyle(color: colors.onSurfaceVariant),
                                ),
                              ),
                      )
                    else
                      _groupedModels(groups, favorites, chosen)
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 5, 24, 16),
                      sliver: SliverList.list(
                        children: [
                          if (editing case final target?)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Text(
                                compactModelName(target.id),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          if (canReason)
                            _EffortSlider(
                              key: ValueKey(
                                configured == null
                                    ? null
                                    : ModelPreferences.keyFor(configured),
                              ),
                              selected: editing == null
                                  ? widget.effort
                                  : preset.effort,
                              canDisable:
                                  configured?.canDisableReasoning != false,
                              onApply: (effort) => setOption(effort: effort),
                            ),
                          if (hasSpeed) ...[
                            if (canReason) ...[
                              const SizedBox(height: 9),
                              Divider(height: 1, color: colors.outlineVariant),
                              const SizedBox(height: 15),
                            ],
                            _SpeedOptions(
                              offersFast: offersFast,
                              offersUltrafast: offersUltrafast,
                              selected: selectedSpeed,
                              activity: editing == null
                                  ? widget.activity
                                  : null,
                              onSelected: (speed) => setOption(speed: speed),
                            ),
                          ],
                          if (editing == null &&
                              widget.hasDraftEffort &&
                              canReason)
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: TextButton(
                                onPressed: () => pick(useProfileEffort: true),
                                child: Text(context.tr('使用档案默认推理')),
                              ),
                            ),
                          if (editing case final target?
                              when preset.effort != null ||
                                  preset.speed != null)
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: TextButton(
                                onPressed: () => updatePreference(
                                  target,
                                  (saved) => (
                                    favorite: saved.favorite,
                                    effort: null,
                                    speed: null,
                                  ),
                                ),
                                child: Text(context.tr('清除模型偏好')),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  OutlineInputBorder _searchBorder([BorderSide side = BorderSide.none]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(26),
        borderSide: side,
      );

  Widget _groupedModels(
    Map<String, List<ModelChoice>> groups,
    List<ModelChoice> favorites,
    ModelChoice? chosen,
  ) {
    final entries = [
      if (favorites.isNotEmpty) ...<Object>[context.tr('收藏'), ...favorites],
      for (final models in groups.values) ...<Object>[
        models.first.providerName,
        ...models,
      ],
    ];
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
      sliver: SliverList.builder(
        itemCount: entries.length,
        itemBuilder: (_, index) {
          final entry = entries[index];
          if (entry is String) return _PickerHeading(entry);
          final model = entry as ModelChoice;
          final saved = preference(model);
          return _ModelTile(
            key: ValueKey(ModelPreferences.keyFor(model)),
            model: model,
            selected: isCurrent(model, chosen),
            favorite: saved.favorite,
            showProvider: saved.favorite,
            onAction: (action) => modelAction(model, action),
            onTap: model.available ? () => pick(model: model) : null,
          );
        },
      ),
    );
  }
}

class _PickerTab extends StatelessWidget {
  const _PickerTab({
    required this.active,
    required this.label,
    required this.onTap,
  });
  final bool active;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: active,
      child: InkWell(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          constraints: const BoxConstraints(minHeight: 44, minWidth: 48),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? colors.onSurface : colors.onSurfaceVariant,
              fontSize: 14,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _EffortSlider extends StatefulWidget {
  const _EffortSlider({
    super.key,
    required this.selected,
    required this.canDisable,
    required this.onApply,
  });

  final String? selected;
  final bool canDisable;
  final ValueChanged<String> onApply;

  @override
  State<_EffortSlider> createState() => _EffortSliderState();
}

class _EffortSliderState extends State<_EffortSlider> {
  String? preview;

  @override
  void didUpdateWidget(covariant _EffortSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) preview = null;
  }

  String label(String effort) =>
      context.tr(_compactEffort[effort] ?? effortLabels[effort] ?? effort);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final levels = effortLabels.keys
        .where((level) => widget.canDisable || level != 'none')
        .toList();
    final selected = levels.contains(widget.selected) ? widget.selected : null;
    final changed = levels.contains(preview) ? preview : null;
    final current = changed ?? selected ?? 'medium';
    final value = levels.indexOf(current);
    final canApply = changed != null && changed != selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                context.tr('推理强度'),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Text(
                  changed == null && selected == null
                      ? context.tr('跟随默认')
                      : label(current),
                  style: TextStyle(
                    color: colors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 11,
            trackShape: const RoundedRectSliderTrackShape(),
            activeTrackColor: colors.primary,
            inactiveTrackColor: Color.alphaBlend(
              colors.onSurface.withValues(alpha: .10),
              colors.surface,
            ),
            activeTickMarkColor: colors.onPrimary.withValues(alpha: .70),
            inactiveTickMarkColor: colors.onSurfaceVariant.withValues(
              alpha: .42,
            ),
            tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 2),
            thumbColor: Colors.white,
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 12,
              elevation: 3,
              pressedElevation: 4,
            ),
            overlayColor: colors.primary.withValues(alpha: .10),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 19),
            showValueIndicator: ShowValueIndicator.never,
          ),
          child: Semantics(
            label: context.tr('推理强度'),
            child: Slider(
              value: value.toDouble(),
              min: 0,
              max: (levels.length - 1).toDouble(),
              divisions: levels.length - 1,
              semanticFormatterCallback: (value) =>
                  label(levels[value.round()]),
              onChanged: (value) =>
                  setState(() => preview = levels[value.round()]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label(levels.first),
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
              Text(
                label(levels.last),
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: canApply ? () => widget.onApply(changed) : null,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(56, 44),
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
            ),
            child: Text(context.tr('应用')),
          ),
        ),
      ],
    );
  }
}

class _SpeedOptions extends StatelessWidget {
  const _SpeedOptions({
    required this.offersFast,
    required this.offersUltrafast,
    required this.selected,
    required this.onSelected,
    required this.activity,
  });

  final bool offersFast, offersUltrafast;
  final String selected;
  final ValueChanged<String> onSelected;
  final ValueListenable<ModelActivity>? activity;

  @override
  Widget build(BuildContext context) {
    if (activity case final status?) {
      return ValueListenableBuilder(
        valueListenable: status,
        builder: (context, activity, _) => options(context, activity),
      );
    }
    return options(context, (running: false, modelPending: false));
  }

  Widget options(BuildContext context, ModelActivity activity) {
    final colors = Theme.of(context).colorScheme;
    final enabled = !activity.running && !activity.modelPending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('响应速度'),
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final entry in speedLabels.entries)
              if (entry.key == 'normal' ||
                  entry.key == selected ||
                  entry.key == 'fast' && offersFast ||
                  entry.key == 'ultrafast' && offersUltrafast)
                Semantics(
                  selected: selected == entry.key,
                  child: TextButton(
                    onPressed: enabled ? () => onSelected(entry.key) : null,
                    style: TextButton.styleFrom(
                      foregroundColor: selected == entry.key
                          ? colors.primary
                          : colors.onSurfaceVariant,
                      disabledForegroundColor: selected == entry.key
                          ? colors.primary
                          : colors.onSurfaceVariant.withValues(alpha: .55),
                      backgroundColor:
                          (selected == entry.key
                                  ? colors.primary
                                  : colors.onSurface)
                              .withValues(
                                alpha: selected == entry.key ? .09 : .045,
                              ),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      minimumSize: const Size(0, 44),
                    ),
                    child: Text(context.tr(entry.value)),
                  ),
                ),
            if (!enabled)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  context.tr(speedUnavailableReason(activity.running)),
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _PickerHeading extends StatelessWidget {
  const _PickerHeading(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(9, 15, 9, 4),
    child: Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    super.key,
    required this.model,
    required this.selected,
    required this.favorite,
    required this.showProvider,
    required this.onTap,
    required this.onAction,
  });
  final ModelChoice model;
  final bool selected, favorite, showProvider;
  final VoidCallback? onTap;
  final ValueChanged<_ModelAction> onAction;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final short = compactModelName(model.id);
    final caption = [
      if (short != model.id) model.id,
      if (showProvider) model.providerName,
      if (!model.available) context.tr('不可用'),
    ].join(' · ');
    return Semantics(
      selected: selected,
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: .07)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          enabled: onTap != null,
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 11),
          minTileHeight: 49,
          minVerticalPadding: 7,
          title: Text(
            short,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          subtitle: caption.isEmpty
              ? null
              : Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected)
                Icon(Icons.check_rounded, color: colors.primary, size: 19),
              PopupMenuButton<_ModelAction>(
                tooltip: context.strings.format("{short} 选项", {"short": short}),
                icon: Icon(
                  favorite ? Icons.star_rounded : Icons.more_horiz_rounded,
                  size: 20,
                  color: favorite ? colors.primary : colors.onSurfaceVariant,
                ),
                onSelected: onAction,
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: _ModelAction.favorite,
                    child: Text(context.tr(favorite ? '取消收藏' : '收藏模型')),
                  ),
                  if (model.reasoning != false || model.fast || model.ultrafast)
                    PopupMenuItem(
                      value: _ModelAction.options,
                      child: Text(context.tr('推理与速度')),
                    ),
                ],
              ),
            ],
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}
