part of 'chat.dart';

class _VoiceReply {
  _VoiceReply(
    this.caption,
    this.isCurrent, {
    required this.interrupted,
    required this.historyBoundary,
    this.voiceContext,
  });

  final String caption;
  final bool Function() isCurrent;
  final bool interrupted;
  final ChatRow? historyBoundary;
  final String? voiceContext;
  final outcome = Completer<({String? text, String? error})>();
  String? submission, turn, session;
  SubmissionCursor? cursor;
  int? userRowId, assistantRowId;
  bool admitted = false;
  bool interruptionRequested = false;

  void confirmAdmission(Json? completion) {
    admitted = true;
    final receipt = completion?['persisted_turn'];
    if (receipt is! Json) return;
    if (receipt['user_row_id'] case final int id when id > 0) userRowId = id;
    if (receipt['final_assistant_row_id'] case final int id when id > 0) {
      assistantRowId = id;
    }
  }

  void complete(String text, {bool finished = false, String? error}) {
    if (!outcome.isCompleted) {
      outcome.complete((text: finished ? null : text, error: error));
    }
  }
}

class _VoiceRecovery {
  final ready = Completer<bool>();
  late final Timer deadline;
}

extension _ChatVoice on _ChatPageState {
  bool get voiceTabActive =>
      widget.keyboardActive &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      ModalRoute.of(context)?.isCurrent != false;

  bool get canUseVoice => voiceTabActive && gatewayReady && !opening;

  void voiceConnectionLost({required bool retrying}) {
    if (!voice.callActive) {
      voice.cancel();
      return;
    }
    if (!retrying) {
      finishVoiceRecovery(ready: false, reportFailure: true);
      return;
    }
    if (voiceRecovery != null) return;
    final recovery = voiceRecovery = _VoiceRecovery();
    recovery.deadline = Timer(const Duration(seconds: 12), () {
      finishVoiceRecovery(ready: false, timedOut: true, reportFailure: true);
    });
    voice.updateConnection(recovering: true);
  }

  void finishVoiceRecovery({
    required bool ready,
    bool reportFailure = false,
    bool timedOut = false,
  }) {
    final recovery = voiceRecovery;
    voiceRecovery = null;
    recovery?.deadline.cancel();
    recovery?.ready.complete(ready);
    voice.updateConnection(
      recovering: false,
      failure: reportFailure && voice.callActive
          ? timedOut
                ? '语音连接恢复超时'
                : '语音连接已断开'
          : null,
    );
  }

  Future<void> finishVoiceRecoveryAfterHydration() async {
    final recovery = voiceRecovery;
    if (recovery == null || hydrating || recoveringSession) return;
    final link = linkRevision;
    final ready = runtime != null && !readOnly;
    if (ready) await recoverVoiceReply(oldest?.rows ?? const [], const {});
    if (mounted &&
        identical(voiceRecovery, recovery) &&
        linkRevision == link &&
        !hydrating &&
        !recoveringSession) {
      finishVoiceRecovery(ready: ready, reportFailure: !ready);
    }
  }

  Future<bool> waitForVoiceConnection(bool Function() current) async {
    if (!current()) return false;
    if (!gatewayReady && widget.gateway.link == GatewayLink.reconnecting) {
      voiceConnectionLost(retrying: true);
    }
    final recovery = voiceRecovery;
    if (recovery != null && !await recovery.ready.future) return false;
    return current() && gatewayReady && !hydrating;
  }

  void showVoiceNotice(String notice) {
    if (mounted && voiceTabActive && voice.callActive) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.tr(notice))));
    }
  }

  bool get canStartVoiceCall =>
      canUseVoice &&
      !queuesDraft &&
      !busy &&
      !hydrating &&
      !readOnly &&
      !composerBusy &&
      !slashPending &&
      modelStatus == null &&
      rewrite == null &&
      unconfirmedSend == null &&
      pendingInteractions.isEmpty;

  Future<void> startVoiceCall() => withVoiceDevice(() async {
    if (!canStartVoiceCall) return;
    bool current() => mounted && voiceTabActive && voice.callActive;
    FocusManager.instance.primaryFocus?.unfocus();
    final fallback = context.tr('GPT-Live 不可用，已使用语音转文字');
    try {
      await voice.converse(
        submit: (text, interrupted, voiceContext) =>
            _sendVoiceTurn(text, interrupted, voiceContext, current),
        interrupt: () async {
          if (!await waitForVoiceConnection(current) || !running || stopping) {
            return false;
          }
          if (pendingVoiceReply case final reply?) {
            reply.interruptionRequested = true;
          }
          return await stop() && current();
        },
        spokenText: speechText,
        delegationFailure: context.tr('Hermes 暂时无法完成此请求。'),
        liveHistory: liveVoiceHistory,
        onNotice: showVoiceNotice,
        preferLive: !MobileAppearance.shared.voiceEngineChosen,
        unavailable: () {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(fallback)));
          }
        },
      );
    } finally {
      finishVoiceRecovery(ready: false);
      pendingVoiceReply?.complete('', finished: true);
    }
  });

  Future<void> withVoiceDevice(Future<void> Function() action) async {
    if (!canUseVoice || voiceBorrowing || voice.phase != VoicePhase.idle) {
      return;
    }
    final wake = widget.wake;
    final link = linkRevision;
    voiceBorrowing = true;
    try {
      await wake?.borrowMicrophone();
      if (mounted && canUseVoice && linkRevision == link) await action();
    } finally {
      voiceBorrowing = false;
      wake?.returnMicrophone();
    }
  }

  void scheduleWakeLaunch() {
    final ticket = widget.wakeLaunch;
    if (ticket == null || identical(scheduledWakeLaunch, ticket)) return;
    scheduledWakeLaunch = ticket;
    final handled = widget.onWakeLaunchHandled;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_acceptWakeLaunch(ticket, handled));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _acceptWakeLaunch(
    Object ticket,
    ValueChanged<Object>? handled,
  ) async {
    bool active() =>
        mounted &&
        widget.keyboardActive &&
        identical(widget.wakeLaunch, ticket) &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        ModalRoute.of(context)?.isCurrent != false;
    final wait = Stopwatch()..start();
    try {
      while (active() && wait.elapsed < const Duration(seconds: 8)) {
        if (canStartVoiceCall && !voiceBorrowing) {
          await startVoiceCall();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (mounted && active()) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('请等待当前会话就绪'))));
      }
    } finally {
      handled?.call(ticket);
    }
  }

  List<Json> liveVoiceHistory() => rows.reversed
      .where(
        (row) =>
            row.activity == null &&
            row.commandReceipt == null &&
            row.backgroundNotice == null,
      )
      .map((row) => (user: row.user, text: speechText(row.body)))
      .where((row) => row.text.isNotEmpty)
      .take(12)
      .map(
        (row) => liveVoiceHistoryItem(
          row.user,
          String.fromCharCodes(row.text.runes.take(1000)),
        ),
      )
      .toList()
      .reversed
      .toList();

  Future<String?> _sendVoiceTurn(
    String text,
    bool interrupted,
    String? voiceContext,
    bool Function() current,
  ) async {
    if (!await waitForVoiceConnection(current)) return null;
    if (!canStartVoiceCall) throw GatewayError('请等待当前会话就绪');
    final pending = pendingVoiceReply = _VoiceReply(
      text,
      current,
      interrupted: interrupted,
      historyBoundary: rows.reversed.where(_isStoredMessage).firstOrNull,
      voiceContext: voiceContext,
    );
    final submittedOn = linkRevision;
    try {
      final sent = await submitMessage(
        original: text,
        caption: text,
        voiced: pending,
      );
      if (!current()) return null;
      if (!sent) {
        final recovered =
            (linkRevision != submittedOn ||
                widget.gateway.link == GatewayLink.reconnecting) &&
            await waitForVoiceConnection(current);
        if (!current()) return null;
        if (!recovered ||
            !pending.admitted ||
            unconfirmedSend?.record.id == pending.submission) {
          throw GatewayError(error ?? '无法发送语音消息');
        }
      }
      final reply = await pending.outcome.future.timeout(
        const Duration(minutes: 10),
      );
      if (!pending.interruptionRequested && reply.error != null) {
        throw GatewayError(reply.error!);
      }
      return reply.text;
    } on TimeoutException {
      throw GatewayError('等待 Hermes 回复超时');
    } finally {
      if (identical(pendingVoiceReply, pending)) pendingVoiceReply = null;
    }
  }

  Future<void> recoverVoiceReply(List<Json> history, Json snapshot) async {
    final pending = pendingVoiceReply;
    final id = pending?.submission;
    if (voiceRecovery == null ||
        pending == null ||
        id == null ||
        pending.outcome.isCompleted ||
        pending.session != stored) {
      return;
    }
    final exact = admittedSubmissionIds(snapshot, history).contains(id);
    pending.admitted = pending.admitted || exact;
    if (running || hydrating || !pending.admitted) return;

    final messages = displayRows(history).where(_isStoredMessage).toList();
    if (pending.assistantRowId case final id?) {
      final recovery = voiceRecovery;
      final link = linkRevision;
      bool current() =>
          mounted &&
          link == linkRevision &&
          identical(voiceRecovery, recovery) &&
          identical(pendingVoiceReply, pending) &&
          !pending.outcome.isCompleted &&
          pending.isCurrent();
      var reply = messages
          .where((row) => !row.user && row.rowId == id)
          .firstOrNull
          ?.body;
      if (stored case final session? when reply == null) {
        try {
          final gateway = widget.gateway;
          final profile = widget.profile;
          final promptId = pending.userRowId;
          final rows = promptId == null
              ? (await gateway.historyPage(profile, session, 0)).rows
              : (await TranscriptNavigation(gateway, profile, session).locate(
                  MessageAddress(id, promptId: promptId),
                  stillOpen: current,
                  scanHistory: false,
                )).rows;
          reply = displayRows(rows)
              .where(
                (row) => _isStoredMessage(row) && !row.user && row.rowId == id,
              )
              .firstOrNull
              ?.body;
        } on GatewayError {
          // The confirmed reply may be unavailable in the current history.
        } on TimeoutException {
          // Let the call continue without playing an unrelated reply.
        }
      }
      if (!current()) return;
      if (reply == null) showVoiceNotice('未能确认断线前的语音回复');
      pending.complete(reply ?? '');
      return;
    }

    final userRow =
        pending.userRowId ??
        history
            .where(
              (row) =>
                  row['role'] == 'user' &&
                  admittedSubmissionIds(row, const []).contains(id),
            )
            .map(historyRowId)
            .nonNulls
            .firstOrNull;
    final boundary = pending.historyBoundary;
    final start = messages.indexWhere(
      (row) => row.rowId != null && row.rowId == boundary?.rowId,
    );
    final matches = [
      for (var index = 0; index < messages.length; index++)
        if (messages[index].user &&
            (userRow != null
                ? messages[index].rowId == userRow
                : (start >= 0 && index > start ||
                          boundary == null && oldest?.nextOffset == null) &&
                      messages[index].body.trim() == pending.caption.trim()))
          index,
    ];
    final reply = matches.length == 1
        ? messages
              .skip(matches.single + 1)
              .takeWhile((row) => !row.user)
              .lastOrNull
              ?.body
        : null;
    if (reply == null) showVoiceNotice('未能确认断线前的语音回复');
    pending.complete(reply ?? '');
  }

  void identifyVoiceTurn(Json payload, String? id) {
    final pending = pendingVoiceReply;
    if (pending == null || pending.submission == null || id == null) return;
    final submitted = payload['submission_id'];
    if (submitted is String && submitted != pending.submission) return;
    final text = messageBody(payload['text']);
    if (submitted == null && text.isNotEmpty && text != pending.caption) return;
    if (payload['user_row_id'] case final int userRowId) {
      pending.userRowId = userRowId;
    }
    pending.turn = id;
  }

  bool settleVoiceReply(Json payload, String text, {bool failed = false}) {
    final pending = pendingVoiceReply;
    if (pending == null || pending.submission == null) return false;
    final persisted = payload['persisted_turn'];
    final submitted =
        payload['submission_id'] ??
        (persisted is Json ? persisted['submission_id'] : null);
    if (submitted is String &&
        submitted.isNotEmpty &&
        submitted != pending.submission) {
      return false;
    }
    final id = payload['turn_id'];
    if (pending.turn != null &&
        id is String &&
        id.isNotEmpty &&
        id != pending.turn) {
      return false;
    }
    if (!failed && submitted == pending.submission) {
      pending.confirmAdmission(payload);
    }
    final failure =
        payload['error'] ?? (failed ? payload['message'] ?? '回复失败' : null);
    pending.complete(
      text.isNotEmpty ? text : live.value,
      error: failure is String && failure.isNotEmpty ? failure : null,
    );
    return true;
  }

  Future<void> dictate() => withVoiceDevice(() async {
    if (!canUseVoice || readOnly || busy) return;
    final text = await voice.dictate();
    if (!mounted || text == null || !canUseVoice || readOnly) return;
    final edit = draft.value;
    final selection = edit.selection.isValid
        ? edit.selection
        : TextSelection.collapsed(offset: edit.text.length);
    draft.value = edit
        .replaced(selection, text)
        .copyWith(
          selection: TextSelection.collapsed(
            offset: selection.start + text.length,
          ),
          composing: TextRange.empty,
        );
    draftFocus.requestFocus();
  });

  void readReply(String body) {
    if (!canUseVoice || voice.inCall) return;
    final text = speechText(body);
    if (text.isEmpty) return;
    if (voice.readingReply) {
      unawaited(voice.speak(text));
    } else {
      unawaited(withVoiceDevice(() => voice.speak(text)));
    }
  }

  Future<void> openVoiceEngine() => showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Colors.black.withValues(alpha: .18),
    builder: (_) =>
        _VoiceEngineSheet(gateway: widget.gateway, profile: widget.profile),
  );

  Widget voiceButtons(ColorScheme colors) => ListenableBuilder(
    listenable: voice,
    builder: (context, _) {
      final recording = voice.phase == VoicePhase.recording;
      if (voice.inCall) return const SizedBox.shrink();
      final idle = voice.phase == VoicePhase.idle;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: context.tr(recording ? '转写录音' : '语音听写'),
            onPressed: recording
                ? voice.finishDictation
                : idle &&
                      gatewayReady &&
                      !busy &&
                      !hydrating &&
                      !composerBusy &&
                      !slashPending &&
                      !readOnly
                ? dictate
                : null,
            icon: Icon(
              recording ? Icons.check_rounded : Icons.mic_none_rounded,
              size: 22,
              color: recording ? colors.primary : null,
            ),
          ),
          IconButton(
            tooltip: context.tr('开始语音对话'),
            onPressed: idle && canStartVoiceCall ? startVoiceCall : null,
            icon: const Icon(Icons.graphic_eq_rounded, size: 22),
          ),
        ],
      );
    },
  );

  Widget voiceStatus() => ListenableBuilder(
    listenable: voice,
    builder: (context, _) {
      final phase = voice.phase;
      final error = voice.error;
      // Calls and dictation have their own views; this row only reports
      // read-aloud progress and errors left behind once voice goes idle.
      if (phase == VoicePhase.idle && error == null ||
          voice.inCall ||
          phase == VoicePhase.opening ||
          phase == VoicePhase.recording ||
          phase == VoicePhase.transcribing) {
        return const SizedBox.shrink();
      }
      final label =
          error ??
          (voice.reconnecting
              ? '正在恢复语音连接…'
              : switch (phase) {
                  VoicePhase.idle => '',
                  VoicePhase.opening => voice.inCall ? '正在启动语音…' : '正在打开麦克风…',
                  VoicePhase.recording => '正在录音',
                  VoicePhase.listening => voice.muted ? '麦克风已静音' : '正在听你说话…',
                  VoicePhase.transcribing => '正在转写…',
                  VoicePhase.waiting => '正在等待 Hermes 回复…',
                  VoicePhase.preparing => '正在生成朗读音频…',
                  VoicePhase.playing => '正在朗读',
                });
      final color = Theme.of(context).colorScheme;
      final pending = switch (phase) {
        VoicePhase.opening ||
        VoicePhase.transcribing ||
        VoicePhase.preparing => true,
        _ => false,
      };
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 9),
              child: pending
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      error != null
                          ? Icons.error_outline_rounded
                          : phase == VoicePhase.recording
                          ? Icons.fiber_manual_record
                          : Icons.volume_up_outlined,
                      size: 16,
                      color: error != null ? color.error : color.primary,
                    ),
            ),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  context.tr(label),
                  style: TextStyle(
                    color: error != null ? color.error : color.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: context.tr(
                error != null
                    ? '关闭'
                    : phase == VoicePhase.playing
                    ? '停止朗读'
                    : '取消',
              ),
              onPressed: error != null ? voice.dismissError : voice.cancel,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
          ],
        ),
      );
    },
  );
}

class _VoiceEngineSheet extends StatefulWidget {
  const _VoiceEngineSheet({required this.gateway, required this.profile});
  final Gateway gateway;
  final String profile;

  @override
  State<_VoiceEngineSheet> createState() => _VoiceEngineSheetState();
}

class _VoiceEngineSheetState extends State<_VoiceEngineSheet> {
  late Future<VoiceEngineStatus> status = VoiceEngineStatus.read(
    widget.gateway,
    widget.profile,
  );
  bool saving = false;
  String? error;

  Future<void> select(bool live) async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await VoiceEngineStatus.select(
        widget.gateway,
        widget.profile,
        live: live,
      );
      await MobileAppearance.shared.markVoiceEngineChosen();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => error = '未能切换语音引擎');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: GlassSurface(
          radius: 30,
          opacity: theme.brightness == Brightness.dark ? .82 : .9,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
          child: FutureBuilder<VoiceEngineStatus>(
            future: status,
            builder: (context, snapshot) {
              final modes = snapshot.data;
              // GPT-Live is the default until the user picks an engine here.
              final live =
                  modes != null &&
                  modes.liveAvailable &&
                  (modes.liveSelected ||
                      !MobileAppearance.shared.voiceEngineChosen);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: colors.onSurfaceVariant.withValues(alpha: .25),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 14),
                    child: Text(
                      context.tr('语音引擎'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (snapshot.hasError)
                    ListTile(
                      title: Text(context.tr('无法读取语音引擎')),
                      trailing: TextButton(
                        onPressed: () => setState(
                          () => status = VoiceEngineStatus.read(
                            widget.gateway,
                            widget.profile,
                          ),
                        ),
                        child: Text(context.tr('重试')),
                      ),
                    )
                  else if (modes == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else ...[
                    _EngineCard(
                      icon: Icons.auto_awesome_rounded,
                      title: 'GPT-Live',
                      subtitle: context.tr(
                        modes.liveAvailable
                            ? '实时双向语音，可随时打断，复杂请求交给 Hermes 处理'
                            : modes.supported
                            ? '当前档案的 GPT-Live 不可用'
                            : '网关未提供此语音功能',
                      ),
                      badge: context.tr('默认'),
                      selected: live,
                      onTap: saving || !modes.liveAvailable
                          ? null
                          : () => select(true),
                    ),
                    const SizedBox(height: 10),
                    _EngineCard(
                      icon: Icons.graphic_eq_rounded,
                      title: context.tr('语音转文字'),
                      subtitle: context.tr('说完一句后转写发送，回复再朗读出来'),
                      selected: !live,
                      onTap: saving ? null : () => select(false),
                    ),
                  ],
                  if (saving)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (error case final message?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
                      child: Text(
                        context.tr(message),
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _EngineCard extends StatelessWidget {
  const _EngineCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title, subtitle;
  final String? badge;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Opacity(
      opacity: onTap == null && !selected ? .45 : 1,
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: .1)
            : colors.onSurface.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.primary
                        : colors.onSurface.withValues(alpha: .07),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 21,
                    color: selected ? colors.onPrimary : colors.onSurface,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (badge case final label?) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: colors.primary.withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: colors.primary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 22,
                  color: selected ? colors.primary : colors.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
