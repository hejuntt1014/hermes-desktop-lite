part of 'chat.dart';

const _turnSilenceInterval = Duration(seconds: 20);

bool _continuousReply(Iterable<Json> frames) {
  int? segment;
  var offset = 0;
  for (final frame in frames) {
    final payload = frame['payload'];
    if (payload is! Json) continue;
    final wireSegment = payload['segment'];
    final nextSegment = wireSegment is int ? wireSegment : null;
    if (nextSegment != null && segment != null && nextSegment < segment) {
      continue;
    }
    switch (frame['type']) {
      case 'message.interim':
        segment = nextSegment == null ? null : nextSegment + 1;
        offset = 0;
      case 'message.delta':
        final chunk = payload['text'];
        if (chunk == null && payload.containsKey('text')) {
          if (nextSegment != null && nextSegment != segment) offset = 0;
          segment = nextSegment ?? segment;
          continue;
        }
        if (chunk is! String) continue;
        if (nextSegment != null && segment != null && nextSegment > segment) {
          offset = 0;
        }
        segment = nextSegment ?? segment;
        final wireOffset = payload['offset'];
        final start = wireOffset is int ? wireOffset : offset;
        if (start > offset) return false;
        offset = math.max(offset, start + chunk.length);
    }
  }
  return true;
}

class _UnconfirmedSend {
  const _UnconfirmedSend(this.record, {this.liveInputs});

  final FollowupDraft record;
  final ({List<XFile> files, List<XFile> pictures})? liveInputs;
}

extension _ChatReconnect on _ChatPageState {
  void clearReplyGap() {
    replyGapAfter = null;
  }

  bool canApplyReplyDelta(Json payload) {
    if (replyGap) return false;
    final nextSegment = payload['segment'];
    final currentSegment = segment;
    if (nextSegment is int &&
        currentSegment != null &&
        nextSegment < currentSegment) {
      return true;
    }
    final expected =
        nextSegment is int &&
            currentSegment != null &&
            nextSegment > currentSegment
        ? 0
        : replyOffset;
    final offset = payload['offset'];
    if (offset is! int || offset <= expected) return true;
    // Do not advance the replay cursor past a missing part of the reply.
    replyGapAfter = seq;
    if (!running) updateSlash(() => running = true);
    unawaited(requestSessionRecovery());
    return false;
  }

  Future<void> fillPeerPrompt() async {
    final session = runtime;
    if (session == null || opening || !gatewayReady) return;
    final ticket = peerPromptTicket = Object();
    final link = linkRevision;
    final started = turn;
    final boundary = rows.lastOrNull;
    final history = historyTail;
    bool current() =>
        mounted &&
        peerPromptTicket == ticket &&
        linkRevision == link &&
        runtime == session &&
        gatewayReady &&
        !opening &&
        historyTail == history;
    try {
      // Older gateways can announce the turn before they set its inflight text.
      for (final delay in const [
        Duration.zero,
        Duration(milliseconds: 150),
        Duration(milliseconds: 400),
      ]) {
        if (delay != Duration.zero) await Future<void>.delayed(delay);
        if (!current() || !running) return;
        final snapshot = await widget.gateway.call('session.activate', {
          'session_id': session,
          'profile': widget.profile,
          'omit_messages': true,
        }, timeout: const Duration(seconds: 6));
        if (!current() || snapshot['session_id'] != session) return;
        final inflight = snapshot['inflight'];
        if (inflight is! Json ||
            snapshot['running'] == false ||
            inflight['status'] == 'error') {
          continue;
        }
        if (inflight['display_kind'] == 'hidden') return;
        final snapTurn = inflight['turn_id'];
        if (started != null && snapTurn is String && snapTurn != started) {
          continue;
        }
        final prompt = ChatRow.visibleIncomingUser(inflight['user'], inflight);
        if (prompt == null) continue;
        final index = boundary == null ? 0 : rows.indexOf(boundary) + 1;
        if (boundary != null && index == 0) return;
        updateSlash(() {
          rows.insert(index, prompt);
          if (_countsConversationMessage(prompt)) noteNewMessage();
        });
        return;
      }
    } catch (_) {
      // The next history refresh can still supply the persisted prompt.
    } finally {
      if (peerPromptTicket == ticket) peerPromptTicket = null;
    }
  }

  TurnCorrectionScope? get activeCorrectionScope {
    final id = runtime;
    final generation = executionGeneration;
    if (id == null || generation == null || sessionEpoch.isEmpty) return null;
    return (runtime: id, epoch: sessionEpoch, generation: generation);
  }

  void clearConfirmedCorrections() {
    correctionScope = null;
    confirmedCorrections.clear();
  }

  TurnCorrections? get correctionStore {
    final id = widget.id ?? stored;
    return id == null
        ? null
        : TurnCorrections(widget.gateway, widget.profile, id);
  }

  Future<TurnCorrectionRecord?> loadConfirmedCorrections() async {
    if (!widget.gateway.canonical) return null;
    try {
      return await correctionStore?.read();
    } catch (_) {
      return null;
    }
  }

  void applyConfirmedCorrections(TurnCorrectionRecord? saved) {
    final scope = running ? activeCorrectionScope : null;
    if (scope == null || scope != correctionScope) clearConfirmedCorrections();
    if (scope == null || saved?.scope != scope) return;
    correctionScope = scope;
    final known = {
      for (final entry in saved!.entries) entry.id: entry,
      for (final entry in confirmedCorrections) entry.id: entry,
    };
    confirmedCorrections
      ..clear()
      ..addAll(known.values);
  }

  void pruneConfirmedCorrections(TurnCorrectionScope scope) {
    unawaited(correctionStore?.clear(scope).catchError((Object _) {}));
  }

  void settleConfirmedCorrections() {
    final scope = correctionScope;
    clearConfirmedCorrections();
    // An in-flight send must record its acknowledgement before removal.
    if (!busy && unconfirmedSend == null && scope != null) {
      pruneConfirmedCorrections(scope);
    }
  }

  Future<TurnCorrectionScope?> acceptConfirmedCorrection(
    String id,
    String text,
  ) async {
    final scope = activeCorrectionScope;
    final correction = (
      id: id,
      sequence: seq,
      text: text,
      precedingReply: live.value,
    );
    updateSlash(() {
      if (scope != null) {
        if (correctionScope != scope) clearConfirmedCorrections();
        correctionScope = scope;
        confirmedCorrections.add(correction);
      }
      appendCorrection(text);
    });
    if (scope != null) {
      await correctionStore?.append(scope, correction);
    }
    return scope;
  }

  void appendCorrection(String text) {
    restoredAssistantPrefix += live.value;
    seal(keepOffset: true);
    rows.add(ChatRow.incomingUser(text, const {}));
  }

  void restoreConfirmedCorrections() {
    if (correctionScope == null || activeCorrectionScope != correctionScope) {
      return;
    }
    for (final correction in confirmedCorrections) {
      if (correction.precedingReply.isNotEmpty) {
        rows.add(ChatRow(user: false, body: correction.precedingReply));
      }
      rows.add(ChatRow.incomingUser(correction.text, const {}));
    }
  }

  bool get watchesTurn {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        gatewayReady &&
        runtime != null &&
        !readOnly &&
        (running || remoteFollowups.isNotEmpty) &&
        (unsupportedTurnRosterLink != linkRevision ||
            unsupportedTurnReplayLink != linkRevision);
  }

  bool get canCheckTurn =>
      watchesTurn &&
      !busy &&
      !opening &&
      !hydrating &&
      !loadingOlder &&
      !stopping &&
      !queueDraining &&
      unconfirmedSend == null &&
      rewrite == null;

  void suspendTurnCheck() {
    turnActivityRevision++;
    turnSilence.reset();
    turnCheckTimer?.cancel();
    turnCheckTimer = null;
  }

  void noteTurnActivity() {
    turnActivityRevision++;
    turnSilence.reset();
    scheduleTurnCheck();
  }

  void scheduleTurnCheck({bool verifyIdle = false}) {
    if (!watchesTurn) {
      turnCheckTimer?.cancel();
      turnCheckTimer = null;
      return;
    }
    if (checkingTurn) return;
    if (verifyIdle) {
      turnCheckTimer?.cancel();
      final activity = turnActivityRevision;
      // Let the completion frame arrive before probing an idle owner.
      turnCheckTimer = Timer(const Duration(milliseconds: 350), () {
        turnCheckTimer = null;
        if (activity == turnActivityRevision) {
          unawaited(checkSilentTurn());
        } else {
          scheduleTurnCheck();
        }
      });
      return;
    }
    if (turnCheckTimer != null) return;
    final remaining = _turnSilenceInterval - turnSilence.elapsed;
    turnCheckTimer = Timer(remaining, () {
      turnCheckTimer = null;
      if (turnSilence.elapsed >= _turnSilenceInterval) {
        unawaited(checkSilentTurn());
      } else {
        scheduleTurnCheck();
      }
    });
  }

  Future<String?> _silentTurnStatus(
    String session,
    int connection,
    bool Function() current,
  ) async {
    if (unsupportedTurnRosterLink == connection) return null;
    final Json result;
    try {
      result = await widget.gateway.call('session.active_list', {
        'profile': widget.profile,
        'current_session_id': session,
      }, timeout: const Duration(seconds: 8));
    } on GatewayError catch (failure) {
      if (failure.code != -32601) rethrow;
      if (current()) unsupportedTurnRosterLink = connection;
      return null;
    }
    final entries = result['sessions'];
    if (!current() ||
        entries is! List ||
        entries.any((entry) => entry is! Json || entry['id'] is! String)) {
      return null;
    }
    final row = entries.whereType<Json>().where((entry) {
      return entry['id'] == session &&
          (entry['profile'] == null || entry['profile'] == widget.profile);
    }).firstOrNull;
    if (row == null) return 'idle';
    final status = row['status'];
    return status is String ? status : null;
  }

  Future<void> checkSilentTurn() async {
    if (checkingTurn) return;
    if (!canCheckTurn) {
      turnSilence.reset();
      scheduleTurnCheck();
      return;
    }
    final session = runtime!;
    final link = linkRevision;
    final activity = turnActivityRevision;
    final sequence = seq;
    bool current() =>
        canCheckTurn &&
        runtime == session &&
        linkRevision == link &&
        turnActivityRevision == activity &&
        seq == sequence;
    checkingTurn = true;
    try {
      final status = await _silentTurnStatus(session, link, current);
      if (!current()) return;
      if (status == 'idle' ||
          status == 'waiting' && pendingInteractions.isEmpty ||
          !running &&
              const {'working', 'starting', 'running'}.contains(status)) {
        await requestSessionRecovery();
        return;
      }
      if (sequence <= 0 || unsupportedTurnReplayLink == link) return;
      final Json replay;
      try {
        replay = await widget.gateway.call('session.events.since', {
          'session_id': session,
          'profile': widget.profile,
          'last_seen': replyGapAfter ?? sequence,
          if (sessionEpoch.isNotEmpty) 'replay_epoch': sessionEpoch,
        }, timeout: const Duration(seconds: 5));
      } on GatewayError catch (failure) {
        if (failure.code != -32601) rethrow;
        if (current()) unsupportedTurnReplayLink = link;
        return;
      }
      if (!current()) return;
      final missed = replay['events'];
      final epoch = replay['replay_epoch'] ?? replay['epoch'];
      final requests = replay['open_requests'];
      final missedRequest =
          requests is List &&
          requests.whereType<Json>().any((request) {
            final owned = ownedInteractionRequest(request);
            return owned != null &&
                pendingInteractions[owned.key]?.requestId != owned.requestId;
          });
      if (replay['snapshot_required'] == true ||
          replay['truncated'] == true ||
          epoch is String &&
              epoch.isNotEmpty &&
              sessionEpoch.isNotEmpty &&
              epoch != sessionEpoch ||
          missed is List && missed.isNotEmpty ||
          missedRequest) {
        await requestSessionRecovery();
      }
    } catch (_) {
      // A failed probe must leave the visible turn and queue intact.
    } finally {
      checkingTurn = false;
      turnSilence.reset();
      scheduleTurnCheck();
    }
  }

  bool get gatewayReady =>
      widget.gateway.usable && !recoveringSession && !sessionRecoveryDeferred;

  bool get needsImmediateRecovery =>
      widget.keyboardActive ||
      opening ||
      busy ||
      running ||
      recoveringSession ||
      recoveryRequested ||
      modelStatus != null ||
      unconfirmedSend != null ||
      rewrite != null ||
      queueDraining ||
      followups.isNotEmpty ||
      remoteFollowups.isNotEmpty ||
      workActivity?.hasWork == true ||
      widget.notificationTarget != null;

  void resumeSessionConnection() {
    unawaited(profileReasoning.refresh(force: true));
    unawaited(requestSessionRecovery());
  }

  void onConnectionEvent(Json event) {
    final payload = event['payload'];
    if (payload is! Json) return;
    linkRevision++;
    interactiveHistoryRead?.cancel();
    stopAdjacentHistoryRead();
    if (payload['state'] == 'online') {
      final resumed = payload['resumed'] == true;
      if (resumed && !needsImmediateRecovery && transcriptSession != null) {
        updateSlash(() => sessionRecoveryDeferred = true);
      } else if (resumed) {
        resumeSessionConnection();
      } else {
        updateSlash(() {});
      }
    } else {
      voiceConnectionLost(retrying: payload['state'] == 'reconnecting');
      sessionApprovalBypass.value = null;
      updateSlash(() {
        pendingInteractions.clear();
        if (error == '网关连接中断' || error == '连接已断开') error = null;
      });
    }
    noteTurnActivity();
    scheduleHistoryCheck();
  }

  Future<void> requestSessionRecovery() async {
    if (!mounted || !widget.gateway.usable) return;
    if (widget.id == null && stored == null) {
      updateSlash(() {
        if (error == '网关连接中断' || error == '连接已断开') error = null;
      });
      finishVoiceRecovery(ready: true);
      return;
    }
    recoveryRequested = true;
    if (recoveringSession) return;
    interactiveHistoryRead?.cancel();
    stopAdjacentHistoryRead();
    updateSlash(() {
      recoveringSession = true;
      sessionRecoveryDeferred = false;
    });
    try {
      while (mounted && widget.gateway.usable && recoveryRequested) {
        while (mounted &&
            widget.gateway.usable &&
            (busy || loadingOlder || slashPending || queueDraining)) {
          await Future<void>.delayed(const Duration(milliseconds: 90));
        }
        if (!mounted || !widget.gateway.usable) break;
        recoveryRequested = false;
        early.clear();
        final gateway = widget.gateway;
        final knownRuntime = runtime;
        final revision = linkRevision;
        if (knownRuntime != null &&
            seq > 0 &&
            (gateway.canonical ||
                sessionEpoch.isNotEmpty &&
                    sessionEpoch == gateway.replayEpoch)) {
          await acknowledgeReplay(gateway, knownRuntime);
        }
        if (!mounted || !gateway.usable || revision != linkRevision) continue;
        await open(recovering: true);
      }
    } finally {
      if (mounted) {
        final trailing = [...early];
        early.clear();
        updateSlash(() => recoveringSession = false);
        if (widget.gateway.usable && runtime != null) {
          for (final event in trailing) {
            applyEvent(event);
          }
        }
        if (widget.gateway.usable && !hydrating) {
          final ready = runtime != null && !readOnly;
          finishVoiceRecovery(ready: ready, reportFailure: !ready);
        }
        scheduleFollowupDrain();
        scheduleHistoryCheck();
        if (rows.isEmpty && oldest?.nextOffset != null) unawaited(loadOlder());
        openNotificationTarget();
        if (contextMeter.value == null) unawaited(refreshContextUsage());
      }
    }
  }

  Future<void> acknowledgeReplay(Gateway gateway, String knownRuntime) async {
    try {
      await gateway.call('session.events.since', {
        'session_id': knownRuntime,
        'profile': widget.profile,
        'last_seen': replyGapAfter ?? seq,
        if (gateway.canonical && sessionEpoch.isNotEmpty)
          'replay_epoch': sessionEpoch,
      }, timeout: const Duration(seconds: 5));
    } catch (_) {
      // A bounded session snapshot is still available when replay is unsupported.
    }
  }

  void restoreInflightOutput(Json inflight) {
    clearReplyGap();
    final prompt = ChatRow.visibleIncomingUser(inflight['user'], inflight);
    final last = rows.lastOrNull;
    if (prompt != null &&
        !(last != null &&
            last.user == prompt.user &&
            last.body == prompt.body)) {
      rows.add(prompt);
    }

    final assistant = messageBody(inflight['assistant']);
    final corrections = inflight['corrections'];
    final offsets = inflight['correction_offsets'];
    var start = 0;
    if (corrections is List && corrections.isNotEmpty) {
      // The gateway counts Python characters. Dart substrings use UTF-16.
      final positions = <int>[0];
      for (final rune in assistant.runes) {
        positions.add(positions.last + (rune > 0xffff ? 2 : 1));
      }
      final paired =
          offsets is List &&
          offsets.length == corrections.length &&
          offsets.every((offset) => offset is int && offset >= 0);
      for (final (index, correction) in corrections.indexed) {
        if (correction is! String || correction.trim().isEmpty) continue;
        final offset = paired ? offsets[index] as int : positions.length;
        final end = math.max(
          start,
          offset < positions.length ? positions[offset] : assistant.length,
        );
        if (end > start) {
          lastSealedReply = assistant.substring(start, end);
          rows.add(ChatRow(user: false, body: lastSealedReply));
        }
        rows.add(ChatRow.incomingUser(correction, const {}));
        start = end;
      }
    }

    restoredAssistantPrefix = assistant.substring(0, start);
    live.value = assistant.substring(start);
    replyOffset = live.value.length;
    if (inflight['error'] case final String message
        when message.trim().isNotEmpty) {
      seal();
      error = message;
    }
  }

  Future<bool> restoreRunningOutput(Json snapshot, int revision) async {
    final sid = runtime;
    if (sid == null) return false;
    final generation = snapshot['execution_generation'];
    final through = seq;
    try {
      final replay = await widget.gateway.call('session.events.since', {
        'session_id': sid,
        'profile': widget.profile,
        'last_seen': 0,
        if (sessionEpoch.isNotEmpty) 'replay_epoch': sessionEpoch,
      }, timeout: const Duration(seconds: 5));
      if (!mounted ||
          linkRevision != revision ||
          replay['snapshot_required'] == true ||
          replay['truncated'] == true) {
        return false;
      }
      final source = replay['events'];
      if (source is! List) return false;
      final frames = source.whereType<Json>().where((event) {
        final sequence = event['seq'];
        final eventGeneration = event['execution_generation'];
        return sequence is int &&
            sequence > 0 &&
            sequence <= through &&
            (eventGeneration == null ||
                generation == null ||
                eventGeneration == generation);
      }).toList();
      final begin = frames.lastIndexWhere(
        (event) => event['type'] == 'message.start',
      );
      if (begin < 0) return false;
      final turnFrames = frames.skip(begin);
      if (turnFrames.any((event) => event['type'] == 'message.complete') ||
          !_continuousReply(turnFrames)) {
        return false;
      }
      clearReplyGap();
      seq = (frames[begin]['seq'] as int) - 1;
      final corrections = activeCorrectionScope == correctionScope
          ? confirmedCorrections.toList()
          : const <ConfirmedCorrection>[];
      var nextCorrection = 0;
      for (final event in turnFrames) {
        applyEvent(event);
        while (nextCorrection < corrections.length &&
            corrections[nextCorrection].sequence <= seq) {
          appendCorrection(corrections[nextCorrection++].text);
        }
      }
      for (; nextCorrection < corrections.length; nextCorrection++) {
        appendCorrection(corrections[nextCorrection].text);
      }
      seq = through;
      return true;
    } catch (_) {
      return false;
    }
  }

  FollowupQueue? get submissionStore {
    final id = widget.id ?? stored;
    return id == null
        ? null
        : FollowupQueue.submissions(widget.gateway, widget.profile, id);
  }

  Future<bool> confirmReconnectedDraft(
    Json snapshot,
    List<Json> history, {
    TurnCorrectionRecord? savedCorrections,
  }) async {
    final store = submissionStore;
    if (store == null) return true;
    final List<FollowupDraft> retained;
    try {
      retained = await store.read();
    } catch (_) {
      if (mounted) error = '暂时无法核对上次发送';
      return false;
    }
    if (!mounted) return false;
    final record = retained.firstOrNull;
    if (record == null) return true;
    final pending = _UnconfirmedSend(
      record,
      liveInputs: unconfirmedSend?.record.id == record.id
          ? unconfirmedSend?.liveInputs
          : null,
    );
    final voiceTurn = pendingVoiceReply;
    final matchingVoice =
        voiceTurn?.submission == record.id && voiceTurn?.session == stored;
    final restoringVoice = matchingVoice && voiceRecovery != null;
    final confirmed =
        record.accepted ||
        savedCorrections?.entries.any((entry) => entry.id == record.id) ==
            true ||
        (record.request != null &&
            admittedSubmissionIds(snapshot, history).contains(record.id));
    final replay = !confirmed || restoringVoice && !running
        ? await submissionCompletionFromReplay(
            snapshot,
            record,
            voiceCursor: restoringVoice ? voiceTurn?.cursor : null,
          )
        : null;
    if (!mounted) return false;
    if (confirmed || replay != null) {
      if (matchingVoice && identical(pendingVoiceReply, voiceTurn)) {
        voiceTurn?.confirmAdmission(replay);
      }
      await confirmRetainedDraft(store, pending);
    } else if (await discardRedundantPreparation(store, record)) {
      if (mounted && unconfirmedSend?.record.id == record.id) {
        unconfirmedSend = null;
      }
    } else if (mounted) {
      unconfirmedSend = pending;
    }
    return true;
  }

  Future<Json?> submissionCompletionFromReplay(
    Json snapshot,
    FollowupDraft entry, {
    SubmissionCursor? voiceCursor,
  }) async {
    final id = widget.id ?? stored;
    if (id == null ||
        voiceCursor == null && entry.request?['submission_id'] != entry.id) {
      return null;
    }
    return completedSubmissionInReplay(
      widget.gateway,
      snapshot,
      profile: widget.profile,
      stored: id,
      id: entry.id,
      cursor: voiceCursor ?? entry.cursor,
    );
  }

  Future<bool> discardRedundantPreparation(
    FollowupQueue store,
    FollowupDraft record,
  ) async {
    final tab = widget.composerTab;
    final attachments = composerStore;
    if (record.request != null || tab == null || attachments == null) {
      return false;
    }
    bool hasDraftText() =>
        record.text.isEmpty ||
        (record.draftStamp != null &&
            record.draftStamp == tab.draftStamp &&
            record.text == tab.draft);
    if (!hasDraftText() ||
        record.composerInputs.length != record.attachmentCount) {
      return false;
    }
    final refs = {for (final item in tab.attachments) item.id: item};
    final originals = record.composerInputs.map((id) => refs[id]).toList();
    if (originals.any((item) => item == null)) return false;

    try {
      for (final item in originals.nonNulls) {
        final file = await attachments.source(item);
        if (!await File(file.path).exists()) return false;
      }
      if (!mounted || composerWrite != null || !hasDraftText()) return false;
      if (!record.composerInputs.every(
        (id) => tab.attachments.any((item) => item.id == id),
      )) {
        return false;
      }
      // A submission without a staged request never reached the gateway.
      // The composer owns a separate copy of every input in this record.
      await store.remove(record.id);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> confirmRetainedDraft(
    FollowupQueue store,
    _UnconfirmedSend pending,
  ) async {
    if (!pending.record.accepted) await store.markSubmitted(pending.record);
    if (!mounted) return;
    await clearSubmittedComposer(
      pending.record.composerInputs,
      documents: pending.liveInputs?.files ?? const [],
      photos: pending.liveInputs?.pictures ?? const [],
    );
    if (!mounted) return;
    updateSlash(() {
      final stamp = pending.record.draftStamp;
      if (draft.text == pending.record.text &&
          (stamp == null ? pending.liveInputs != null : stamp == draftStamp)) {
        draft.clear();
      }
      if (unconfirmedSend?.record.id == pending.record.id) {
        unconfirmedSend = null;
      }
    });
  }

  bool acceptedSubmission(Json receipt, Json request) {
    if (receipt['voice_stopped'] == true) return true;
    if (!widget.gateway.canonical) {
      return const {
            'streaming',
            'queued',
            'steered',
            'redirected',
          }.contains(receipt['status']) ||
          receipt['ok'] == true;
    }
    final reference = receipt['ref'];
    final status = receipt['status'];
    return const {'queued', 'started', 'terminal'}.contains(status) &&
        (reference == null ||
            reference is Json &&
                reference['session_id'] == request['session_id']);
  }

  void confirmLiveAdmission(Json payload) {
    final pending = unconfirmedSend;
    final store = submissionStore;
    if (pending == null ||
        store == null ||
        busy ||
        !admittedSubmissionIds(payload, const []).contains(pending.record.id)) {
      return;
    }
    unawaited(
      confirmRetainedDraft(store, pending).catchError((Object _) {
        if (mounted) updateSlash(() => error = '暂时无法保存发送确认');
      }),
    );
  }

  void confirmLiveRewrite(Json payload) {
    final plan = rewrite;
    final journal = rewriteJournal;
    if (journal == null ||
        plan?['phase'] != RewritePhase.submit.name ||
        !admittedSubmissionIds(payload, const []).contains(plan?['id'])) {
      return;
    }
    unawaited(
      journal
          .confirmSeen(payload, const [])
          .then((confirmed) {
            if (confirmed && mounted && identical(rewrite, plan)) {
              setState(() => rewrite = null);
            }
          })
          .catchError((Object _) {
            // A later reconnect can confirm the same receipt.
          }),
    );
  }

  Future<void> retryRetainedDraft(_UnconfirmedSend pending) async {
    final store = submissionStore;
    if (store == null || !gatewayReady || busy || !canRetryRetained(pending)) {
      return;
    }
    updateSlash(() {
      error = null;
      busy = true;
    });
    try {
      final request = pending.record.request!;
      final receipt = await widget.gateway.call('prompt.submit', request);
      if (!acceptedSubmission(receipt, request)) {
        throw GatewayError('网关未返回发送确认');
      }
      await confirmRetainedDraft(store, pending);
      if (!mounted) return;
      updateSlash(() => busy = false);
      await requestSessionRecovery();
    } catch (e) {
      if (mounted) updateSlash(() => error = e.toString());
    } finally {
      if (mounted && busy && !opening) updateSlash(() => busy = false);
    }
  }

  bool canRetryRetained(_UnconfirmedSend pending) =>
      widget.gateway.canonical &&
      runtime != null &&
      pending.record.request?['session_id'] == runtime &&
      pending.record.request?['submission_id'] == pending.record.id;

  bool canMarkRetainedAsSent(_UnconfirmedSend pending) =>
      pending.record.request != null &&
      pending.record.request!['submission_id'] == null;

  Future<void> markRetainedAsSent(_UnconfirmedSend pending) async {
    final store = submissionStore;
    if (store == null || busy || !canMarkRetainedAsSent(pending)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(dialog.tr('标为已发送？')),
        content: Text(dialog.tr('请先在会话中核对这条消息。标为已发送后，会清除这次保留的草稿和附件。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(dialog.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(dialog.tr('标为已发送')),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        busy ||
        !identical(unconfirmedSend, pending)) {
      return;
    }
    updateSlash(() {
      error = null;
      busy = true;
    });
    try {
      await confirmRetainedDraft(store, pending);
    } catch (failure) {
      if (mounted) updateSlash(() => error = failure.toString());
    } finally {
      if (mounted) {
        updateSlash(() => busy = false);
        scheduleFollowupDrain();
      }
    }
  }

  Future<void> editRetainedDraft(_UnconfirmedSend pending) async {
    final store = submissionStore;
    if (store == null || busy) return;
    if (pending.record.request != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.tr('继续编辑这条消息？')),
          content: Text(context.tr('网关还没确认上次发送。再次发送前，可以先查看会话里是否已有这条消息。')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.tr('继续编辑')),
            ),
          ],
        ),
      );
      if (confirmed != true ||
          !mounted ||
          busy ||
          !identical(unconfirmedSend, pending)) {
        return;
      }
    }
    updateSlash(() => busy = true);
    try {
      if (composerStore != null) {
        final record = pending.record;
        await composerRestore;
        if (!mounted) return;
        final present = <String>{};
        for (final input in [...files, ...pictures].whereType<ComposerFile>()) {
          if (await File(input.path).exists()) present.add(input.attachment.id);
        }
        String identity(FollowupFile file) =>
            file.index >= 0 && file.index < record.composerInputs.length
            ? record.composerInputs[file.index]
            : '';
        bool missing(FollowupFile file) => !present.contains(identity(file));
        final documents = record.files.where(missing).toList();
        final photos = record.pictures.where(missing).toList();
        if (documents.isNotEmpty || photos.isNotEmpty) {
          final inputs = await Future.wait(
            documents.map((file) => store.source(record.id, file)),
          );
          final images = await Future.wait(
            photos.map((file) => store.source(record.id, file)),
          );
          if (!mounted || !identical(unconfirmedSend, pending)) return;
          await addComposerInputs(
            inputs,
            images,
            identities: [...documents.map(identity), ...photos.map(identity)],
          );
        }
      }
      final restored = composerStore == null && pending.liveInputs == null
          ? await store.copyToEditor(pending.record)
          : null;
      if (!mounted || !identical(unconfirmedSend, pending)) return;
      await store.remove(pending.record.id, allowStaged: true);
      if (!mounted) return;
      updateSlash(() {
        if (draft.text.isEmpty) draft.text = pending.record.text;
        if (restored != null) {
          files.addAll(restored.files);
          pictures.addAll(restored.pictures);
        }
        unconfirmedSend = null;
        error = null;
      });
    } catch (e) {
      if (mounted) updateSlash(() => error = e.toString());
    } finally {
      if (mounted) updateSlash(() => busy = false);
    }
  }

  Widget connectionNotice() {
    final gateway = widget.gateway;
    final state = gateway.link;
    if (gatewayReady) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final loading = recoveringSession || state == GatewayLink.reconnecting;
    final (label, action, handler) = switch (state) {
      GatewayLink.offline => ('连接已断开', '重试', gateway.retry),
      GatewayLink.signIn => ('网关需要重新登录', '登录', widget.onGatewaySignIn),
      GatewayLink.reconnecting => ('正在重新连接网关', '', null),
      _ => ('正在恢复会话', '', null),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 2),
      child: Row(
        children: [
          if (loading)
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              Icons.cloud_off_outlined,
              size: 18,
              color: colors.onSurfaceVariant,
            ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              context.tr(label),
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
            ),
          ),
          if (handler != null)
            TextButton(onPressed: handler, child: Text(context.tr(action))),
        ],
      ),
    );
  }

  Widget unconfirmedNotice(_UnconfirmedSend pending) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pending.record.request == null
                ? context.tr('上次消息尚未发出')
                : context.tr('上次发送结果待确认'),
            style: TextStyle(color: colors.onSurface, fontSize: 13),
          ),
          if (pending.record.attachmentCount > 0)
            Text(
              context.strings.format('已保留 {value} 个附件', {
                'value': pending.record.attachmentCount,
              }),
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          Wrap(
            spacing: 5,
            children: [
              if (pending.record.request != null)
                TextButton(
                  onPressed: gatewayReady && !busy
                      ? requestSessionRecovery
                      : null,
                  child: Text(context.tr('核对会话')),
                ),
              if (canRetryRetained(pending))
                TextButton(
                  onPressed: gatewayReady && !busy
                      ? () => retryRetainedDraft(pending)
                      : null,
                  child: Text(context.tr('重试原消息')),
                ),
              if (canMarkRetainedAsSent(pending))
                TextButton(
                  onPressed: busy ? null : () => markRetainedAsSent(pending),
                  child: Text(context.tr('标为已发送')),
                ),
              TextButton(
                onPressed: busy ? null : () => editRetainedDraft(pending),
                child: Text(context.tr('继续编辑')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
