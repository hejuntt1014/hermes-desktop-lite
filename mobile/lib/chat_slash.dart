part of 'chat.dart';

typedef _CommandReceiptTarget = ({
  String session,
  CommandReceipts journal,
  int? after,
});

extension _ChatSlash on _ChatPageState {
  void updateActivityScope() {
    final current = workActivity;
    final session = runtime;
    if (current?.service.session == session) return;
    current?.dispose();
    workActivity = session == null
        ? null
        : (SessionActivityMonitor(
            SessionActivityService(widget.gateway, widget.profile, session),
            storedSession: stored,
          )..watch(widget.keyboardActive));
  }

  Future<void> loadCommandReceipts() async {
    final session = transcriptSession;
    if (session == null) return;
    final revision = ++commandReceiptRead;
    try {
      final receipts = await CommandReceipts(
        widget.gateway,
        widget.profile,
        session,
      ).read();
      if (mounted &&
          revision == commandReceiptRead &&
          transcriptSession == session) {
        updateSlash(() => commandReceipts = receipts);
      }
    } catch (_) {
      // The message timeline remains available when local records cannot be read.
    }
  }

  Future<_CommandReceiptTarget?> commandReceiptTarget() async {
    if (!mounted) return null;
    final session = transcriptSession;
    if (session == null) return null;
    final gateway = widget.gateway;
    final profile = widget.profile;
    final journal = CommandReceipts(gateway, profile, session);
    final history = rows.reversed.where((row) => row.commandReceipt == null);
    var after = history.map((row) => row.rowId).nonNulls.firstOrNull;
    // Live events can arrive before their persistent history row IDs.
    if (history.firstOrNull case final last?
        when last.rowId == null && gateway.usable) {
      try {
        final page = await gateway.historyPage(profile, session, 0);
        after =
            displayRows(page.rows)
                .map((row) => row.rowId)
                .nonNulls
                .lastOrNull ??
            after;
      } catch (_) {
        // Use the last loaded history anchor.
      }
    }
    return (session: session, journal: journal, after: after);
  }

  Future<CommandReceipt> saveCommandReceipt(
    _CommandReceiptTarget? target,
    String command,
    String output,
  ) async {
    final receipt = CommandReceipt(command, output, after: target?.after);
    if (target == null || !mounted || transcriptSession != target.session) {
      return receipt;
    }
    try {
      await target.journal.append(receipt);
      if (mounted && transcriptSession == target.session) {
        await loadCommandReceipts();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('无法保存命令回执'))));
      }
    }
    return receipt;
  }

  Future<void> openSessionActivity() async {
    final sid = runtime;
    if (sid == null) {
      updateSlash(() => error = '会话连接后可查看活动');
      return;
    }
    draftFocus.unfocus();
    final activity = workActivity;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SessionActivityPage(
          service: SessionActivityService(widget.gateway, widget.profile, sid),
          title: displayTitle,
          monitor: activity,
        ),
      ),
    );
  }

  bool get hasWorkspace =>
      widget.id == null || runtime != null || workspaceDir?.isNotEmpty == true;

  bool get isDraftWorkspace =>
      widget.id == null && stored == null && runtime == null;

  bool get canChangeDirectory =>
      gatewayReady &&
      !busy &&
      !running &&
      !readOnly &&
      !queueDraining &&
      !hydrating &&
      pendingInteractions.isEmpty &&
      unconfirmedSend == null &&
      rewrite == null &&
      !followups.any((item) => item.request != null) &&
      (isDraftWorkspace || runtime != null && stored != null);

  Future<void> readDraftWorkspace() async {
    try {
      final saved = await workspaceDefaults.read();
      if (mounted && isDraftWorkspace && saved != null && saved.isNotEmpty) {
        updateSlash(() => workspaceDir = saved);
        if (gatewayReady) unawaited(restoreWorkspaceBranch(saved));
      }
    } catch (_) {
      // The profile default remains available when local preferences cannot be read.
    }
  }

  Future<Json?> readWorkspaceProject(String path) async {
    try {
      return await widget.gateway.call('config.get', {
        'key': 'project',
        'profile': widget.profile,
        'cwd': path,
      }, timeout: const Duration(seconds: 5));
    } catch (_) {
      // Browsing the chosen directory works without Git metadata.
      return null;
    }
  }

  Future<void> restoreWorkspaceBranch(String path) async {
    final link = linkRevision;
    final project = await readWorkspaceProject(path);
    if (mounted &&
        isDraftWorkspace &&
        workspaceBranch == null &&
        linkRevision == link &&
        workspaceDir == path) {
      updateSlash(
        () => workspaceBranch = workspaceBranchName(project?['branch']),
      );
    }
  }

  Future<String?> changeWorkDirectory(String? target) async {
    if (!mounted || !canChangeDirectory) {
      throw GatewayError('会话空闲并连接后可更改工作目录');
    }
    final editingDraft = isDraftWorkspace;
    final activeRuntime = runtime;
    final activeStored = stored;
    final controls = modelControls;
    final link = linkRevision;
    bool stillAttached() =>
        mounted &&
        gatewayReady &&
        linkRevision == link &&
        !running &&
        runtime == activeRuntime &&
        stored == activeStored &&
        identical(modelControls, controls);
    updateSlash(() => busy = true);
    try {
      if (editingDraft) {
        final project = target == null
            ? null
            : await readWorkspaceProject(target);
        final normalized = project?['cwd'];
        final path = normalized is String && normalized.isNotEmpty
            ? normalized
            : target;
        if (!stillAttached() || !isDraftWorkspace) {
          throw GatewayError('当前会话已切换');
        }
        await workspaceDefaults.write(path);
        if (mounted) {
          updateSlash(() {
            workspaceDir = path;
            workspaceBranch = workspaceBranchName(project?['branch']);
          });
        }
        return path;
      }
      if (target == null) throw GatewayError('请选择工作目录');
      final result =
          await WorkspaceDirectoryChange(
            widget.gateway,
            widget.profile,
            activeStored!,
            activeRuntime!,
          ).change(
            target,
            baseline: controls?.version,
            stillAttached: stillAttached,
          );
      if (!stillAttached()) {
        throw GatewayError('当前会话已切换');
      }
      final prior = modelControls?.version;
      final confirmed = result.version;
      if (prior != null &&
          confirmed != null &&
          (prior.generation > confirmed.generation ||
              prior.generation == confirmed.generation &&
                  prior.revision > confirmed.revision)) {
        return workspaceDir;
      }
      updateSlash(() {
        if (result.path != workspaceDir || result.branch != null) {
          workspaceBranch = result.branch;
        }
        workspaceDir = result.path;
        if (confirmed != null) modelControls?.version = confirmed;
      });
      return result.path;
    } finally {
      if (mounted) {
        updateSlash(() => busy = false);
        scheduleFollowupDrain();
      }
    }
  }

  Future<void> openWorkspace({
    WorkspaceSection section = WorkspaceSection.files,
  }) async {
    final filesOnly = !hasWorkspace;
    if (filesOnly &&
        (section != WorkspaceSection.conversationFiles ||
            transcriptSession == null)) {
      throw GatewayError('会话工作区暂不可用');
    }
    if (isDraftWorkspace) await draftWorkspace;
    if (!mounted) return;
    draftFocus.unfocus();
    final scope = WorkspaceScope(
      widget.gateway,
      widget.profile,
      session: stored ?? widget.id,
      cwd: workspaceDir,
    );
    final selected = await Navigator.push<Object>(
      context,
      MaterialPageRoute(
        builder: (page) => WorkspacePage(
          scope: scope,
          section: section,
          filesOnly: filesOnly,
          browserPosition: widget.composerTab?.workspacePosition,
          reviewPosition: widget.composerTab?.reviewPosition,
          onReviewPosition: (position) {
            if (mounted && (stored ?? widget.id) == scope.session) {
              widget.onWorkspaceReviewPosition?.call(position);
            }
          },
          onBrowserPosition: (position) {
            if (mounted && (stored ?? widget.id) == scope.session) {
              widget.onWorkspacePosition?.call(position);
            }
          },
          title: displayTitle,
          onDirectory: canChangeDirectory ? changeWorkDirectory : null,
          allowDefault: isDraftWorkspace,
          onRevealMessage: (address) => Navigator.pop(page, address),
          onReference: canReference
              ? (entry) => Navigator.pop(page, entry)
              : null,
        ),
      ),
    );
    if (!mounted) return;
    if (selected case final WorkspaceEntry entry) {
      await insertWorkspaceReference(entry);
    } else {
      restoreChatKeyboard();
      if (selected case final MessageAddress address) {
        await revealReadingMessage(address);
      }
    }
  }

  Future<void> openChatFile(
    String path,
    String? fragment,
    String? session,
  ) async {
    draftFocus.unfocus();
    WorkspaceEntry? selected;
    await openWorkspaceFile(
      context,
      WorkspaceScope(
        widget.gateway,
        widget.profile,
        session: session,
        cwd: workspaceDir,
      ),
      WorkspaceEntry(
        workspaceName(path),
        path,
        directory: path.endsWith('/') || path.endsWith('\\'),
      ),
      fragment: fragment,
      onReference: canReference ? (entry) => selected = entry : null,
    );
    if (!mounted) return;
    if (selected case final WorkspaceEntry entry) {
      await insertWorkspaceReference(entry);
    } else {
      restoreChatKeyboard();
    }
  }

  Future<void> insertWorkspaceReference(WorkspaceEntry entry) async {
    if (!widget.keyboardActive ||
        !canReference ||
        !references.appendEntry(entry)) {
      restoreChatKeyboard();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.tr('无法引用此路径'))));
      return;
    }
    try {
      await widget.onFlushDraft?.call();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('无法保存草稿'))));
      }
    }
    if (mounted &&
        widget.keyboardActive &&
        ModalRoute.isCurrentOf(context) != false) {
      draftFocus.requestFocus();
    }
  }

  SlashService get slash =>
      SlashService(widget.gateway, widget.profile, runtime);

  void changeDraft(String text) {
    draft.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> openCommands() async {
    final before = draft.text;
    final isCommand = before.trim() == '/' || parseSlashInput(before) != null;
    draftFocus.unfocus();
    final chosen = await pickSlashCommand(
      context,
      slash,
      initial: isCommand ? before : '',
    );
    if (!mounted || chosen == null || draft.text != before) return;
    if (!isCommand && before.trim().isNotEmpty) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(context.tr('替换当前草稿？')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(context.tr('保留草稿')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(context.tr('替换')),
            ),
          ],
        ),
      );
      if (!mounted || replace != true || draft.text != before) return;
    }
    changeDraft(chosen);
    if (chosen.endsWith(' ')) draftFocus.requestFocus();
  }

  Future<SlashCatalog> loadSlashCatalog() async {
    final scoped = slash;
    final revision = slashRevision;
    final cached = slashCatalog;
    if (cached != null && slashRuntime == scoped.runtime) return cached;
    final loaded = await scoped.catalog();
    if (mounted && scoped.runtime == runtime && slashRevision == revision) {
      slashCatalog = loaded;
      slashRuntime = scoped.runtime;
    }
    return loaded;
  }

  Future<SlashCommand?> resolveSlash(SlashInput input) async {
    final local = localSlashCommands
        .where((item) => item.name == input.name)
        .firstOrNull;
    if (local != null) return local;
    final diagnostic = diagnosticSlash(input.name);
    if (diagnostic != null) return diagnostic;
    try {
      return (await loadSlashCatalog()).entries[input.name];
    } on GatewayError catch (error) {
      if (error.code != -32601) rethrow;
      return null;
    }
  }

  Future<QueuedSkill?> skillForQueue(
    String text, {
    QueuedSkill? previous,
  }) async {
    final input = parseSlashInput(text);
    if (input == null) return null;
    if (previous?.name == input.name) return QueuedSkill(input.name, input.arg);
    final command = await resolveSlash(input);
    return command?.skill == true ? QueuedSkill(input.name, input.arg) : null;
  }

  Future<({String? prompt, String? display})?> prepareSlash(
    String original,
  ) async {
    final input = parseSlashInput(original);
    if (input == null) {
      if (original.trim() != '/') return null;
      await openCommands();
      return (prompt: null, display: null);
    }
    updateSlash(() {
      slashPending = true;
      error = null;
    });
    try {
      final command = await resolveSlash(input);
      if (!mounted) return (prompt: null, display: null);
      if (command == null) return null;
      void accept() {
        if (mounted && draft.text == original) draft.clear();
      }

      if (command.route == SlashRoute.local) {
        if (!validLocalArgument(command.name, input.arg)) {
          throw GatewayError('参数无效，请在命令菜单中选择');
        }
        final result = await runLocalSlash(command.name, input.arg);
        if (result) accept();
        return (prompt: null, display: null);
      }
      if (command.route == SlashRoute.extension &&
          runtime == null &&
          widget.id == null) {
        await open();
        if (!mounted) return (prompt: null, display: null);
      }
      final target = command.route == SlashRoute.diagnostic
          ? await commandReceiptTarget()
          : null;
      if (!mounted) return (prompt: null, display: null);
      final SlashDirective directive;
      try {
        directive = await slash.run(command, input.arg);
      } on GatewayError catch (failure) {
        if (failure.code != null) {
          await saveCommandReceipt(
            target ?? await commandReceiptTarget(),
            command.name,
            failure.message,
          );
        }
        rethrow;
      }
      if (!mounted) return (prompt: null, display: null);
      switch (directive.type) {
        case 'skill':
        case 'send':
          return directive.promptFor(original);
        case 'alias':
        case 'prefill':
          final text = directive.type == 'alias'
              ? directive.target
              : directive.message;
          if (text.trim().isEmpty) throw GatewayError('网关未返回命令内容');
          if (draft.text == original) {
            changeDraft(text);
            draftFocus.requestFocus();
          }
        case 'exec':
        case 'plugin':
        case null:
          final receipt = await saveCommandReceipt(
            target ?? await commandReceiptTarget(),
            command.name,
            directive.output,
          );
          if (!mounted) return (prompt: null, display: null);
          accept();
          draftFocus.unfocus();
          await showSlashResult(context, command.name, receipt.output);
          restoreChatKeyboard();
        default:
          throw GatewayError('网关返回了无法识别的命令结果');
      }
    } catch (e) {
      if (mounted) updateSlash(() => error = e.toString());
    } finally {
      if (mounted) updateSlash(() => slashPending = false);
    }
    return (prompt: null, display: null);
  }

  Future<bool> runLocalSlash(String name, String arg) async {
    final id = transcriptSession;
    if (id == null &&
        {'find', 'branch', 'title', 'save', 'stop', 'copy'}.contains(name)) {
      throw GatewayError('请先打开会话');
    }
    switch (name) {
      case 'new':
        widget.onNew();
      case 'resume':
        draft.clear();
        await openQuickAccess(query: arg);
      case 'find':
        await exploreTranscript();
      case 'agents':
        await openSessionActivity();
      case 'branch':
        await branch();
        if (mounted && error != null) return false;
      case 'title':
        final title = arg.isEmpty ? await requestTitle() : arg;
        if (!mounted || title == null || title.isEmpty) return false;
        if (title != displayTitle) {
          await widget.gateway.patchSession(id!, widget.profile, {
            'title': title,
          });
          if (!mounted) return false;
          updateSlash(() => renamedTitle = title);
          widget.onRenamed?.call(id, title);
        }
      case 'save':
        final saved = await exportConversation(
          context,
          widget.gateway,
          id: id!,
          profile: widget.profile,
          title: displayTitle,
          format: arg.toLowerCase() == 'json'
              ? SessionExportFormat.json
              : SessionExportFormat.markdown,
          stillOpen: () => mounted,
        );
        if (saved && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(context.tr('会话已导出'))));
        }
      case 'stop':
        await stop();
      case 'model':
        return pickModel(receiptCommand: name);
      case 'reasoning':
        final value = arg.toLowerCase();
        if (value.isEmpty) {
          return pickModel(reasoning: true, receiptCommand: name);
        } else if (effortLabels.containsKey(value)) {
          return applyModelSetting(reasoning: value, receiptCommand: name);
        } else {
          final target = await commandReceiptTarget();
          if (!mounted) return false;
          final reply = await widget.gateway.call('config.set', {
            ...slash.scope,
            'key': 'reasoning',
            'value': value,
          });
          if (!mounted) return false;
          final applied = reply['value'] as String? ?? value;
          profileReasoning.apply(applied);
          await saveCommandReceipt(
            target,
            name,
            context.strings.format('思考显示 {value}', {'value': applied}),
          );
          if (switch ((applied, appearance.reasoning)) {
            ('show' || 'on', ReasoningVisibility.hidden) ||
            ('hide' || 'off', ReasoningVisibility.visible) => true,
            _ => false,
          }) {
            await appearance.setReasoningVisibility(
              ReasoningVisibility.gateway,
            );
          }
        }
      case 'cron':
        await widget.onCron?.call();
      case 'files':
        await openWorkspace();
      case 'review':
        await openWorkspace(section: WorkspaceSection.review);
      case 'copy':
        final latest = live.value.isNotEmpty
            ? live.value
            : rows.reversed
                  .where(
                    (row) =>
                        !row.user &&
                        row.activity == null &&
                        row.commandReceipt == null &&
                        row.backgroundNotice == null,
                  )
                  .firstOrNull
                  ?.body;
        if (latest == null || latest.trim().isEmpty) {
          throw GatewayError('暂无可复制的回复');
        }
        await Clipboard.setData(ClipboardData(text: latest));
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(context.tr('已复制回复'))));
        }
      case 'version':
        final version = widget.gateway.version;
        final output = version == null
            ? context.tr('网关版本未知')
            : context.strings.format('Hermes 网关 {value}', {'value': version});
        final target = await commandReceiptTarget();
        final receipt = await saveCommandReceipt(target, name, output);
        if (!mounted) return false;
        await showSlashResult(context, name, receipt.output);
        restoreChatKeyboard();
      case 'help':
        draft.clear();
        await openQuickAccess();
      case 'settings':
        await openMobileSettings();
      case 'commands':
        draft.clear();
        await openCommands();
    }
    return true;
  }

  Future<String?> requestTitle() async {
    var title = displayTitle;
    return showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.tr('重命名会话')),
        content: TextFormField(
          autofocus: true,
          initialValue: title,
          decoration: InputDecoration(labelText: context.tr('会话标题')),
          onChanged: (value) => title = value,
          onFieldSubmitted: (value) => Navigator.pop(dialog, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(context.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, title.trim()),
            child: Text(context.tr('保存')),
          ),
        ],
      ),
    );
  }
}
