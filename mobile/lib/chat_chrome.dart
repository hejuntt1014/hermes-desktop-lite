part of 'chat.dart';

const _chromeMotion = Duration(milliseconds: 220);
const _barHeight = 46.0;

extension _ChatChrome on _ChatPageState {
  /// Space the floating top chrome covers; the transcript pads by it so the
  /// first message starts below the bar but still scrolls under the glass.
  double get chromeTopInset {
    final strip = widget.tabStrip != null && !compactChrome;
    return MediaQuery.paddingOf(context).top +
        (compactChrome ? 4 : 6) +
        (compactChrome ? 40 : _barHeight) +
        (strip ? 50 : 0) +
        6;
  }

  /// The transcript fills the screen; the top bar and the composer dock float
  /// above it as glass, so content is never boxed in by opaque chrome.
  Widget buildChatBody({
    required bool compact,
    required ColorScheme colors,
    required Color chrome,
  }) {
    compactChrome = compact;
    final empty = widget.id == null && runtime == null && rows.isEmpty && !busy;
    return ConversationCanvas(
      child: LayoutBuilder(
        builder: (context, bounds) => Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: empty
                      ? ValueListenableBuilder<double>(
                          valueListenable: dockHeight,
                          builder: (context, dock, child) => Padding(
                            padding: EdgeInsets.only(
                              top: chromeTopInset,
                              bottom: dock,
                            ),
                            child: child,
                          ),
                          child: _NewChatStart(
                            recent: widget.recent,
                            onOpen: widget.onOpen,
                          ),
                        )
                      : TranscriptTextSize(
                          size: appearance.messageSize,
                          child: buildReadingTimeline(),
                        ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: buildTopChrome(
                compact: compact,
                colors: colors,
                empty: empty,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: MeasureSize(
                onChange: (size) {
                  if (mounted) dockHeight.value = size.height;
                },
                child: buildDock(
                  compact: compact,
                  colors: colors,
                  maxHeight: math.max(
                    0.0,
                    bounds.maxHeight - (bounds.maxHeight >= 240 ? 120 : 2),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildDock({
    required bool compact,
    required ColorScheme colors,
    required double maxHeight,
  }) {
    final canvas =
        CustomThemeTokens.read(context, ThemeColor.canvas) ?? colors.surface;
    return DecoratedBox(
      // A short fade keeps text from colliding with the glass edge.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [canvas.withValues(alpha: 0), canvas.withValues(alpha: .9)],
          stops: const [0, .55],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 720, maxHeight: maxHeight),
            child: SingleChildScrollView(
              primary: false,
              reverse: true,
              padding: const EdgeInsets.only(top: 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy) const _DockProgress(),
                  ...dockNotices(colors),
                  buildComposer(compact: compact, colors: colors),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget buildTopChrome({
    required bool compact,
    required ColorScheme colors,
    required bool empty,
  }) {
    final canvas =
        CustomThemeTokens.read(context, ThemeColor.canvas) ?? colors.surface;
    final unread = widget.unreadConversations;
    final libraryLabel = context.tr(switch (widget.libraryDocked) {
      true => '隐藏会话侧栏',
      false => '显示会话侧栏',
      null => '会话列表',
    });
    final height = compact ? 40.0 : _barHeight;
    final strip = widget.tabStrip;
    final statusShare =
        (MediaQuery.paddingOf(context).top / (chromeTopInset + 12)).clamp(
          0.0,
          .6,
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // Solid behind the status bar so the clock never sits on text,
          // then a soft fade below the floating controls.
          colors: [
            canvas,
            canvas,
            canvas.withValues(alpha: .88),
            canvas.withValues(alpha: 0),
          ],
          stops: [0, statusShare, statusShare + (1 - statusShare) * .45, 1],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(10, compact ? 4 : 6, 10, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  GlassIconButton(
                    icon: widget.libraryDocked == null
                        ? Icons.notes_rounded
                        : Icons.view_sidebar_outlined,
                    tooltip: unread == 0
                        ? libraryLabel
                        : '$libraryLabel · ${context.strings.format('{count} 个最近会话未读', {'count': unread})}',
                    size: height,
                    dot: unread > 0,
                    onPressed: canBrowseChat ? widget.onLibrary : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    // A blank conversation has nothing to title yet.
                    child: empty
                        ? const SizedBox.shrink()
                        : buildTitlePill(height, compact, colors),
                  ),
                  const SizedBox(width: 8),
                  GlassSurface(
                    radius: height / 2,
                    child: SizedBox(
                      height: height,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 2),
                          TabCountButton(
                            count: widget.tabCount,
                            onPressed:
                                canBrowseChat && widget.onShowTabs != null
                                ? () {
                                    draftFocus.unfocus();
                                    widget.onShowTabs!();
                                  }
                                : null,
                          ),
                          Builder(
                            builder: (anchor) => IconButton(
                              tooltip: context.tr('会话选项'),
                              onPressed: canBrowseChat
                                  ? () => openChatMenu(globalRectOf(anchor))
                                  : null,
                              icon: const Icon(
                                Icons.more_horiz_rounded,
                                size: 22,
                              ),
                            ),
                          ),
                          const SizedBox(width: 2),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (strip != null && !compact)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: GlassSurface(
                    radius: 22,
                    child: SizedBox(height: 44, child: strip),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Title, profile and context use in one glass pill. Tap manages the
  /// conversation; a horizontal fling switches to the neighbouring tab.
  Widget buildTitlePill(double height, bool compact, ColorScheme colors) {
    final theme = Theme.of(context);
    final cycle = widget.onCycleTab;
    final activity = conversationActivity;
    final chrome = colors.surface;
    final manage = hasConversationActions && canBrowseChat
        ? () => runConversationAction()
        : null;
    return GestureDetector(
      onHorizontalDragEnd: cycle == null || !canBrowseChat
          ? null
          : (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity.abs() < 260) return;
              draftFocus.unfocus();
              cycle(velocity < 0 ? 1 : -1);
            },
      child: GlassSurface(
        radius: height / 2,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('conversation-title-actions'),
            onTap: manage,
            child: SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (activity != null) ...[
                          ConversationIndicator(activity: activity, size: 13),
                          const SizedBox(width: 5),
                        ],
                        Flexible(
                          child: Text(
                            displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -.2,
                              height: 1.2,
                              color: widget.titleColor?.onBackground(chrome),
                            ),
                          ),
                        ),
                        if (manage != null)
                          Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 16,
                            color: colors.onSurfaceVariant,
                          ),
                      ],
                    ),
                    if (!compact)
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.profileLabel ??
                                  context.strings.profileName(widget.profile),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colors.onSurfaceVariant,
                                height: 1.2,
                              ),
                            ),
                          ),
                          ContextMeterLabel(value: contextMeter),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openChatMenu(Rect anchor) async {
    final chosen = await showGlassMenu<_ChatMenu>(
      context,
      anchor: anchor,
      width: 248,
      items: chatMenuItems(),
    );
    if (chosen != null && mounted) runChatMenu(chosen);
    restoreChatKeyboard();
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
        return Padding(
          key: fileDrop.key,
          padding: EdgeInsets.fromLTRB(
            10,
            compact ? 2 : 4,
            10,
            compact ? 3 : 8,
          ),
          child: GlassSurface(
            radius: 26,
            tint: CustomThemeTokens.read(context, ThemeColor.composer),
            borderColor: fileDrop.hovering ? colors.primary : null,
            padding: EdgeInsets.fromLTRB(4, expanded ? 6 : 2, 4, 2),
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
                          ? () =>
                                openWorkspace(section: WorkspaceSection.review)
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
                    crossAxisAlignment: expanded
                        ? CrossAxisAlignment.center
                        : CrossAxisAlignment.end,
                    // Side slots swap instantly: a cross-fade keeps the old
                    // buttons' size during the fade and makes the text jump.
                    // The key keeps the field (and its focus) across the swap.
                    children: [
                      if (expanded)
                        const SizedBox(width: 12)
                      else
                        attachButton(),
                      Expanded(
                        key: const ValueKey('composer-field'),
                        child: buildDraftField(expanded, compact),
                      ),
                      if (expanded)
                        const SizedBox(width: 12)
                      else ...[
                        if (!readOnly) voiceButtons(colors),
                        if (running) stopButton(colors),
                      ],
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

  Widget attachButton() => Builder(
    key: const ValueKey('composer-attach'),
    builder: (anchor) => IconButton(
      onPressed: canPickAttachment ? () => pick(globalRectOf(anchor)) : null,
      tooltip: context.tr('添加附件与命令'),
      icon: const Icon(Icons.add_rounded, size: 24),
    ),
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

/// Thin progress line above the dock while a reply is being produced.
class _DockProgress extends StatelessWidget {
  const _DockProgress();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(28, 0, 28, 6),
    child: ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(2)),
      child: LinearProgressIndicator(minHeight: 2.5),
    ),
  );
}
