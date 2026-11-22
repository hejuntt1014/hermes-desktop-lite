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
      return ListTile(
        dense: true,
        title: text,
        trailing: runtime == null && !busy
            ? IconButton(
                tooltip: context.tr('重新加载会话'),
                onPressed: open,
                icon: const Icon(Icons.refresh_rounded),
              )
            : null,
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

  Widget buildConversationTitle(Color chrome) {
    final activity = conversationActivity;
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (activity != null) ...[
          ConversationIndicator(activity: activity, size: 15),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -.25,
              color: widget.titleColor?.onBackground(chrome),
            ),
          ),
        ),
      ],
    );
    if (!hasConversationActions) return title;
    return Tooltip(
      message: context.tr('管理会话'),
      child: InkWell(
        key: const ValueKey('conversation-title-actions'),
        borderRadius: BorderRadius.circular(8),
        onTap: canBrowseChat ? runConversationAction : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 30),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: title),
              const SizedBox(width: 3),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 17,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<PopupMenuEntry<_ChatMenu>> buildConversationMenu(BuildContext menu) {
    final colors = Theme.of(menu).colorScheme;
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
        if (visible(item)) ...[
          if (item == _ChatMenu.newChat ||
              item == _ChatMenu.find ||
              item == _ChatMenu.gateway)
            const PopupMenuDivider(height: 8),
          PopupMenuItem(
            value: item,
            enabled: enabled(item),
            child: Row(
              children: [
                Icon(
                  item.icon,
                  size: 19,
                  color: enabled(item)
                      ? colors.onSurfaceVariant
                      : colors.onSurface.withValues(alpha: .38),
                ),
                const SizedBox(width: 11),
                Flexible(child: Text(menu.tr(item.label))),
              ],
            ),
          ),
        ],
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
      MaterialPageRoute(
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
  photo('选择照片', Icons.image_outlined),
  file('添加文件', Icons.attach_file_rounded),
  pasteImage('粘贴剪贴板图片', Icons.content_paste_rounded),
  referenceFile('引用远程文件', Icons.description_outlined),
  referenceFolder('引用远程文件夹', Icons.folder_outlined),
  commands('命令与技能', Icons.terminal_rounded);

  const _ComposerAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

Future<_ComposerAction?> _chooseComposerAction(
  BuildContext context, {
  required bool canReference,
  required bool canPasteImages,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<_ComposerAction>(
    context: context,
    showDragHandle: true,
    barrierColor: Colors.black.withValues(
      alpha: Theme.of(context).brightness == Brightness.dark ? .54 : .28,
    ),
    builder: (sheet) {
      final colors = Theme.of(sheet).colorScheme;
      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(15, 0, 15, 11),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final action in _ComposerAction.values) ...[
                if (action == _ComposerAction.commands ||
                    action == _ComposerAction.referenceFile && canReference)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Divider(color: colors.outlineVariant, height: 9),
                  ),
                if ((action != _ComposerAction.pasteImage || canPasteImages) &&
                    (canReference ||
                        action != _ComposerAction.referenceFile &&
                            action != _ComposerAction.referenceFolder))
                  ListTile(
                    title: Text(sheet.tr(action.label)),
                    leading: Icon(
                      action.icon,
                      color: colors.onSurfaceVariant,
                      size: 21,
                    ),
                    minLeadingWidth: 23,
                    minTileHeight: 48,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onTap: () => Navigator.pop(sheet, action),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _NewChatStart extends StatelessWidget {
  const _NewChatStart({required this.recent, required this.onOpen});
  final List<Json> recent;
  final ValueChanged<Json> onOpen;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.expand();
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, space) {
        if (space.maxHeight < 120) return const SizedBox.expand();
        return Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: SingleChildScrollView(
              reverse: true,
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const BrandMark(size: 43),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          context.tr('新会话'),
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.65,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (recent.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      context.tr('最近会话'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    for (final row in recent.take(3))
                      Material(
                        type: MaterialType.transparency,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          minTileHeight: 48,
                          title: Text(
                            (row['title'] ??
                                    row['preview'] ??
                                    context.tr('未命名会话'))
                                .toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                          trailing: Icon(
                            Icons.arrow_outward_rounded,
                            size: 16,
                            color: colors.onSurfaceVariant,
                          ),
                          onTap: () => onOpen(row),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
