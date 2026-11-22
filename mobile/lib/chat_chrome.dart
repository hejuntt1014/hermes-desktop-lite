part of 'chat.dart';

const _chromeMotion = Duration(milliseconds: 220);

extension _ChatChrome on _ChatPageState {
  /// One slim row: library, title (swipe to switch tabs), tab count, menu.
  /// The tab strip only returns on wide layouts, where the shell supplies it.
  PreferredSizeWidget buildChatAppBar({
    required bool compact,
    required Color chrome,
    required ColorScheme colors,
  }) {
    final libraryLabel = context.tr(switch (widget.libraryDocked) {
      true => '隐藏会话侧栏',
      false => '显示会话侧栏',
      null => '会话列表',
    });
    final unread = widget.unreadConversations;
    final cycle = widget.onCycleTab;
    final showTabs = widget.onShowTabs;
    return AppBar(
      bottom: compact || widget.tabStrip == null
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: widget.tabStrip!,
            ),
      toolbarHeight: compact ? 46 : 54,
      backgroundColor: chrome,
      centerTitle: false,
      titleSpacing: 0,
      leadingWidth: 52,
      leading: _ChromeButton(
        icon: widget.libraryDocked == null
            ? Icons.menu_rounded
            : Icons.view_sidebar_outlined,
        label: unread == 0
            ? libraryLabel
            : '$libraryLabel · ${context.strings.format('{count} 个最近会话未读', {'count': unread})}',
        badge: unread,
        tap: canBrowseChat ? widget.onLibrary : null,
      ),
      title: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: cycle == null || !canBrowseChat
            ? null
            : (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity.abs() < 260) return;
                draftFocus.unfocus();
                cycle(velocity < 0 ? 1 : -1);
              },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            buildConversationTitle(chrome),
            if (!compact)
              Row(
                children: [
                  Flexible(
                    child: Text(
                      widget.profileLabel ??
                          context.strings.profileName(widget.profile),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        letterSpacing: .1,
                      ),
                    ),
                  ),
                  ContextMeterLabel(value: contextMeter),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TabCountButton(
          count: widget.tabCount,
          onPressed: canBrowseChat && showTabs != null
              ? () {
                  draftFocus.unfocus();
                  showTabs();
                }
              : null,
        ),
        Semantics(
          container: true,
          child: PopupMenuButton<_ChatMenu>(
            enabled: canBrowseChat,
            tooltip: context.tr('会话选项'),
            icon: const Icon(Icons.more_vert_rounded, size: 21),
            position: PopupMenuPosition.under,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            onSelected: runChatMenu,
            itemBuilder: buildConversationMenu,
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  void runChatMenu(_ChatMenu action) {
    switch (action) {
      case _ChatMenu.quickAccess:
        openQuickAccess();
      case _ChatMenu.workspace:
        openWorkspace();
      case _ChatMenu.rename:
        runConversationAction(SessionMenuAction.rename);
      case _ChatMenu.export:
        runConversationAction(SessionMenuAction.export);
      case _ChatMenu.find:
        exploreTranscript();
      case _ChatMenu.conversationFiles:
        openWorkspace(section: WorkspaceSection.conversationFiles);
      case _ChatMenu.newChat:
        widget.onNew();
      case _ChatMenu.activity:
        openSessionActivity();
      case _ChatMenu.status:
        openSessionStatus();
      case _ChatMenu.gateway:
        openGatewayStatus();
      case _ChatMenu.busyInput:
        openBusyInputSettings();
      case _ChatMenu.voiceEngine:
        openVoiceEngine();
      case _ChatMenu.wake:
        widget.onWakeSettings?.call();
      case _ChatMenu.reload:
        reloadConversation();
    }
  }

  bool get canPickAttachment =>
      gatewayReady && !busy && !composerBusy && !slashPending && !readOnly;

  /// Idle and empty, the composer is a single pill: attach, field, voice.
  /// It opens into a full editor with the model and send row while the
  /// keyboard is up or once it holds a draft, then folds away again.
  Widget buildComposer({required bool compact, required ColorScheme colors}) {
    return ListenableBuilder(
      listenable: Listenable.merge([draftFocus, draft, uploadProgress]),
      builder: (context, _) {
        final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
        final expanded =
            compact ||
            draftFocus.hasFocus && keyboard ||
            draft.text.isNotEmpty ||
            files.isNotEmpty ||
            pictures.isNotEmpty ||
            composerBusy ||
            uploadProgress.value != null ||
            fileDrop.hovering;
        final dark = Theme.of(context).brightness == Brightness.dark;
        final fill =
            CustomThemeTokens.read(context, ThemeColor.composer) ??
            (dark ? colors.surfaceContainerLow : colors.surface);
        return AnimatedContainer(
          key: fileDrop.key,
          duration: _chromeMotion,
          curve: Curves.easeOutCubic,
          margin: EdgeInsets.fromLTRB(10, compact ? 2 : 4, 10, compact ? 3 : 8),
          padding: EdgeInsets.fromLTRB(4, expanded ? 6 : 3, 4, 3),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(expanded ? 24 : 27),
            border: Border.all(
              color: fileDrop.hovering
                  ? colors.primary
                  : colors.outlineVariant.withValues(alpha: expanded ? 1 : .75),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: dark ? .28 : (expanded ? .08 : .05),
                ),
                blurRadius: expanded ? 22 : 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: AnimatedSize(
            duration: _chromeMotion,
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (composerBusy) const LinearProgressIndicator(minHeight: 2),
                if (uploadProgress.value case final update?)
                  _ComposerUploadStatus(
                    update: update,
                    cancelling: uploadControl?.cancelled == true,
                    onCancel: cancelUpload,
                  ),
                if (workspaceDir case final path?
                    when expanded && path.isNotEmpty && !compact)
                  _ComposerWorkspaceBar(
                    path: path,
                    branch: workspaceBranch,
                    onBrowse: gatewayReady && !busy ? openWorkspace : null,
                    onReview: gatewayReady && !busy
                        ? () => openWorkspace(section: WorkspaceSection.review)
                        : null,
                  ),
                if (slashHintVisible)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(7, 0, 5, 0),
                    child: TextButton.icon(
                      onPressed: slashPending ? null : openCommands,
                      icon: const Icon(Icons.terminal_rounded, size: 16),
                      label: Text(context.tr('命令与技能')),
                    ),
                  ),
                if (files.isNotEmpty) buildComposerFiles(),
                if (pictures.isNotEmpty) buildComposerPictures(),
                Row(
                  key: const ValueKey('composer-input'),
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    AnimatedSwitcher(
                      duration: _chromeMotion,
                      child: expanded
                          ? const SizedBox(width: 12, height: 44)
                          : attachButton(),
                    ),
                    Expanded(child: buildDraftField(expanded, compact)),
                    AnimatedSwitcher(
                      duration: _chromeMotion,
                      child: expanded
                          ? const SizedBox(width: 12, height: 44)
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!readOnly) voiceButtons(colors),
                                if (running) stopButton(colors),
                              ],
                            ),
                    ),
                  ],
                ),
                if (expanded)
                  Row(
                    children: [
                      attachButton(),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: readOnly
                              ? null
                              : ModelControl(
                                  model: deferredModel?.id ?? currentModel,
                                  effort: deferredEffort ?? effort,
                                  speed: speed,
                                  status: modelStatus,
                                  deferred:
                                      deferredModel != null ||
                                      deferredEffort != null,
                                  onPressed:
                                      !canChangeModel ||
                                          slashPending ||
                                          modelStatus != null
                                      ? null
                                      : pickModel,
                                ),
                        ),
                      ),
                      if (!readOnly) voiceButtons(colors),
                      if (running) stopButton(colors),
                      const SizedBox(width: 2),
                      sendButton(colors),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  bool get slashHintVisible {
    if (readOnly || busy || !gatewayReady) return false;
    final text = draft.text.trimLeft();
    return text.startsWith('/') &&
        (text == '/' || parseSlashInput(text) != null);
  }

  Widget attachButton() => IconButton(
    key: const ValueKey('composer-attach'),
    onPressed: canPickAttachment ? pick : null,
    tooltip: context.tr('添加附件与命令'),
    icon: const Icon(Icons.add_rounded, size: 23),
  );

  Widget stopButton(ColorScheme colors) => IconButton(
    onPressed: gatewayReady && !stopping ? stop : null,
    tooltip: context.tr('停止回复'),
    style: IconButton.styleFrom(
      backgroundColor: colors.surfaceContainerHigh,
      minimumSize: const Size(38, 38),
    ),
    icon: const Icon(Icons.stop_rounded, size: 20),
  );

  Widget buildDraftField(bool expanded, bool compact) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: handleComposerKey,
    child: TextField(
      controller: draft,
      focusNode: draftFocus,
      readOnly: !canEditDraft,
      contextMenuBuilder: composerContextMenu,
      contentInsertionConfiguration:
          composerStore != null && widget.keyboardActive && !readOnly
          ? ContentInsertionConfiguration(
              onContentInserted: insertKeyboardImage,
            )
          : null,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4),
      minLines: 1,
      maxLines: expanded ? (compact ? 2 : 6) : 1,
      decoration: InputDecoration(
        hintText: context.tr('输入消息…'),
        hintStyle: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        filled: false,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: expanded ? 4 : 12),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
      ),
    ),
  );

  Widget sendButton(ColorScheme colors) {
    final text = draft.text.trim();
    final attached = pictures.isNotEmpty || files.isNotEmpty;
    final queue =
        queuesDraft && !canSendBusyText(text, hasAttachments: attached);
    return IconButton.filled(
      onPressed:
          _composing(draft.value) ||
              !gatewayReady ||
              unconfirmedSend != null ||
              busy ||
              composerBusy ||
              slashPending ||
              readOnly ||
              rewrite != null ||
              modelStatus != null ||
              hydrating ||
              widget.id != null && runtime == null ||
              text.isEmpty && !attached
          ? null
          : send,
      tooltip: context.tr(queue ? '加入队列' : '发送'),
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        shape: const CircleBorder(),
        backgroundColor: colors.onSurface,
        foregroundColor: colors.surface,
        disabledBackgroundColor: colors.surfaceContainerHigh,
        disabledForegroundColor: colors.onSurfaceVariant.withValues(alpha: .6),
      ),
      icon: Icon(
        queue ? Icons.playlist_add_rounded : Icons.arrow_upward_rounded,
        size: 20,
      ),
    );
  }

  Widget buildComposerFiles() => SizedBox(
    height: 48,
    child: ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      scrollDirection: Axis.horizontal,
      itemCount: files.length,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (context, index) {
        final file = files[index];
        return Center(
          child: InputChip(
            onPressed: canRemoveDraftAttachments
                ? () => openComposerFile(file, context)
                : null,
            avatar: const Icon(Icons.insert_drive_file_outlined, size: 16),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 175),
              child: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            onDeleted: canRemoveDraftAttachments
                ? () => removeSelectedComposerFile(file, photo: false)
                : null,
          ),
        );
      },
    ),
  );
}
