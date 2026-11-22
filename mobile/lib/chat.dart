import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show compute, listEquals;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        HardwareKeyboard,
        KeyEvent,
        KeyboardInsertedContent,
        LogicalKeyboardKey,
        PlatformException;
import 'package:image_picker/image_picker.dart';
import 'package:file_selector/file_selector.dart' show openFiles;
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';

import 'mobile_locale.dart';
import 'mobile_shortcuts.dart';
import 'session_colors.dart';
import 'command_receipts.dart';
import 'command_receipt_view.dart';
import 'background_notice.dart';
import 'background_notice_view.dart';
import 'busy_input.dart';
import 'chat_display.dart';
import 'gateway.dart';
import 'gateway_status_view.dart';
import 'followup_queue.dart';
import 'chat_tabs.dart';
import 'composer_attachments.dart';
import 'mobile_photo_picker.dart';
import 'composer_file_drop.dart';
import 'composer_references.dart';
import 'file_transfer_dialog.dart' show formatTransferSize;
import 'image_format.dart';
import 'mobile_clipboard.dart';
import 'session_activity.dart';
import 'session_activity_view.dart';
import 'session_status_view.dart';
import 'history.dart';
import 'interaction.dart';
import 'models.dart';
import 'model_picker.dart';
import 'model_preferences.dart';
import 'message_content.dart';
import 'media_gallery.dart';
import 'message_rewrite.dart';
import 'timeline.dart';
import 'activity_view.dart';
import 'attachment_view.dart' show exportLocalAttachment, fileShareOrigin;
import 'message_bookmarks.dart';
import 'quick_access.dart';
import 'tab_switcher.dart' show TabCountButton;
import 'mobile_settings.dart';
import 'mobile_voice.dart';
import 'mobile_wake.dart';
import 'mobile_wake_view.dart';
import 'mobile_notifications.dart';
import 'mobile_themes.dart';
import 'transcript_explorer.dart';
import 'transcript_search.dart';
import 'transcript_reader.dart';
import 'reading_position.dart';
import 'transcript_navigation.dart';
import 'transcript_match_view.dart';
import 'turn_corrections.dart';
import 'session_tasks.dart';
import 'session_branch.dart';
import 'session_library.dart';
import 'appearance.dart';
import 'session_export.dart';
import 'slash_commands.dart';
import 'slash_picker.dart';
import 'workspace.dart';
import 'workspace_directory.dart';
import 'workspace_files.dart';
import 'workspace_view.dart';

part 'chat_slash.dart';
part 'chat_shell.dart';
part 'chat_reading.dart';
part 'chat_reconnect.dart';
part 'chat_queue.dart';
part 'chat_models.dart';
part 'chat_status.dart';
part 'chat_composer.dart';
part 'chat_chrome.dart';
part 'chat_start.dart';
part 'chat_voice.dart';
part 'chat_clipboard.dart';
part 'chat_history_addresses.dart';
part 'chat_rewrite_target.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.gateway,
    required this.profile,
    required this.id,
    required this.title,
    this.titleColor,
    required this.onLibrary,
    this.unreadConversations = 0,
    required this.onNew,
    this.onNewWithDraft,
    this.onConversationAction,
    required this.recent,
    required this.onOpen,
    this.onOpenMessage,
    this.messageTarget,
    this.onMessageTargetOpened,
    this.onCron,
    this.wake,
    this.onWakeSettings,
    this.wakeLaunch,
    this.onWakeLaunchHandled,
    this.onRenamed,
    this.onActivityChanged,
    this.notificationTarget,
    this.onNotificationOpened,
    this.onGatewaySignIn,
    this.onBound,
    this.initialDraft = '',
    this.initialDraftStamp,
    this.draftModel,
    this.onDraftModel,
    this.onDraft,
    this.onFlushDraft,
    this.composerTab,
    this.onDraftAttachments,
    this.onWorkspacePosition,
    this.onWorkspaceReviewPosition,
    this.tabStrip,
    this.openTabs = const [],
    this.onSelectTab,
    this.onCloseTab,
    this.onReopenTab,
    this.onShowTabs,
    this.tabCount = 1,
    this.onCycleTab,
    this.keyboardActive = true,
    this.landscapeKeyboard = false,
    this.fileDropActive = true,
    this.reloadRequest = 0,
    this.libraryDocked,
    this.cwd,
    this.profileLabel,
  });
  final VoidCallback onLibrary, onNew;
  final int unreadConversations;
  final Future<void> Function()? onNewWithDraft;
  final ValueChanged<SessionMenuAction?>? onConversationAction;
  final Future<void> Function()? onCron;
  final MobileWake? wake;
  final VoidCallback? onWakeSettings;
  final Object? wakeLaunch;
  final ValueChanged<Object>? onWakeLaunchHandled;
  final void Function(String id, String title)? onRenamed;
  final ValueChanged<ConversationActivity?>? onActivityChanged;
  final VoidCallback? onGatewaySignIn;
  final ConversationAlertTarget? notificationTarget;
  final ValueChanged<ConversationAlertTarget>? onNotificationOpened;
  final Future<void> Function(Json)? onBound;
  final String initialDraft;
  final String? initialDraftStamp;
  final Json? draftModel;
  final ValueChanged<Json>? onDraftModel;
  final void Function(String text, String? stamp)? onDraft;
  final Future<void> Function()? onFlushDraft;
  final ChatTab? composerTab;
  final Future<bool> Function(List<ComposerAttachment>)? onDraftAttachments;
  final ValueChanged<WorkspaceBrowserPosition>? onWorkspacePosition;
  final ValueChanged<WorkspaceReviewPosition>? onWorkspaceReviewPosition;
  final Widget? tabStrip;
  final List<ChatTab> openTabs;
  final ValueChanged<String>? onSelectTab;
  final int reloadRequest;
  final bool? libraryDocked;
  final VoidCallback? onCloseTab, onReopenTab, onShowTabs;
  final int tabCount;
  final ValueChanged<int>? onCycleTab;
  final bool keyboardActive, landscapeKeyboard, fileDropActive;
  final List<Json> recent;
  final ValueChanged<Json> onOpen;
  final ValueChanged<TranscriptTarget>? onOpenMessage;
  final TranscriptTarget? messageTarget;
  final ValueChanged<TranscriptTarget>? onMessageTargetOpened;
  final Gateway gateway;
  final String profile, title;
  final String? profileLabel;
  final SessionTitleColor? titleColor;
  final String? id, cwd;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final draft = TextEditingController(text: widget.initialDraft);
  bool quickAccessOpen = false;
  final readingViewport = GlobalKey();
  final readingCells = <BuildContext, _ReadingCellInfo>{};
  final readingAddresses = <int, MessageAddress>{};
  final latestScroll = ScrollController(keepScrollOffset: false);
  final awayFromLatest = ValueNotifier(false);
  final messagesBelow = ValueNotifier<int?>(null);
  final pinnedQuestion = ValueNotifier<_PinnedQuestion?>(null);
  _ReadingTimeline? shownReadingTimeline;
  bool readingIndicatorsScheduled = false, newHistoryWhileReading = false;
  late final AppLifecycleListener readingLifecycle;
  ScrollController? readingScroll;
  Timer? readingTimer;
  ReadingPosition? latestReading;
  ReadingWindow? readingWindow;
  final readingTimelines = _ReadingTimelines();
  final activityExpansion = ActivityExpansion();
  int readingEpoch = 0;
  bool readingGesture = false;
  bool readingTowardNewer = false;
  bool readingDirty = false;
  ({bool older, String message})? readingError;
  ({int target, Object token})? readingJump;
  FileTransferControl? readingLookup, adjacentHistoryRead;
  bool get readingLoading => adjacentHistoryRead != null;
  int? revealedRowId;
  TranscriptMatchExcerpt? revealedMatch;
  final draftFocus = FocusNode();
  late final references = ComposerReferences(widget.gateway, draft, draftFocus);
  final keyboardFocus = FocusNode(debugLabel: 'Conversation shortcuts');
  bool slashPending = false;
  SlashCatalog? slashCatalog;
  String? slashRuntime;
  int slashRevision = 0;
  String? renamedTitle;
  late String? workspaceDir = widget.cwd;
  String? workspaceBranch;

  void updateWorkspaceInfo(Json info) {
    if (info['cwd'] case final String path
        when path.isNotEmpty && path != workspaceDir) {
      workspaceDir = path;
      workspaceBranch = null;
    }
    if (info.containsKey('branch')) {
      workspaceBranch = workspaceBranchName(info['branch']);
    }
  }

  late final WorkspaceDefaults workspaceDefaults = WorkspaceDefaults(
    widget.gateway,
    widget.profile,
  );
  late final Future<void> draftWorkspace = readDraftWorkspace();
  final appearance = MobileAppearance.shared;
  late final profileReasoning = ProfileReasoning.of(
    widget.gateway,
    widget.profile,
  );
  bool get showsReasoning => appearance.reasoning.shows(profileReasoning);
  ReasoningPresentation get reasoningPresentation =>
      profileReasoning.presentation;
  List<CommandReceipt> commandReceipts = [];
  int commandReceiptRead = 0;
  String get displayTitle => renamedTitle ?? widget.title;
  void updateSlash(VoidCallback change) => setState(change);
  final rows = <ChatRow>[];
  final historyRows = <Json>[];
  int displayedHistoryCount = 0;
  HistoryPage? oldest;
  ({String session, Json? row})? historyTail;
  Timer? historyCheckTimer;
  bool checkingHistory = false, historyCheckSoon = false;
  bool loadingOlder = false;
  FileTransferControl? interactiveHistoryRead;
  bool get loadingRecentHistory =>
      interactiveHistoryRead != null && !loadingOlder;
  String? historyError, olderHistoryError;
  bool readOnly = false;
  bool copyingDraft = false;
  bool hydrating = false;
  bool stopping = false;
  bool opening = false;
  bool get canBrowseChat => !busy || opening && widget.id != null;
  bool get canEditDraft => !readOnly && (canBrowseChat || recoveringSession);
  Json? rewrite;
  bool get idleForRewrite =>
      gatewayReady &&
      !busy &&
      !queueDraining &&
      !running &&
      !stopping &&
      !readOnly &&
      !hydrating &&
      !loadingOlder &&
      modelStatus == null &&
      unconfirmedSend == null &&
      remoteFollowups.isEmpty &&
      pendingInteractions.isEmpty &&
      runtime != null;
  RewriteJournal? get rewriteJournal {
    final id = stored ?? widget.id;
    return id == null
        ? null
        : RewriteJournal(widget.gateway, widget.profile, id);
  }

  final pendingInteractions = <String, Interaction>{};
  final clarificationDrafts = <(String, int?), ClarifyDraft>{};
  final answering = <String>{};

  bool _openingNotification = false;

  ConversationAlertTarget? alertTarget({
    String? prompt,
    bool reply = false,
    MessageAddress? message,
  }) {
    final session = stored ?? widget.id;
    if (session == null) return null;
    return ConversationAlertTarget(
      owner: ConversationAlertTarget.ownerFor(widget.gateway),
      profile: widget.profile,
      session: session,
      title: displayTitle,
      prompt: prompt,
      reply: reply,
      message: message,
    );
  }

  void removeInteraction(String key) {
    final removed = pendingInteractions.remove(key);
    if (removed == null) return;
    if (!removed.approval) clarificationDrafts.remove(removed.clarification);
    if (alertTarget(prompt: key) case final target?) {
      MobileNotifications.shared.clearPrompt(target);
    }
  }

  void clearInteractions() {
    for (final key in pendingInteractions.keys.toList()) {
      removeInteraction(key);
    }
    clarificationDrafts.clear();
    reconcilePromptNotifications();
  }

  void reconcilePromptNotifications() {
    if (alertTarget() case final scope?) {
      MobileNotifications.shared.reconcilePrompts(
        scope,
        pendingInteractions.keys,
      );
    }
  }

  void openNotificationTarget() {
    final target = widget.notificationTarget;
    if (target == null || _openingNotification) return;
    bool ready() =>
        mounted &&
        widget.keyboardActive &&
        identical(widget.notificationTarget, target) &&
        target.profile == widget.profile &&
        (target.session == widget.id || target.session == stored) &&
        !opening &&
        !hydrating &&
        gatewayReady &&
        ModalRoute.isCurrentOf(context) != false &&
        (runtime != null || target.reply && oldest != null);
    if (!ready()) return;
    final key = target.prompt;
    // Older approval notifications stored the JSON-RPC frame ID.
    Interaction? pending() =>
        pendingInteractions[key] ??
        pendingInteractions.values
            .where(
              (item) =>
                  item.approval &&
                  item.requestId != null &&
                  key == 'request:${item.requestId}',
            )
            .firstOrNull;
    if (key != null && pending() == null && running) return;
    _openingNotification = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openingNotification = false;
      if (!ready()) return;
      final item = key == null ? null : pending();
      if (key != null && item == null && running) return;
      widget.onNotificationOpened?.call(target);
      if (item != null) {
        unawaited(showInteraction(item));
      } else if (target.reply) {
        if (target.message case final address?) {
          unawaited(revealReadingMessage(address, latestOnMiss: true));
        } else {
          returnToLatest();
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.isCurrentOf(context) == false) {
      voice.cancel();
    } else {
      openNotificationTarget();
    }
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.title != oldWidget.title) renamedTitle = null;
    if (widget.keyboardActive != oldWidget.keyboardActive) {
      workActivity?.watch(widget.keyboardActive);
      if (!widget.keyboardActive) {
        voice.cancel();
        stopAdjacentHistoryRead();
        trimInactiveReading();
      }
      scheduleHistoryCheck(changed: widget.keyboardActive);
    }
    if (widget.keyboardActive && !oldWidget.keyboardActive) {
      if (sessionRecoveryDeferred &&
          widget.gateway.link == GatewayLink.online) {
        resumeSessionConnection();
      }
      restoreChatKeyboard();
    }
    if (widget.wakeLaunch != oldWidget.wakeLaunch) scheduleWakeLaunch();
    if (oldWidget.notificationTarget != widget.notificationTarget ||
        !oldWidget.keyboardActive && widget.keyboardActive) {
      openNotificationTarget();
    }
    if (oldWidget.messageTarget != widget.messageTarget ||
        !oldWidget.keyboardActive && widget.keyboardActive) {
      openMessageTarget();
    }
    if (oldWidget.reloadRequest != widget.reloadRequest) {
      final request = widget.reloadRequest;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.reloadRequest == request) {
          unawaited(reloadConversation());
        }
      });
    }
  }

  void restoreChatKeyboard() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          widget.keyboardActive &&
          !keyboardFocus.hasFocus &&
          ModalRoute.of(context)?.isCurrent != false) {
        keyboardFocus.requestFocus();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> reloadConversation() async {
    if (!gatewayReady || (widget.id ?? stored) == null) return;
    if (busy || loadingOlder || hydrating) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.tr('会话正在加载，请稍后重试'))));
      return;
    }
    await open(recovering: true);
  }

  void acceptInteraction(Interaction? interaction) {
    if (interaction == null) return;
    final previous = pendingInteractions[interaction.key];
    // Use the live request when the recovery snapshot also includes its approval.
    if (previous?.requestId != null && interaction.requestId == null) return;
    final isNew = previous == null;
    pendingInteractions[interaction.key] = interaction;
    running = true;
    if (isNew) {
      if (alertTarget(prompt: interaction.key) case final target?) {
        MobileNotifications.shared.prompt(
          target,
          approval: interaction.approval,
        );
      }
    }
    openNotificationTarget();
  }

  void notifyPendingInteractions() {
    for (final item in pendingInteractions.values) {
      if (alertTarget(prompt: item.key) case final target?) {
        MobileNotifications.shared.prompt(target, approval: item.approval);
      }
    }
  }

  Interaction? ownedInteractionRequest(Json request) {
    final params = request['params'];
    if (params is! Json) return null;
    final sessionId = params['session_id'] ?? params['gateway_session_id'];
    if (sessionId != runtime && sessionId != stored ||
        params['profile'] != null && params['profile'] != widget.profile) {
      return null;
    }
    return Interaction.fromRequest(request);
  }

  void acceptRequest(Json request) {
    final interaction = ownedInteractionRequest(request);
    if (interaction == null) return;
    widget.gateway.rememberInteractionRequest(request);
    acceptInteraction(interaction);
  }

  Future<void> showInteraction(Interaction interaction) async {
    if (!answering.add(interaction.key)) return;
    final link = linkRevision;
    final draftKey = interaction.clarification;
    final signature = interaction.approval
        ? null
        : interaction.questionSignature;
    Interaction? currentPrompt() => interaction.approval
        ? pendingInteractions[interaction.key]
        : pendingInteractions.values
              .where(
                (item) =>
                    !item.approval &&
                    item.clarification == draftKey &&
                    item.questionSignature == signature,
              )
              .firstOrNull;
    try {
      final answer = await showModalBottomSheet<Json>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => InteractionSheet(
          interaction: interaction,
          draft: interaction.approval ? null : clarificationDrafts[draftKey],
          onDraft: interaction.approval
              ? null
              : (draft) {
                  if (mounted &&
                      (currentPrompt() != null || !gatewayReady && running)) {
                    clarificationDrafts[draftKey] = draft;
                  }
                },
        ),
      );
      final sid = runtime;
      final live = currentPrompt();
      if (!mounted ||
          sid == null ||
          answer == null ||
          live == null ||
          interaction.approval && linkRevision != link ||
          live.id != interaction.id ||
          live.generation != interaction.generation) {
        return;
      }
      if (!gatewayReady) throw GatewayDisconnected();
      await live.answer(widget.gateway, sid, widget.profile, answer);
      if (mounted && identical(pendingInteractions[live.key], live)) {
        setState(() => removeInteraction(live.key));
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      answering.remove(interaction.key);
    }
  }

  ModelChoice? pickedModel;
  late final modelPreferences = ModelPreferences(
    widget.gateway,
    widget.profile,
  );
  ({ModelChoice model, String? effort, String? speed})? pendingModelPreset;
  ModelChoice? _deferredModel;
  int? deferredModelTurn;
  ModelChoice? get deferredModel => _deferredModel;
  set deferredModel(ModelChoice? value) {
    _deferredModel = value;
    if (value == null) deferredModelTurn = null;
    modelActivity.value = (running: running, modelPending: value != null);
  }

  String? deferredEffort;
  bool applyingModelPreset = false;
  String? currentModel, currentProvider, effort, speed, modelStatus;
  SessionModelControls? modelControls;
  SessionTaskSnapshot? taskSnapshot;

  void updateTasks(SessionTaskSnapshot? next) {
    if (next == null) return;
    final previous = taskSnapshot?.revision;
    if (previous != null &&
        next.revision != null &&
        next.revision! < previous) {
      return;
    }
    taskSnapshot = next;
  }

  Json get launch => {
    if (workspaceDir case final String path when path.isNotEmpty) ...{
      'cwd': path,
      'cwd_explicit': true,
    },
    if (pickedModel != null) ...{
      'model': pickedModel!.id,
      'provider': pickedModel!.provider,
    },
    if (effort != null)
      (widget.gateway.canonical ? 'reasoning' : 'reasoning_effort'): effort,
    if (speed != null) ...{
      if (!widget.gateway.canonical) 'fast': speed != 'normal',
      if (widget.gateway.canonical || speed == 'ultrafast')
        'service_tier': speed,
    },
  };

  final contextMeter = ValueNotifier<ContextMeter?>(null);
  final sessionApprovalBypass = ValueNotifier<bool?>(null);
  Future<bool>? contextReading;
  final live = ValueNotifier('');
  final thought = ValueNotifier('');
  String? turn;
  ChatRow? awaitingEcho;
  Object? peerPromptTicket;

  ChatRow addPendingEcho(String body) {
    final echo = ChatRow(user: true, body: displayedUserMessageBody(body));
    rows.add(echo);
    awaitingEcho = echo;
    running = true;
    return echo;
  }

  bool removePendingEcho(ChatRow echo) {
    if (!identical(awaitingEcho, echo)) return false;
    rows.remove(echo);
    awaitingEcho = null;
    running = false;
    return true;
  }

  late final StreamSubscription<Json> subscription;
  String? runtime, stored, error;
  SessionActivityMonitor? workActivity;
  bool busy = false;
  final modelActivity = ValueNotifier((running: false, modelPending: false));
  bool get running => modelActivity.value.running;
  set running(bool value) {
    modelActivity.value = (running: value, modelPending: deferredModel != null);
    noteTurnActivity();
  }

  final pictures = <XFile>[];
  final files = <XFile>[];
  final uploadProgress = ValueNotifier<_ComposerUpload?>(null);
  FileTransferControl? uploadControl;
  late final ComposerAttachmentStore? composerStore = widget.composerTab == null
      ? null
      : ComposerAttachmentStore(
          widget.gateway,
          widget.profile,
          widget.composerTab!.id,
        );
  late final Future<void> composerRestore;
  Future<void>? composerWrite;
  bool pastingImages = false;
  bool pickingAttachments = false;
  bool restoringComposer = false;
  String? composerError;
  late final fileDrop = ComposerFileDrop(
    onChanged: _updateDisplay,
    onFiles: addDroppedFiles,
    onFailure: () {
      if (mounted) {
        setState(() => composerError = '无法读取拖入的文件');
      }
    },
  );
  bool get composerBusy =>
      restoringComposer ||
      composerWrite != null ||
      pickingAttachments ||
      pastingImages ||
      fileDrop.receiving;
  final early = <Json>[];
  int? segment;
  int replyOffset = 0;
  int? replyGapAfter;
  bool get replyGap => replyGapAfter != null;
  String lastSealedReply = '';
  String restoredAssistantPrefix = '';
  final interimReplies = <ChatRow>[];
  int seq = 0;
  String sessionEpoch = '';
  int? executionGeneration;
  TurnCorrectionScope? correctionScope;
  final confirmedCorrections = <ConfirmedCorrection>[];
  bool recoveringSession = false, recoveryRequested = false;
  bool sessionRecoveryDeferred = false;
  int linkRevision = 0;
  int turnActivityRevision = 0;
  final turnSilence = Stopwatch()..start();
  int? unsupportedTurnRosterLink, unsupportedTurnReplayLink;
  Timer? turnCheckTimer;
  bool checkingTurn = false;
  _UnconfirmedSend? unconfirmedSend;
  List<FollowupDraft> followups = [];
  List<RemoteFollowup> remoteFollowups = [];
  bool queueLoaded = false, queueDraining = false, queueExpanded = false;
  bool queueEditing = false;
  int completedTurns = 0;
  late final voice = MobileVoice(widget.gateway, widget.profile);
  bool voiceBorrowing = false;
  Object? scheduledWakeLaunch;
  _VoiceReply? pendingVoiceReply;
  _VoiceRecovery? voiceRecovery;
  String? queueError;
  final queueActions = <String>{};
  @override
  void initState() {
    super.initState();
    appearance.addListener(_updateDisplay);
    profileReasoning.addListener(_updateDisplay);
    unawaited(profileReasoning.refresh());
    restoringComposer =
        widget.composerTab?.attachments.isNotEmpty == true ||
        photoDraftTarget != null;
    composerRestore = restoreComposer();
    draft.addListener(draftChanged);
    restoreDraftModel();
    readingLifecycle = AppLifecycleListener(
      onInactive: () {
        flushReading();
        references.updateScope(null);
        if (voice.phase != VoicePhase.opening) voice.cancel();
      },
      onHide: () {
        flushReading();
        suspendTurnCheck();
        historyCheckTimer?.cancel();
        historyCheckTimer = null;
        voice.cancel();
        notifyPendingInteractions();
      },
      onResume: () {
        scheduleTurnCheck();
        scheduleHistoryCheck(changed: true);
        openNotificationTarget();
        if (widget.keyboardActive) _updateDisplay();
      },
    );
    subscription = widget.gateway.events.listen(
      onEvent,
      onDone: () {
        interactiveHistoryRead?.cancel();
        stopAdjacentHistoryRead();
        if (mounted) {
          setState(() {
            error = '网关连接已断开，请重新连接';
            running = false;
          });
        }
      },
    );
    if (widget.id != null) {
      unawaited(loadCommandReceipts());
      if (widget.messageTarget == null &&
          widget.notificationTarget?.reply != true) {
        unawaited(restoreReading());
      } else {
        openMessageTarget();
      }
      open();
    } else {
      unawaited(draftWorkspace);
    }
    scheduleWakeLaunch();
  }

  void _updateDisplay() {
    if (mounted) setState(() {});
  }

  ConversationActivity? _publishedActivity;

  ConversationActivity? get conversationActivity {
    if (!gatewayReady) return null;
    if (pendingInteractions.isNotEmpty) return ConversationActivity.waiting;
    if (running) return ConversationActivity.running;
    return null;
  }

  void publishConversationActivity() {
    final activity = conversationActivity;
    if (_publishedActivity == activity) return;
    _publishedActivity = activity;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && conversationActivity == activity) {
        widget.onActivityChanged?.call(activity);
      }
    });
  }

  late String _lastDraft = widget.initialDraft;
  late String? draftStamp = widget.initialDraftStamp;

  void draftChanged() {
    final text = draft.text;
    if (text == _lastDraft) return;
    _lastDraft = text;
    draftStamp = text.isEmpty ? null : const Uuid().v4();
    widget.onDraft?.call(text, draftStamp);
  }

  @override
  void dispose() {
    appearance.removeListener(_updateDisplay);
    profileReasoning.removeListener(_updateDisplay);
    flushReading();
    stopReadingLookup();
    stopAdjacentHistoryRead();
    workActivity?.dispose();
    readingLifecycle.dispose();
    suspendTurnCheck();
    historyCheckTimer?.cancel();
    interactiveHistoryRead?.cancel();
    voice.dispose();
    finishVoiceRecovery(ready: false);
    latestScroll.dispose();
    awayFromLatest.dispose();
    messagesBelow.dispose();
    pinnedQuestion.dispose();
    readingScroll?.dispose();
    subscription.cancel();
    draft.removeListener(draftChanged);
    references.dispose();
    fileDrop.dispose();
    draft.dispose();
    draftFocus.dispose();
    keyboardFocus.dispose();
    contextMeter.dispose();
    transcriptSearch?.dispose();
    sessionApprovalBypass.dispose();
    modelActivity.dispose();
    uploadControl?.cancel();
    uploadProgress.dispose();
    live.dispose();
    thought.dispose();
    super.dispose();
  }

  Future<void> open({bool recovering = false}) async {
    if (busy || loadingOlder) return;
    interactiveHistoryRead?.cancel();
    stopAdjacentHistoryRead();
    if (!recovering) early.clear();
    final linkAtStart = linkRevision;
    final previousRuntime = runtime;
    final previousEpoch = sessionEpoch;
    final previousGeneration = executionGeneration;
    final previousOutput = (
      reply: live.value,
      thought: thought.value,
      turn: turn,
      segment: segment,
      offset: replyOffset,
      sealed: lastSealedReply,
      prefix: restoredAssistantPrefix,
    );
    setState(() {
      busy = true;
      opening = true;
      error = null;
      historyError = null;
      olderHistoryError = null;
      readOnly = false;
      hydrating = false;
    });
    final id = widget.id ?? stored;
    List<Json> recentWireRows = [];
    try {
      if (id == null) {
        await draftWorkspace;
        if (!mounted || linkRevision != linkAtStart) return;
      }
      // Show stored history even when the runtime cannot resume this session.
      var paged = id != null;
      if (id != null && (!recovering || oldest == null)) {
        try {
          final page = await widget.gateway.historyPage(widget.profile, id, 0);
          recentWireRows = page.rows;
          if (!mounted || linkRevision != linkAtStart) return;
          setState(() {
            applyLatestHistory(page);
            stored = page.sessionId;
          });
        } on GatewayError catch (e) {
          if (!mounted || linkRevision != linkAtStart) return;
          paged = e.status != 404 && e.status != 405 && e.status != 501;
          if (paged) historyError = '历史读取失败，点击重试';
        }
      }
      if (!mounted || linkRevision != linkAtStart) return;
      Json snapshot;
      try {
        snapshot = await widget.gateway.openSession(
          widget.profile,
          id,
          paged: paged,
          launch: launch,
        );
      } on GatewayError catch (e) {
        if (!mounted || linkRevision != linkAtStart) return;
        if (!paged ||
            oldest?.nextOffset != null ||
            !{4000, -32602}.contains(e.code) ||
            !RegExp(r'defer_history|omit_messages').hasMatch(e.message)) {
          rethrow;
        }
        snapshot = await widget.gateway.openSession(widget.profile, id);
        paged = false;
      }
      if (!mounted || linkRevision != linkAtStart) return;
      if (recovering && paged && id != null) {
        try {
          final page = await widget.gateway.historyPage(widget.profile, id, 0);
          if (!mounted || linkRevision != linkAtStart) return;
          recentWireRows = page.rows;
          applyLatestHistory(page, keepLoaded: true);
        } catch (_) {
          if (!mounted || linkRevision != linkAtStart) return;
          historyError = '未能更新最近消息';
        }
      }
      runtime = snapshot['session_id'] as String;
      stored =
          (snapshot['stored_session_id'] ?? stored ?? id ?? runtime) as String;
      updateActivityScope();
      modelControls = SessionModelControls(
        gateway: widget.gateway,
        profile: widget.profile,
        stored: stored!,
        runtime: runtime!,
        version: modelVersion(snapshot),
      );
      executionGeneration = snapshot['execution_generation'] is int
          ? snapshot['execution_generation'] as int
          : null;
      if (previousRuntime != runtime ||
          previousEpoch.isNotEmpty &&
              (snapshot['replay_epoch'] ?? widget.gateway.replayEpoch) !=
                  previousEpoch) {
        deferredModel = null;
        deferredEffort = null;
      }
      final info = snapshot['info'];
      final bypass = info is Json ? info['yolo'] : null;
      sessionApprovalBypass.value = bypass is bool ? bypass : null;
      if (info is Json) {
        updateWorkspaceInfo(info);
        updateSessionModelSettings(info);
        updateContextUsage(info);
      }
      if (id == null && stored != null) {
        final name = info is Json ? info['title'] as String? : null;
        final excerpt = bookmarkExcerpt(draft.text);
        await widget.onBound?.call({
          'id': stored,
          'profile': widget.profile,
          'title': name?.isNotEmpty == true
              ? name
              : excerpt.isEmpty
              ? '新会话'
              : excerpt,
          'cwd': workspaceDir,
        });
        if (!mounted || linkRevision != linkAtStart) return;
        unawaited(loadCommandReceipts());
      }
      final messages =
          snapshot['display_messages'] ??
          snapshot['messages'] ??
          snapshot['history'];
      if (!paged && messages is List) {
        recentWireRows = messages.whereType<Json>().toList();
        rows
          ..clear()
          ..addAll(displayRows(messages));
        oldest = null;
        historyRows.clear();
        displayedHistoryCount = 0;
        historyTail = null;
        historyError = null;
      }
      hydrating = snapshot['hydrating'] == true;
      if (recovering) {
        live.value = '';
        thought.value = '';
        lastSealedReply = '';
        restoredAssistantPrefix = '';
        interimReplies.clear();
        awaitingEcho = null;
        peerPromptTicket = null;
        turn = null;
        segment = null;
        replyOffset = 0;
      }
      running =
          snapshot['running'] == true ||
          snapshot['inflight']?['streaming'] == true;
      final journal = rewriteJournal;
      if (journal != null) {
        await journal.confirmSeen(snapshot, recentWireRows);
        final saved = await journal.load();
        if (!mounted || linkRevision != linkAtStart) return;
        rewrite = saved;
      }
      seq = snapshot['last_sequence'] as int? ?? 0;
      sessionEpoch =
          snapshot['replay_epoch'] as String? ?? widget.gateway.replayEpoch;
      if (!running ||
          previousRuntime != runtime ||
          previousEpoch != sessionEpoch ||
          previousGeneration != executionGeneration) {
        clearReplyGap();
      }
      final savedCorrections = await loadConfirmedCorrections();
      if (!mounted || linkRevision != linkAtStart) return;
      applyConfirmedCorrections(savedCorrections);
      final reconciledDraft = await confirmReconnectedDraft(
        snapshot,
        recentWireRows,
        savedCorrections: savedCorrections,
      );
      if (!mounted || linkRevision != linkAtStart) return;
      if (reconciledDraft &&
          savedCorrections != null &&
          (!running || activeCorrectionScope != savedCorrections.scope)) {
        pruneConfirmedCorrections(savedCorrections.scope);
      }
      await syncFollowupQueue(snapshot, recentWireRows);
      if (!mounted || linkRevision != linkAtStart) return;
      pendingInteractions.clear();
      for (final item
          in (snapshot['prompts'] as List? ?? []).whereType<Json>()) {
        acceptInteraction(
          Interaction.fromPrompt(
            item['kind']?.toString() ?? '',
            item,
            snapshot['execution_generation'] as int?,
          ),
        );
      }
      if (snapshot['pending_approval'] case final Json approval) {
        acceptInteraction(Interaction.fromPrompt('approval', approval, null));
      }
      for (final item
          in (snapshot['open_requests'] as List? ?? []).whereType<Json>()) {
        acceptRequest(item);
      }
      for (final item in widget.gateway.pendingInteractionRequests.toList()) {
        acceptRequest(item);
      }
      updateTasks(SessionTaskSnapshot.parse(snapshot['todo_state']));
      final inflight = snapshot['inflight'];
      if (inflight is Json) {
        restoreInflightOutput(inflight);
      } else if (running && widget.gateway.canonical) {
        final rebuilt =
            seq > 0 && await restoreRunningOutput(snapshot, linkAtStart);
        if (!mounted || linkRevision != linkAtStart) return;
        if (!rebuilt) restoreConfirmedCorrections();
        if (!rebuilt &&
            recovering &&
            previousRuntime == runtime &&
            previousEpoch == sessionEpoch &&
            previousGeneration != null &&
            previousGeneration == executionGeneration) {
          live.value = previousOutput.reply;
          thought.value = previousOutput.thought;
          turn = previousOutput.turn;
          segment = previousOutput.segment;
          replyOffset = previousOutput.offset;
          lastSealedReply = previousOutput.sealed;
          restoredAssistantPrefix = previousOutput.prefix;
        }
      }
      for (final event in early) {
        applyEvent(event);
      }
      if (snapshot['open_requests'] is List ||
          snapshot['prompts'] is List ||
          !running && !hydrating) {
        reconcilePromptNotifications();
      }
      if (recovering) await recoverVoiceReply(recentWireRows, snapshot);
    } on GatewayError catch (e) {
      if (mounted && linkRevision == linkAtStart) {
        setState(() {
          if (recovering) {
            runtime = null;
            running = false;
            updateActivityScope();
          }
          readOnly = e.code == 4130;
          error = readOnly ? '当前会话超过网关的恢复上限，可查看历史或新建会话。' : e.message;
        });
      }
    } catch (e) {
      if (mounted && linkRevision == linkAtStart) {
        setState(() {
          if (recovering) {
            runtime = null;
            running = false;
            updateActivityScope();
          }
          error = e.toString();
        });
      }
    } finally {
      early.clear();
      if (mounted) {
        setState(() {
          busy = false;
          opening = false;
        });
        openNotificationTarget();
        if (rows.isEmpty && oldest?.nextOffset != null) {
          loadOlder();
        }
        if (!queueLoaded && queueStore != null) {
          unawaited(syncFollowupQueue({}, const []));
        }
        scheduleFollowupDrain();
        scheduleHistoryCheck();
        unawaited(applyReadyModelPreset());
        if (contextMeter.value == null) unawaited(refreshContextUsage());
        if (recovering &&
            widget.notificationTarget?.reply != true &&
            rows.isNotEmpty &&
            readingWindow == null &&
            latestReading != null &&
            widget.gateway.usable) {
          unawaited(restoreReading());
        }
      }
    }
  }

  Future<void> loadOlder() async {
    final first = oldest;
    final offset = first?.nextOffset;
    final id = widget.id ?? stored;
    if (first == null || offset == null || id == null || !canReadOlderHistory) {
      return;
    }
    final control = interactiveHistoryRead = FileTransferControl();
    final link = linkRevision;
    bool current() =>
        mounted &&
        !control.cancelled &&
        identical(oldest, first) &&
        (widget.id ?? stored) == id &&
        link == linkRevision;
    setState(() {
      loadingOlder = true;
      olderHistoryError = null;
    });
    try {
      var page = await widget.gateway.historyPage(
        widget.profile,
        id,
        offset,
        control: control,
      );
      if (!current()) return;
      var pageOffset = offset;
      List<Json> prefix;
      try {
        prefix = olderPrefix(first, page);
      } on GatewayError {
        if (page.sessionId != first.sessionId || first.rows.isEmpty) rethrow;
        final rebased = await TranscriptNavigation(
          widget.gateway,
          widget.profile,
          id,
        ).recoverOlderTail(first, offset, control: control);
        if (!current()) return;
        if (rebased == null) rethrow;
        (:page, offset: pageOffset) = rebased;
        prefix = olderPrefix(first, page);
      }
      setState(() {
        recordReadingAddresses(page.rows, newestOffset: pageOffset);
        historyRows.insertAll(0, prefix);
        final olderRows = displayRows(prefix).toList(growable: false);
        rows.insertAll(0, olderRows);
        displayedHistoryCount += olderRows.length;
        oldest = page;
      });
    } catch (_) {
      if (current()) setState(() => olderHistoryError = '较早消息读取中断，点此重试');
    } finally {
      if (mounted && identical(interactiveHistoryRead, control)) {
        setState(() {
          interactiveHistoryRead = null;
          loadingOlder = false;
        });
      }
    }
  }

  void onEvent(Json event) {
    if (!mounted ||
        event['profile'] != null && event['profile'] != widget.profile) {
      return;
    }
    if (event['type'] == 'client.connection') {
      onConnectionEvent(event);
      return;
    }
    if (event['type'] == 'sessions.changed') {
      scheduleHistoryCheck(changed: true);
    }
    if (event['type'] == 'skills.changed') {
      slashCatalog = null;
      slashRevision++;
      return;
    }
    if (sessionRecoveryDeferred) {
      final session = event['session_id'];
      final type = event['type'];
      if (session != null &&
          (session == runtime || session == stored) &&
          type is String &&
          (type.startsWith('message.') ||
              type.startsWith('subagent.') ||
              type.startsWith('background.') ||
              type == 'client.interaction' ||
              type == 'approval.request' ||
              type == 'clarify.request')) {
        if (widget.gateway.usable) {
          resumeSessionConnection();
          if (recoveringSession) early.add(event);
        } else {
          recoveryRequested = true;
        }
      }
      return;
    }
    if (opening || recoveringSession || runtime == null) {
      if ((opening || recoveringSession) && event['session_id'] != null) {
        early.add(event);
      }
      return;
    }
    applyEvent(event);
  }

  void seal({bool keepOffset = false}) {
    sealThought();
    if (live.value.isNotEmpty) {
      lastSealedReply = live.value;
      rows.add(ChatRow(user: false, body: live.value));
    }
    live.value = '';
    if (!keepOffset) replyOffset = 0;
  }

  void sealInterim({bool keepOffset = false}) {
    final displayed = live.value.isNotEmpty;
    seal(keepOffset: keepOffset);
    if (displayed) interimReplies.add(rows.last);
  }

  bool settlePreviewedReply(String text) {
    final finalText = text.trim();
    final streamed = live.value.trim();
    // The current segment takes precedence over earlier commentary with the
    // same opening line.
    if (streamed.isNotEmpty && finalText.startsWith(streamed)) return false;
    for (final preview in interimReplies.reversed) {
      final prior = preview.body.trim();
      if (prior.isEmpty || !finalText.startsWith(prior)) continue;
      final index = rows.indexOf(preview);
      if (index < 0) continue;
      if (finalText != prior) rows[index] = ChatRow(user: false, body: text);
      return true;
    }
    return false;
  }

  void sealThought() {
    if (thought.value.isEmpty) return;
    final summary = thought.value.trim();
    if (summary.isNotEmpty) {
      rows.add(ChatRow(user: false, body: summary, activity: '思考'));
    }
    thought.value = '';
  }

  void applyEvent(Json e) {
    if (e['session_id'] != runtime && e['session_id'] != stored) return;
    final payload = e['payload'];
    if (payload is! Json) return;
    final next = e['seq'];
    final epoch = e['replay_epoch'];
    if (epoch is String && epoch.isNotEmpty) sessionEpoch = epoch;
    if (next is int && next > 0 && next <= seq) return;
    final kind = e['type'];
    final generation =
        e['execution_generation'] ?? payload['execution_generation'];
    final previousGeneration = executionGeneration;
    final stale =
        widget.gateway.canonical &&
        generation is int &&
        previousGeneration != null &&
        generation < previousGeneration;
    if (!stale &&
        kind == 'message.delta' &&
        payload['text'] is String &&
        !canApplyReplyDelta(payload)) {
      return;
    }
    if (next is int && next > 0) {
      seq = next;
    }
    if (stale) return;
    if (generation is int) executionGeneration = generation;
    final version = modelVersion(e) ?? modelVersion(payload);
    if (version != null) modelControls?.observeVersion(version);
    final info = payload['info'];
    final name = info is Json ? info['title'] : payload['title'];
    if ((e['type'] == 'session.info' || e['type'] == 'session.updated') &&
        name is String &&
        name.isNotEmpty &&
        name != displayTitle &&
        stored != null) {
      setState(() => renamedTitle = name);
      widget.onRenamed?.call(stored!, name);
    }
    if (kind == 'session.updated') scheduleHistoryCheck(changed: true);
    if (kind == 'session.info' && payload['running'] == false && running) {
      scheduleTurnCheck(verifyIdle: true);
    }
    if (const {
      'message.start',
      'message.delta',
      'message.interim',
      'message.complete',
      'reasoning.delta',
      'thinking.delta',
      'tool.start',
      'tool.complete',
      'client.interaction',
      'approval.request',
      'clarify.request',
    }.contains(kind)) {
      noteTurnActivity();
    }
    if (deferredModelTurn case final int after
        when kind == 'message.start' && completedTurns > after) {
      deferredModelTurn = null;
    }
    final sessionInfo = info is Json
        ? info
        : kind == 'session.info' || kind == 'session.updated'
        ? payload
        : null;
    if (sessionInfo != null) {
      setState(() {
        updateWorkspaceInfo(sessionInfo);
        updateSessionModelSettings(sessionInfo);
      });
      if (sessionInfo['yolo'] case final bool bypass) {
        sessionApprovalBypass.value = bypass;
      }
      updateContextUsage(sessionInfo);
    }
    if (kind == 'session.usage' || kind == 'message.complete') {
      updateContextUsage(payload);
    }
    if (!running && sessionInfo != null && kind != 'message.start') {
      unawaited(applyReadyModelPreset());
    }
    final text = messageBody(payload['text']);
    final admissionId = e['admission_id'];
    final startingFollowup =
        kind == 'message.start' &&
            widget.gateway.canonical &&
            admissionId is String
        ? remoteFollowups.where((entry) => entry.id == admissionId).firstOrNull
        : null;
    if (widget.gateway.canonical && payload.containsKey('pending')) {
      final remote = RemoteFollowup.parse(payload['pending']);
      if (remote != null) {
        setState(() => remoteFollowups = remote);
        scheduleFollowupDrain();
      }
    }
    switch (e['type']) {
      case 'session.resume_progress':
        if (payload['phase'] == 'history') {
          setState(() {
            hydrating = payload['status'] == 'loading';
            if (payload['status'] == 'failed') {
              runtime = null;
              updateActivityScope();
              readOnly = true;
              error = '暂时无法继续这段会话。历史仍可查看。';
            }
          });
          if (!hydrating) {
            unawaited(finishVoiceRecoveryAfterHydration());
            openNotificationTarget();
          }
        }
      case 'client.interaction':
        setState(() => acceptRequest(payload));
      case 'approval.request':
      case 'clarify.request':
        final kind = (e['type'] as String).split('.').first;
        setState(
          () => acceptInteraction(
            Interaction.fromPrompt(
              kind,
              payload,
              e['execution_generation'] as int? ??
                  modelControls?.version?.generation,
            ),
          ),
        );
      case 'request.cancel':
        final request = payload['id'];
        final match = pendingInteractions.values
            .where((item) => item.requestId?.toString() == request?.toString())
            .firstOrNull;
        if (request != null && match != null) {
          setState(() => removeInteraction(match.key));
        }
      case 'approval.settled':
      case 'approval.cancelled':
      case 'clarify.settled':
      case 'clarify.cancelled':
        final kind = (e['type'] as String).split('.').first;
        final id = payload['prompt_id'] ?? payload['request_id'];
        setState(() => removeInteraction('$kind:$id'));
      case 'notification.show' when payload['key'] == 'model_switch.dropped':
        setState(() {
          deferredModel = null;
          deferredEffort = null;
          pendingModelPreset = null;
        });
        if (payload['text'] case final String text when widget.keyboardActive) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(text)));
        }
      case 'message.start':
        confirmLiveAdmission(payload);
        final started = payload['turn_id'] as String?;
        identifyVoiceTurn(payload, started);
        if (started != null && started == turn) return;
        var fetchPeerPrompt = false;
        setState(() {
          seal();
          peerPromptTicket = null;
          turn = started;
          segment = null;
          clearReplyGap();
          lastSealedReply = '';
          restoredAssistantPrefix = '';
          interimReplies.clear();
          running = true;
          final prompt = ChatRow.visibleIncomingUser(
            text.isNotEmpty ? text : startingFollowup?.text,
            payload,
          );
          final echo = awaitingEcho;
          awaitingEcho = null;
          fetchPeerPrompt =
              echo == null &&
              prompt == null &&
              payload['display_kind'] != 'hidden' &&
              !widget.gateway.canonical;
          if (echo == null &&
              prompt != null &&
              (startingFollowup != null ||
                  rows.isEmpty ||
                  (!rows.last.user && rows.last.backgroundNotice == null) ||
                  rows.last.body != prompt.body)) {
            rows.add(prompt);
            if (_countsConversationMessage(prompt)) noteNewMessage();
          }
        });
        if (fetchPeerPrompt) unawaited(fillPeerPrompt());
      case 'reasoning.delta':
      case 'thinking.delta':
        thought.value += text;
      case 'reasoning.available':
        if (text.trim().isNotEmpty) thought.value = text;
      case 'todo.updated':
        setState(() => updateTasks(SessionTaskSnapshot.parse(payload)));
      case 'tool.start':
      case 'tool.complete':
        final tool = ChatRow.result(payload);
        setState(() {
          if (e['type'] == 'tool.start') sealThought();
          if (e['type'] == 'tool.complete' &&
              {'todo', 'todo_list'}.contains(tool.activity)) {
            updateTasks(SessionTaskSnapshot.parse(payload));
          }
          final existing = tool.toolId == null
              ? -1
              : rows.lastIndexWhere((row) => row.toolId == tool.toolId);
          if (existing >= 0 && e['type'] == 'tool.complete') {
            rows[existing] = rows[existing].mergeResult(tool);
          } else if (existing < 0) {
            rows.add(
              e['type'] == 'tool.complete'
                  ? tool
                  : ChatRow(
                      user: false,
                      body: '',
                      activity: tool.activity,
                      toolId: tool.toolId,
                      arguments: tool.arguments,
                      inlineDiff: tool.inlineDiff,
                      running: true,
                    ),
            );
          }
        });
      case 'message.delta':
        final s = payload['segment'] as int?;
        if (s != null && segment != null && s < segment!) return;
        if (payload.containsKey('text') && payload['text'] == null) {
          if (replyGap) return;
          setState(() {
            // A presentation boundary before a tool can keep the same wire
            // segment and its cumulative UTF-16 offset.
            sealInterim(keepOffset: s == null || s == segment);
            segment = s ?? segment;
            running = true;
          });
          return;
        }
        if (s != null && segment != null && s > segment!) setState(seal);
        segment = s ?? segment;
        final offset = payload['offset'] as int? ?? replyOffset;
        var overlap = (replyOffset - offset).clamp(0, text.length);
        if (overlap > 0 && overlap < text.length) {
          final trailing = text.codeUnitAt(overlap);
          if (trailing >= 0xdc00 && trailing <= 0xdfff) overlap++;
        }
        live.value += text.substring(overlap);
        replyOffset = math.max(replyOffset, offset + text.length);
        if (!running) setState(() => running = true);
      case 'message.interim':
        final s = payload['segment'] as int?;
        if (s != null && segment != null && s < segment!) return;
        setState(() {
          if (text.isNotEmpty) {
            if (s == null || segment == null || s == segment) {
              clearReplyGap();
            }
            live.value = text;
          }
          sealInterim();
          segment = s == null ? null : s + 1;
        });
      case 'message.complete':
        confirmLiveAdmission(payload);
        confirmLiveRewrite(payload);
        final wasRunning = running;
        final reply = [
          text,
          live.value,
          lastSealedReply,
        ].firstWhere((part) => part.trim().isNotEmpty, orElse: () => '');
        final voiced = settleVoiceReply(payload, reply);
        final status = payload['status'];
        final missingFinal =
            replyGap &&
            (text.isEmpty ||
                payload['response_reused'] == true ||
                payload['response_previewed'] == true);
        setState(() {
          completedTurns++;
          settleConfirmedCorrections();
          clearInteractions();
          awaitingEcho = null;
          clearReplyGap();
          if (text.isNotEmpty && payload['response_reused'] != true) {
            final finalText =
                restoredAssistantPrefix.isNotEmpty &&
                    text.startsWith(restoredAssistantPrefix)
                ? text.substring(restoredAssistantPrefix.length)
                : text;
            if (!(payload['response_previewed'] == true &&
                settlePreviewedReply(finalText))) {
              live.value = finalText;
            }
          }
          seal();
          if (wasRunning && reply.isNotEmpty) noteNewMessage();
          lastSealedReply = '';
          restoredAssistantPrefix = '';
          interimReplies.clear();
          segment = null;
          running = false;
          error = payload['error'] as String?;
        });
        if (wasRunning && payload['error'] == null) {
          unawaited(bindCompletedHistory());
          if (appearance.autoReadReplies &&
              !voiced &&
              (status == null || status == 'complete')) {
            readReply(reply);
          }
          final receipt = payload['persisted_turn'];
          final address = receipt is Json
              ? MessageAddress.fromWire({
                  'row_id': receipt['final_assistant_row_id'],
                  'prompt_id': receipt['user_row_id'],
                  'tail_offset': 0,
                })
              : null;
          if (alertTarget(reply: true, message: address) case final target?) {
            MobileNotifications.shared.reply(target);
          }
        }
        openNotificationTarget();
        unawaited(applyReadyModelPreset());
        if (missingFinal) unawaited(requestSessionRecovery());
        scheduleFollowupDrain();
        scheduleHistoryCheck();
      case 'error':
        settleVoiceReply(payload, '', failed: true);
        setState(() {
          peerPromptTicket = null;
          settleConfirmedCorrections();
          seal();
          running = false;
          clearReplyGap();
          lastSealedReply = '';
          restoredAssistantPrefix = '';
          interimReplies.clear();
          error = (payload['message'] ?? '回复失败').toString();
        });
    }
  }

  Future<void> pick() async {
    if (busy || composerBusy) return;
    final item = await _chooseComposerAction(
      context,
      canReference: canReference,
      canPasteImages: canPasteImages,
    );
    if (item == null || !mounted) return;
    if (item == _ComposerAction.commands) {
      await openCommands();
      return;
    }
    if (item == _ComposerAction.pasteImage) {
      await pasteComposerClipboard(showEmpty: true);
      return;
    }
    if (item == _ComposerAction.referenceFile ||
        item == _ComposerAction.referenceFolder) {
      if (canReference) {
        references.insertPrefix(
          item == _ComposerAction.referenceFile
              ? ReferenceKind.file
              : ReferenceKind.folder,
        );
      }
      return;
    }
    try {
      if (item == _ComposerAction.photo || item == _ComposerAction.camera) {
        await pickComposerPhotos(camera: item == _ComposerAction.camera);
      } else {
        await pickComposerFiles();
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => composerError = e is GatewayError ? e.message : '无法保存草稿附件',
        );
      }
    }
  }

  Future<void> branchAt(ChatRow row) async {
    final boundary = row.rowId;
    if (boundary != null &&
        (!widget.gateway.canonical || _historyRowMutable(row))) {
      await branch(through: boundary);
    }
  }

  Future<void> branch({int? through}) async {
    final parent = through == null ? transcriptSession : stored;
    if (busy || parent == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final forked = await branchConversation(
        widget.gateway,
        parent: parent,
        profile: widget.profile,
        title: displayTitle,
        runtime: runtime,
        through: through,
      );
      if (mounted) widget.onOpen(forked);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> startRewrite(
    ChatRow row, {
    required bool retry,
    ReadingWindow? history,
  }) async {
    if (row.rowId == null ||
        !_historyRowMutable(row) ||
        !idleForRewrite ||
        rewrite != null ||
        readingWindow != history) {
      return;
    }
    final journal = rewriteJournal;
    if (journal == null) return;
    final attached = runtime;
    final link = linkRevision;
    final completion = completedTurns;
    final readingRevision = readingEpoch;
    final expected = modelControls?.version;
    bool current() =>
        mounted &&
        widget.keyboardActive &&
        gatewayReady &&
        !running &&
        runtime == attached &&
        linkRevision == link &&
        completedTurns == completion &&
        modelControls?.version == expected &&
        (stored ?? widget.id) == journal.stored &&
        readingWindow == history &&
        (history != null
            ? readingEpoch == readingRevision
            : _findRewriteRow(rows, row) >= 0);

    final _RewriteTarget target;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      target = await _resolveRewriteTarget(
        row,
        history,
        journal.stored,
        retry: retry,
        current: current,
      );
    } catch (e) {
      if (mounted && current()) setState(() => error = e.toString());
      return;
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (!mounted || !current() || !idleForRewrite || rewrite != null) return;
    final source = target.prompt;
    final id = source.rowId;
    if (!source.user || id == null) return;
    final deep = target.deep;
    final originals = RewriteDraft.fromMessage(source.body);
    var edited = originals.caption;
    final confirmed = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(retry ? context.tr('重试回复') : context.tr('编辑并重新发送')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (retry && originals.caption.isNotEmpty)
                Text(
                  originals.caption,
                  maxLines: 7,
                  overflow: TextOverflow.ellipsis,
                ),
              if (!retry)
                TextFormField(
                  initialValue: edited,
                  onChanged: (value) => edited = value,
                  minLines: 2,
                  maxLines: 7,
                  decoration: InputDecoration(labelText: context.tr('消息内容')),
                ),
              if (deep)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(context.tr('这条消息之后的对话将从当前分支归档。')),
                ),
              if (originals.fileRefs.isNotEmpty || originals.images.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    dialog.strings.format('保留 {length} 个原附件', {
                      'length':
                          originals.fileRefs.length + originals.images.length,
                    }),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(context.tr('取消')),
          ),
          FilledButton(
            onPressed: () {
              final text = edited.trim();
              if (text.isEmpty &&
                  originals.fileRefs.isEmpty &&
                  originals.images.isEmpty) {
                return;
              }
              if (!retry && text == originals.caption.trim()) return;
              Navigator.pop(dialog, text);
            },
            child: Text(dialog.tr(retry ? '重试' : '重新发送')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed == null) return;
    if (!idleForRewrite || rewrite != null || !current()) {
      if (widget.keyboardActive) {
        setState(() => error = '会话已变化，请刷新后再试');
      }
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var version = expected;
      if (widget.gateway.canonical && version == null) {
        final snapshot = await widget.gateway.mutationSnapshot(
          journal.stored,
          widget.profile,
        );
        if (snapshot != null) {
          version = (
            revision: snapshot['runtime_revision'] as int,
            generation: snapshot['runtime_generation'] as int,
          );
        }
      }
      if (!current()) {
        throw GatewayError('会话已变化，请刷新后再试');
      }
      final plan = await journal.prepare(
        caption: confirmed,
        original: originals,
        row: id,
        deep: deep,
        version: version,
        replayEpoch: sessionEpoch,
        replaySequence: seq,
      );
      if (!mounted) return;
      rewrite = await journal.load();
      if (!mounted) return;
      if (!current()) {
        throw GatewayError('会话已变化，请先检查待发送内容');
      }
      await finishRewrite(journal, plan);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          busy = false;
        });
      }
    }
  }

  Future<void> finishRewrite(RewriteJournal journal, Json plan) async {
    String? failure;
    try {
      await journal.send(runtime!, plan);
    } catch (e) {
      failure = e.toString();
    }
    if (!mounted) return;
    final pending = await journal.load();
    if (!mounted) return;
    setState(() {
      rewrite = pending;
      busy = false;
    });
    if (failure == null || pending?['phase'] == RewritePhase.submit.name) {
      returnToLatest();
    }
    await open();
    if (mounted && failure != null && rewrite?['id'] == plan['id']) {
      setState(() => error = failure);
    }
  }

  Future<void> continueRewrite() async {
    final plan = rewrite;
    final journal = rewriteJournal;
    if (!idleForRewrite || plan == null || journal == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await finishRewrite(journal, plan);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          busy = false;
        });
      }
    }
  }

  Future<void> discardRewrite() async {
    final journal = rewriteJournal;
    if (busy || journal == null) return;
    setState(() => busy = true);
    try {
      await journal.clear();
      if (mounted) setState(() => rewrite = null);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String? get transcriptSession => widget.id ?? stored;
  TranscriptSearch? transcriptSearch;
  (String, int, int?, String)? transcriptSearchRevision;

  Future<void> exploreTranscript({
    bool focusSearch = false,
    bool turns = false,
  }) async {
    final id = transcriptSession;
    if (id == null) return;
    final existing = transcriptSearch;
    final version = (id, completedTurns, rows.lastOrNull?.rowId, sessionEpoch);
    final search =
        existing?.navigation.session == id &&
            existing?.navigation.profile == widget.profile &&
            identical(existing?.navigation.gateway, widget.gateway)
        ? existing!
        : TranscriptSearch(
            TranscriptNavigation(widget.gateway, widget.profile, id),
          );
    if (!identical(existing, search)) existing?.dispose();
    if (historyTail?.session != id && transcriptSearchRevision != version) {
      search.reset(search.query);
    }
    transcriptSearch = search;
    transcriptSearchRevision = version;
    draftFocus.unfocus();
    final selected = await Navigator.push<TranscriptTarget>(
      context,
      MaterialPageRoute(
        builder: (_) => TranscriptExplorer(
          gateway: widget.gateway,
          profile: widget.profile,
          session: id,
          title: displayTitle,
          focusSearch: focusSearch,
          initialTurns: turns,
          returnSelection: true,
          searchState: search,
        ),
      ),
    );
    restoreChatKeyboard();
    if (selected != null && mounted) await openTranscriptTarget(selected);
  }

  MessageBookmark? bookmarkFor(ChatRow row) {
    final id = transcriptSession;
    final boundary = row.rowId;
    if (id == null || boundary == null) return null;
    final index = rows.indexOf(row);
    final known = readingAddresses[boundary];
    if (index < 0 && known == null) return null;
    int? prompt = known?.promptId;
    for (var i = index; i >= 0; i--) {
      if (rows[i].user && rows[i].rowId != null) {
        prompt = rows[i].rowId;
        break;
      }
    }
    return MessageBookmark(
      profile: widget.profile,
      session: id,
      title: displayTitle,
      excerpt: bookmarkExcerpt(row.body),
      address: MessageAddress(
        boundary,
        promptId: prompt,
        tailOffset: known?.tailOffset,
      ),
    );
  }

  Future<void> messageActions(ChatRow row) async {
    final history = readingWindow;
    final bookmark = bookmarkFor(row);
    final book = MessageBookmarks.forGateway(widget.gateway);
    var saved = false;
    try {
      if (bookmark != null) {
        saved = (await book.read()).any(
          (mark) => mark.addresses(
            bookmark.profile,
            bookmark.session,
            bookmark.address.rowId,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
    if (!mounted) return;

    final canBranch =
        gatewayReady &&
        !row.user &&
        row.rowId != null &&
        stored != null &&
        !busy &&
        !hydrating &&
        (widget.gateway.canonical ? _historyRowMutable(row) : runtime != null);
    final mayRewrite =
        idleForRewrite && rewrite == null && readingWindow == history;
    final rewriteRows = mayRewrite ? _rewriteRows(history) : const <ChatRow>[];
    final position = _findRewriteRow(rewriteRows, row);
    final edit =
        mayRewrite &&
        row.user &&
        position >= 0 &&
        _historyRowMutable(rewriteRows[position]);
    final retry = mayRewrite && _mayRetryFrom(rewriteRows, position, history);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (edit)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(context.tr('编辑消息')),
                  onTap: () => Navigator.pop(sheet, 'edit'),
                ),
              if (retry)
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: Text(context.tr('重试回复')),
                  onTap: () => Navigator.pop(sheet, 'retry'),
                ),
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: Text(context.tr('复制消息')),
                onTap: () => Navigator.pop(sheet, 'copy'),
              ),
              if (!row.user &&
                  row.activity == null &&
                  gatewayReady &&
                  speechText(row.body).isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.volume_up_outlined),
                  title: Text(context.tr('朗读回复')),
                  onTap: () => Navigator.pop(sheet, 'read'),
                ),
              if (bookmark != null)
                ListTile(
                  leading: Icon(
                    saved
                        ? Icons.bookmark_remove_outlined
                        : Icons.bookmark_add_outlined,
                  ),
                  title: Text(saved ? context.tr('移除书签') : context.tr('添加书签')),
                  onTap: () => Navigator.pop(sheet, 'bookmark'),
                ),
              if (canBranch)
                ListTile(
                  leading: const Icon(Icons.call_split_rounded),
                  title: Text(context.tr('从这里分叉')),
                  onTap: () => Navigator.pop(sheet, 'branch'),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'bookmark' && bookmark != null) {
      try {
        final added = await book.setSaved(bookmark, saved: !saved);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                added ? context.tr('已添加消息书签') : context.tr('已移除消息书签'),
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) setState(() => error = e.toString());
      }
      return;
    }
    if (action == 'edit' || action == 'retry') {
      await startRewrite(row, retry: action == 'retry', history: history);
    } else if (action == 'branch') {
      await branchAt(row);
    } else if (action == 'read') {
      readReply(row.body);
    } else if (action == 'copy') {
      await copyMobileText(context, row.body, '已复制消息');
    }
  }

  Future<bool> stop() async {
    final sid = runtime;
    if (sid == null || stopping || !running || !gatewayReady) return false;
    setState(() => stopping = true);
    try {
      await widget.gateway.call('session.interrupt', {
        'session_id': sid,
        'profile': widget.profile,
        if (widget.gateway.canonical)
          'execution_generation': modelControls?.version?.generation ?? 0,
      });
      return true;
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
      return false;
    } finally {
      if (mounted) setState(() => stopping = false);
    }
  }

  Future<void> send() async {
    final original = draft.text;
    var caption = original.trim();
    final selectedPictures = List<XFile>.of(pictures);
    final selectedFiles = List<XFile>.of(files);
    if (busy ||
        _composing(draft.value) ||
        composerBusy ||
        !gatewayReady ||
        unconfirmedSend != null ||
        slashPending ||
        rewrite != null ||
        readOnly ||
        hydrating ||
        modelStatus != null ||
        (caption.isEmpty &&
            selectedPictures.isEmpty &&
            selectedFiles.isEmpty)) {
      return;
    }
    if (selectedPictures.length > composerPhotoLimit) {
      setState(() => composerError = '一次最多发送 10 张图片');
      return;
    }
    if (selectedPictures.isEmpty &&
        selectedFiles.isEmpty &&
        voice.stopWithPhrase(caption)) {
      draft.clear();
      await widget.onFlushDraft?.call();
      return;
    }
    final busyText = canSendBusyText(
      caption,
      hasAttachments: selectedFiles.isNotEmpty || selectedPictures.isNotEmpty,
    );
    voice.cancel();
    if (queuesDraft && !busyText) {
      if (selectedPictures.isEmpty &&
          selectedFiles.isEmpty &&
          parseSlashInput(caption)?.name == 'agents') {
        await prepareSlash(original);
      } else {
        await enqueueFollowup(original, selectedFiles, selectedPictures);
      }
      return;
    }
    String? commandDisplay;
    if (selectedPictures.isEmpty &&
        selectedFiles.isEmpty &&
        caption.startsWith('/')) {
      final command = await prepareSlash(original);
      if (!mounted || (command != null && command.prompt == null)) return;
      caption = command?.prompt ?? caption;
      commandDisplay = command?.display;
    }
    await submitMessage(
      original: original,
      caption: caption,
      selectedFiles: selectedFiles,
      selectedPictures: selectedPictures,
      commandDisplay: commandDisplay,
      busyText: busyText,
    );
  }

  Future<bool> submitMessage({
    required String original,
    required String caption,
    List<XFile> selectedFiles = const [],
    List<XFile> selectedPictures = const [],
    String? commandDisplay,
    _VoiceReply? voiced,
    bool busyText = false,
  }) async {
    bool active() => mounted && (voiced == null || voiced.isCurrent());
    if (runtime == null) {
      await open();
      if (!active() ||
          runtime == null ||
          running ||
          rewrite != null ||
          unconfirmedSend != null) {
        return false;
      }
    }
    final store = submissionStore;
    if (store == null || unconfirmedSend != null || !active()) return false;
    final session = runtime!;
    final revision = linkRevision;
    final canonical = widget.gateway.canonical;
    final generation = executionGeneration;
    final epoch = sessionEpoch;
    final initialTurn = turn;
    final initialCompletion = completedTurns;
    bool sameTurn() =>
        turn == initialTurn && completedTurns == initialCompletion;
    bool sameConnection() =>
        mounted && linkRevision == revision && runtime == session;
    bool readyToSubmit() =>
        sameConnection() && gatewayReady && (!running || busyText);
    bool canCorrect() =>
        sameTurn() &&
        canSendBusyText(caption, hasAttachments: false) &&
        (!canonical || executionGeneration == generation);
    setState(() {
      busy = true;
      error = null;
    });
    final control = beginUpload(selectedFiles, selectedPictures);
    FollowupDraft? retained;
    ChatRow? optimistic;
    try {
      final mode = busyText && canonical && generation != null
          ? await BusyInputSettings(widget.gateway, widget.profile).read()
          : null;
      final correction = mode?.correction;
      if (!active()) return false;
      if (!readyToSubmit()) throw GatewayDisconnected();
      if (voiced == null &&
          draft.text == original &&
          draftStamp == null &&
          original.isNotEmpty) {
        draftStamp = const Uuid().v4();
        widget.onDraft?.call(original, draftStamp);
      }
      final originalStamp = voiced == null && draft.text == original
          ? draftStamp
          : null;
      await widget.onFlushDraft?.call();
      if (!active()) return false;
      control?.throwIfCancelled();
      retained = (await store.add(
        original,
        selectedFiles,
        null,
        pictures: selectedPictures,
        draftStamp: originalStamp,
        composerInputs: composerInputIds(selectedFiles, selectedPictures),
      )).single;
      if (!active()) {
        if (voiced != null) await store.remove(retained.id, allowStaged: true);
        return false;
      }
      final copies = await Future.wait(
        retained.files.map((entry) => store.source(retained!.id, entry)),
      );
      final copiedPictures = await Future.wait(
        retained.pictures.map((entry) => store.source(retained!.id, entry)),
      );
      if (!active()) {
        if (voiced != null) await store.remove(retained.id, allowStaged: true);
        return false;
      }
      if (!readyToSubmit()) throw GatewayDisconnected();
      control?.throwIfCancelled();
      final prepared = await prepareOutbound(
        session,
        caption,
        copies,
        copiedPictures,
        submissionId: retained.id,
        control: control,
      );
      control?.throwIfCancelled();
      endUpload(control);
      if (!active()) {
        if (voiced != null) await store.remove(retained.id, allowStaged: true);
        return false;
      }
      if (prepared == null || !readyToSubmit()) {
        throw GatewayDisconnected();
      }
      final (body, request) = prepared;
      if (voiced != null) {
        if (voiced.voiceContext case final context?) {
          request['surface'] = 'voice-live';
          request['voice_context'] = context;
        } else if (widget.gateway.canonical) {
          request['voice_turn'] = true;
        }
        if (voiced.interrupted && widget.gateway.canonical) {
          request['interrupted'] = true;
        }
      }
      if (correction != null && generation != null && canCorrect()) {
        // A correction has no idempotent submission ID. Keep it recoverable
        // without enabling automatic retry when the reply goes missing.
        retained = (await store.stage(retained, {
          'session_id': session,
        })).single;
        if (active() && readyToSubmit() && canCorrect()) {
          final reply = await sendBusyCorrection(
            correction,
            session,
            generation,
            body,
          );
          if (reply != null) {
            TurnCorrectionScope? savedScope;
            if (mounted &&
                runtime == session &&
                sessionEpoch == epoch &&
                running &&
                sameTurn() &&
                executionGeneration == generation &&
                reply['voice_stopped'] != true) {
              savedScope = await acceptConfirmedCorrection(retained.id, body);
            }
            await confirmRetainedDraft(store, _UnconfirmedSend(retained));
            retained = null;
            if (mounted &&
                savedScope != null &&
                (!running || activeCorrectionScope != savedScope)) {
              pruneConfirmedCorrections(savedScope);
            }
            return true;
          }
        }
        retained = (await store.unstage(retained.id)).single;
        if (!active()) return false;
        if (!readyToSubmit()) throw GatewayDisconnected();
      }
      if (busyText && canonical) {
        // The gateway can start this immediately when idle, or hold it behind
        // a new turn that appears while the submission is being saved.
        request['queued'] = true;
      }
      final persisted = canonical ? request : {'session_id': session};
      retained = (await store.stage(
        retained,
        persisted,
        cursor: canonical ? (epoch: sessionEpoch, sequence: seq) : null,
      )).single;
      if (!active()) {
        if (voiced != null) await store.remove(retained.id, allowStaged: true);
        return false;
      }
      if (!readyToSubmit()) {
        retained = (await store.unstage(retained.id)).single;
        throw GatewayDisconnected();
      }
      voiced?.submission = retained.id;
      voiced?.session = stored ?? widget.id;
      voiced?.cursor = retained.cursor;
      final busyAtDispatch = running;
      if (busyText && !canonical && !canCorrect()) {
        request['queued'] = true;
      }
      if (!busyAtDispatch) {
        returnToLatest();
        setState(() => optimistic = addPendingEcho(commandDisplay ?? body));
      }
      Json receipt;
      try {
        receipt = await widget.gateway.call('prompt.submit', request);
      } on GatewayError catch (failure) {
        final code = failure.code;
        if (code != null &&
            !{4090, 4094}.contains(code) &&
            (code >= 4000 && code < 5000 || code == -32602 || code == -32601)) {
          await store.remove(retained.id, allowStaged: true);
          retained = null;
        }
        rethrow;
      }
      if (!acceptedSubmission(receipt, request)) {
        throw GatewayError('网关未返回发送确认');
      }
      if (busyText &&
          !canonical &&
          receipt['status'] == 'queued' &&
          sameConnection() &&
          widget.keyboardActive) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('消息已加入网关队列'))));
      }
      if (receipt['execution_generation'] case final int admittedGeneration
          when canonical &&
              sameConnection() &&
              sameTurn() &&
              receipt['status'] == 'started') {
        executionGeneration = admittedGeneration;
      }
      if (voiced != null) {
        voiced.admitted = true;
        if (receipt['user_row_id'] case final int userRowId) {
          voiced.userRowId = userRowId;
        }
      }
      if (busyAtDispatch && sameConnection() && running && sameTurn()) {
        switch (receipt['status']) {
          case 'steered' || 'redirected':
            setState(() => rows.add(ChatRow.incomingUser(body, receipt)));
          case 'queued' when canonical:
            setState(() => recordRemoteFollowup(receipt, body));
        }
      }
      if (optimistic != null &&
          mounted &&
          identical(awaitingEcho, optimistic) &&
          (receipt['status'] == 'queued' ||
              receipt['status'] == 'terminal' ||
              receipt['voice_stopped'] == true)) {
        setState(() {
          removePendingEcho(optimistic!);
          running = receipt['status'] == 'queued';
          if (running && widget.gateway.canonical) {
            recordRemoteFollowup(receipt, body);
          }
        });
      }
      final pending = _UnconfirmedSend(
        retained,
        liveInputs: voiced == null
            ? (files: selectedFiles, pictures: selectedPictures)
            : null,
      );
      await confirmRetainedDraft(store, pending);
      retained = null;
      if (voiced != null &&
          (receipt['voice_stopped'] == true ||
              receipt['status'] == 'terminal')) {
        voiced.complete('', finished: receipt['voice_stopped'] == true);
      }
      return true;
    } catch (e) {
      final cancelled = e is FileTransferCancelled;
      if (retained case final record? when voiced == null) {
        if (await discardRedundantPreparation(store, record)) retained = null;
      }
      if (mounted) {
        setState(() {
          if (optimistic != null) removePendingEcho(optimistic!);
          if (retained case final record?) {
            unconfirmedSend = _UnconfirmedSend(
              record,
              liveInputs: voiced == null
                  ? (files: selectedFiles, pictures: selectedPictures)
                  : null,
            );
          }
          error = cancelled ? null : e.toString();
        });
        if (cancelled && widget.keyboardActive) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(context.tr('已取消上传'))));
        }
      }
      return false;
    } finally {
      if (mounted) {
        endUpload(control);
        setState(() => busy = false);
        scheduleFollowupDrain();
      }
    }
  }

  void insertDraftNewline() {
    if (!canEditDraft) return;
    final value = draft.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    draft.value = value
        .replaced(selection, '\n')
        .copyWith(
          selection: TextSelection.collapsed(offset: selection.start + 1),
        );
  }

  bool get canReference =>
      gatewayReady &&
      !busy &&
      !readOnly &&
      !hydrating &&
      !opening &&
      !composerBusy &&
      !slashPending &&
      (isDraftWorkspace || runtime != null);

  @override
  Widget build(BuildContext context) {
    publishConversationActivity();
    final currentRoute = ModalRoute.isCurrentOf(context) != false;
    final compactComposer =
        widget.keyboardActive &&
        currentRoute &&
        (widget.landscapeKeyboard ||
            MediaQuery.orientationOf(context) == Orientation.landscape &&
                MediaQuery.viewInsetsOf(context).bottom > 0);
    fileDrop.update(
      widget.keyboardActive &&
          widget.fileDropActive &&
          currentRoute &&
          gatewayReady &&
          !busy &&
          !composerBusy &&
          !slashPending &&
          !readOnly,
    );
    references.updateScope(
      canReference &&
              widget.keyboardActive &&
              currentRoute &&
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed
          ? (
              profile: widget.profile,
              runtime: runtime,
              cwd: workspaceDir,
              connection: linkRevision,
              canonical: widget.gateway.canonical,
            )
          : null,
    );
    final colors = Theme.of(context).colorScheme;
    final chrome =
        CustomThemeTokens.read(context, ThemeColor.chrome) ?? colors.surface;
    final screen = Scaffold(
      resizeToAvoidBottomInset: currentRoute,
      appBar: buildChatAppBar(
        compact: compactComposer,
        chrome: chrome,
        colors: colors,
      ),
      backgroundColor: colors.surface,
      body: ConversationCanvas(
        child: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: LayoutBuilder(
                builder: (_, bounds) => Column(
                  children: [
                    if (busy) const LinearProgressIndicator(minHeight: 2),
                    Expanded(
                      child:
                          widget.id == null &&
                              runtime == null &&
                              rows.isEmpty &&
                              !busy
                          ? _NewChatStart(
                              recent: widget.recent,
                              onOpen: widget.onOpen,
                            )
                          : TranscriptTextSize(
                              size: appearance.messageSize,
                              child: buildReadingTimeline(),
                            ),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: math.max(
                          0.0,
                          bounds.maxHeight - (bounds.maxHeight >= 240 ? 72 : 2),
                        ),
                      ),
                      child: SingleChildScrollView(
                        primary: false,
                        reverse: true,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (historyError case final message?)
                              TextButton.icon(
                                onPressed: canRetryRecentHistory
                                    ? retryRecentHistory
                                    : null,
                                icon: const Icon(
                                  Icons.refresh_rounded,
                                  size: 18,
                                ),
                                label: Text(context.tr(message)),
                              ),
                            if (gatewayReady &&
                                (opening || hydrating || loadingRecentHistory))
                              LinearProgressIndicator(
                                minHeight: 2,
                                semanticsLabel: context.tr(
                                  loadingRecentHistory ? '正在读取历史消息' : '正在恢复会话',
                                ),
                              ),
                            if (!gatewayReady) connectionNotice(),
                            if (error != null && gatewayReady)
                              buildConversationError(error!, colors),
                            if (rewrite case final Json plan)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  4,
                                  14,
                                  0,
                                ),
                                child: Card(
                                  color: colors.surfaceContainerLow,
                                  elevation: 0,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      8,
                                      12,
                                      3,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          plan['phase'] ==
                                                  RewritePhase.submit.name
                                              ? context.tr('替换消息待确认')
                                              : context.tr('会话更新待确认'),
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall,
                                        ),
                                        Wrap(
                                          alignment: WrapAlignment.end,
                                          children: [
                                            if ({
                                                  'rewind',
                                                  'submit',
                                                }.contains(plan['phase']) ||
                                                plan['phase'] == 'legacy' &&
                                                    plan['legacy_image_count'] ==
                                                        0)
                                              TextButton(
                                                onPressed: idleForRewrite
                                                    ? continueRewrite
                                                    : null,
                                                child: Text(context.tr('继续')),
                                              ),
                                            TextButton(
                                              onPressed: busy
                                                  ? null
                                                  : () async {
                                                      await Clipboard.setData(
                                                        ClipboardData(
                                                          text:
                                                              plan['text']
                                                                  ?.toString() ??
                                                              '',
                                                        ),
                                                      );
                                                    },
                                              child: Text(context.tr('复制内容')),
                                            ),
                                            TextButton(
                                              onPressed: busy
                                                  ? null
                                                  : discardRewrite,
                                              child: Text(context.tr('清除待发内容')),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            if (pendingInteractions.isNotEmpty)
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxHeight: 165,
                                ),
                                child: ListView(
                                  primary: false,
                                  shrinkWrap: true,
                                  padding: EdgeInsets.zero,
                                  children: [
                                    for (final item
                                        in pendingInteractions.values)
                                      InteractionCard(
                                        interaction: item,
                                        onOpen: () => showInteraction(item),
                                      ),
                                  ],
                                ),
                              ),
                            if (taskSnapshot != null &&
                                taskSnapshot!.tasks.isNotEmpty)
                              SessionTasks(
                                snapshot: taskSnapshot!,
                                running: running,
                              ),
                            if (unconfirmedSend case final pending?)
                              unconfirmedNotice(pending),
                            if (workActivity case final monitor?)
                              SessionWorkSummary(
                                key: ValueKey(monitor.service.session),
                                monitor: monitor,
                              ),
                            followupPanel(),
                            voiceStatus(),
                            if ((widget.wake, widget.onWakeSettings) case (
                              final listener?,
                              final settings?,
                            ))
                              WakeIndicator(
                                wake: listener,
                                onSettings: settings,
                              ),
                            if (composerError case final message?)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: Text(
                                  context.tr(message),
                                  style: TextStyle(color: colors.error),
                                ),
                              ),
                            ReferenceSuggestions(references: references),
                            buildComposer(
                              compact: compactComposer,
                              colors: colors,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: MobileShortcut.bind({
        if (widget.keyboardActive) ...{
          MobileShortcut.quickAccess: () => openQuickAccess(focusSearch: true),
          MobileShortcut.newTab: widget.onNew,
          MobileShortcut.settings: openMobileSettings,
          MobileShortcut.closeTab: ?widget.onCloseTab,
          MobileShortcut.reopenTab: ?widget.onReopenTab,
          if (transcriptSession != null) ...{
            MobileShortcut.find: () => exploreTranscript(focusSearch: true),
            MobileShortcut.turns: () => exploreTranscript(turns: true),
          },
          if (hasWorkspace) ...{
            MobileShortcut.workspace: openWorkspace,
            MobileShortcut.review: () =>
                openWorkspace(section: WorkspaceSection.review),
          },
        },
      }),
      child: Focus(
        focusNode: keyboardFocus,
        canRequestFocus: widget.keyboardActive,
        skipTraversal: true,
        autofocus: widget.keyboardActive,
        child: screen,
      ),
    );
  }
}

class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.icon,
    required this.label,
    required this.tap,
    this.badge = 0,
  });
  final IconData icon;
  final String label;
  final VoidCallback? tap;
  final int badge;
  @override
  Widget build(BuildContext context) {
    final glyph = Icon(icon, size: 20);
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: label,
      onPressed: tap,
      icon: badge == 0
          ? glyph
          : ExcludeSemantics(
              child: Badge.count(
                count: badge,
                backgroundColor: colors.primary,
                textColor: colors.onPrimary,
                child: glyph,
              ),
            ),
    );
  }
}
