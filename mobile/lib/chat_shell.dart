part of 'chat.dart';

extension _ChatContinuation on _ChatPageState {
  Future<void> copyDraftAndContinue() async {
    final copy = widget.onNewWithDraft;
    if (copy == null || copyingDraft || composerBusy) return;
    updateSlash(() => copyingDraft = true);
    try {
      await copy();
    } catch (_) {
      if (mounted && widget.keyboardActive) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('无法复制草稿'))));
      }
    } finally {
      if (mounted) updateSlash(() => copyingDraft = false);
    }
  }

  Widget buildConversationError(String message, ColorScheme colors) {
    final text = Text(
      context.tr(message),
      style: TextStyle(color: colors.error),
    );
    if (!readOnly) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: GlassSurface(
          radius: 18,
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
          child: Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 18, color: colors.error),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  context.tr(message),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.error,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ),
              if (runtime == null && !busy)
                IconButton(
                  tooltip: context.tr('重新加载会话'),
                  onPressed: open,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          text,
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: draft,
              builder: (context, value, _) {
                final hasDraft =
                    widget.onNewWithDraft != null &&
                    (value.text.isNotEmpty ||
                        widget.composerTab?.attachments.isNotEmpty == true);
                return TextButton.icon(
                  onPressed: copyingDraft || composerBusy
                      ? null
                      : hasDraft
                      ? copyDraftAndContinue
                      : widget.onNew,
                  icon: copyingDraft
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          hasDraft
                              ? Icons.edit_note_rounded
                              : Icons.add_rounded,
                          size: 19,
                        ),
                  label: Text(
                    context.tr(
                      copyingDraft
                          ? '正在复制草稿…'
                          : hasDraft
                          ? '带草稿新建'
                          : '新建会话',
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

enum _ChatMenu {
  quickAccess('快捷入口', Icons.search_rounded),
  workspace('工作区', Icons.folder_open_outlined),
  newChat('新建会话', Icons.add_rounded),
  rename('重命名会话', Icons.edit_outlined),
  export('导出会话', Icons.download_outlined),
  find('查找与定位', Icons.manage_search_rounded),
  conversationFiles('会话文件', Icons.attach_file_rounded),
  activity('会话活动', Icons.bolt_outlined),
  status('会话状态', Icons.data_usage_rounded),
  reload('重新加载会话', Icons.refresh_rounded),
  gateway('网关状态', Icons.monitor_heart_outlined),
  busyInput('忙时发送', Icons.pending_actions_outlined),
  voiceEngine('语音引擎', Icons.record_voice_over_outlined),
  wake('语音唤醒', Icons.hearing_outlined);

  const _ChatMenu(this.label, this.icon);
  final String label;
  final IconData icon;
}

extension _ChatSessionMenu on _ChatPageState {
  bool get hasConversationActions =>
      transcriptSession != null && widget.onConversationAction != null;

  void runConversationAction([SessionMenuAction? action]) {
    if (!mounted ||
        !widget.keyboardActive ||
        !canBrowseChat ||
        !hasConversationActions ||
        action?.requiresGateway == true && !gatewayReady) {
      return;
    }
    draftFocus.unfocus();
    widget.onConversationAction?.call(action);
  }

  List<GlassMenuItem<_ChatMenu>> chatMenuItems() {
    bool visible(_ChatMenu item) => switch (item) {
      _ChatMenu.workspace => hasWorkspace,
      _ChatMenu.rename || _ChatMenu.export => hasConversationActions,
      _ChatMenu.find ||
      _ChatMenu.conversationFiles ||
      _ChatMenu.reload => transcriptSession != null,
      _ChatMenu.activity => runtime != null,
      _ChatMenu.wake => widget.onWakeSettings != null,
      _ => true,
    };
    bool enabled(_ChatMenu item) => switch (item) {
      _ChatMenu.rename ||
      _ChatMenu.export ||
      _ChatMenu.reload ||
      _ChatMenu.busyInput => gatewayReady,
      _ChatMenu.voiceEngine || _ChatMenu.wake => gatewayReady && !voice.inCall,
      _ => true,
    };
    return [
      for (final item in _ChatMenu.values)
        if (visible(item))
          GlassMenuItem(
            value: item,
            icon: item.icon,
            label: context.tr(item.label),
            enabled: enabled(item),
            separated:
                item == _ChatMenu.newChat ||
                item == _ChatMenu.find ||
                item == _ChatMenu.gateway,
          ),
    ];
  }
}

extension _ChatQuickAccess on _ChatPageState {
  Future<void> openQuickAccess({
    String query = '',
    bool focusSearch = false,
  }) async {
    if (!mounted || quickAccessOpen || !canBrowseChat) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent == false) return;
    quickAccessOpen = true;
    draftFocus.unfocus();
    final QuickTarget? chosen;
    try {
      chosen = await Navigator.of(context).push<QuickTarget>(
        MaterialPageRoute(
          builder: (_) => QuickAccessPage(
            gateway: widget.gateway,
            profile: widget.profile,
            initialQuery: query,
            focusSearch: focusSearch,
            recent: widget.recent,
            openTabs: widget.openTabs,
            activeTabId: widget.composerTab?.id,
            actions: [
              QuickAction.newChat,
              if (widget.onReopenTab != null) QuickAction.reopenTab,
              switch (widget.libraryDocked) {
                true => QuickAction.hideSidebar,
                false => QuickAction.showSidebar,
                null => QuickAction.sidebar,
              },
              if (transcriptSession != null) QuickAction.find,
              if (hasConversationActions) QuickAction.manageConversation,
              if (hasConversationActions && gatewayReady) ...[
                QuickAction.renameConversation,
                QuickAction.exportConversation,
              ],
              if (transcriptSession != null) QuickAction.conversationFiles,
              if (hasWorkspace) ...[QuickAction.files, QuickAction.review],
              if (runtime != null) QuickAction.activity,
              if (gatewayReady) ...[QuickAction.status, QuickAction.busyInput],
              QuickAction.gatewayStatus,
              if (widget.onCron != null) QuickAction.cron,
              QuickAction.commands,
              QuickAction.settings,
            ],
          ),
        ),
      );
    } finally {
      quickAccessOpen = false;
      restoreChatKeyboard();
    }
    if (!mounted || chosen == null) return;
    switch (chosen) {
      case QuickTab(:final id):
        if (id != widget.composerTab?.id) widget.onSelectTab?.call(id);
      case QuickSession(:final row):
        final id = row['id'] ?? row['session_id'];
        if (id != null && id != widget.id && id != stored) widget.onOpen(row);
      case QuickBookmark(:final bookmark):
        await openTranscriptTarget(
          TranscriptTarget(
            bookmark.profile,
            bookmark.session,
            bookmark.title,
            bookmark.address,
          ),
        );
        restoreChatKeyboard();
      case QuickCommand(:final action):
        switch (action) {
          case QuickAction.newChat:
            widget.onNew();
          case QuickAction.reopenTab:
            widget.onReopenTab?.call();
          case QuickAction.sidebar ||
              QuickAction.showSidebar ||
              QuickAction.hideSidebar:
            widget.onLibrary();
          case QuickAction.find:
            await exploreTranscript();
          case QuickAction.manageConversation:
            runConversationAction();
          case QuickAction.renameConversation:
            runConversationAction(SessionMenuAction.rename);
          case QuickAction.exportConversation:
            runConversationAction(SessionMenuAction.export);
          case QuickAction.conversationFiles:
            await openWorkspace(section: WorkspaceSection.conversationFiles);
          case QuickAction.files:
            await openWorkspace();
          case QuickAction.review:
            await openWorkspace(section: WorkspaceSection.review);
          case QuickAction.activity:
            await openSessionActivity();
          case QuickAction.status:
            await openSessionStatus();
          case QuickAction.busyInput:
            await openBusyInputSettings();
          case QuickAction.gatewayStatus:
            await openGatewayStatus();
          case QuickAction.cron:
            await widget.onCron?.call();
          case QuickAction.commands:
            await openCommands();
          case QuickAction.settings:
            await openMobileSettings();
        }
    }
  }

  Future<void> openBusyInputSettings() => showBusyInputSettings(
    context,
    settings: BusyInputSettings(widget.gateway, widget.profile),
    profileLabel:
        widget.profileLabel ?? context.strings.profileName(widget.profile),
  );

  Future<void> openMobileSettings() async {
    await Navigator.of(context).push<void>(
      floatingPageRoute<void>(
        context,
        builder: (_) => MobileSettingsPage(
          gateway: widget.gateway,
          profile: widget.profile,
          onGateway: widget.onGatewaySignIn,
          notificationTarget: alertTarget(),
        ),
      ),
    );
    restoreChatKeyboard();
  }

  Future<void> openGatewayStatus() async {
    draftFocus.unfocus();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GatewayStatusPage(
          gateway: widget.gateway,
          profile: widget.profile,
          onSelectGateway: widget.onGatewaySignIn,
        ),
      ),
    );
    restoreChatKeyboard();
  }
}

enum _ComposerAction {
  camera('拍照', Icons.photo_camera_outlined),
  photo('照片', Icons.image_outlined),
  file('文件', Icons.attach_file_rounded),
  commands('命令与技能', Icons.terminal_rounded),
  pasteImage('粘贴图片', Icons.content_paste_rounded),
  referenceFile('引用远程文件', Icons.description_outlined),
  referenceFolder('引用远程文件夹', Icons.folder_outlined);

  const _ComposerAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Glass popover over the + button: the four everyday actions as large
/// rows, then the occasional ones below a hairline.
Future<_ComposerAction?> _chooseComposerAction(
  BuildContext context, {
  required Rect anchor,
  required bool canReference,
  required bool canPasteImages,
}) => showGlassMenu<_ComposerAction>(
  context,
  anchor: anchor,
  prominent: true,
  width: 250,
  items: [
    for (final action in _ComposerAction.values)
      if ((action != _ComposerAction.pasteImage || canPasteImages) &&
          (canReference ||
              action != _ComposerAction.referenceFile &&
                  action != _ComposerAction.referenceFolder))
        GlassMenuItem(
          value: action,
          icon: action.icon,
          label: context.tr(action.label),
          separated:
              action == _ComposerAction.pasteImage ||
              action == _ComposerAction.referenceFile && !canPasteImages,
        ),
  ],
);
