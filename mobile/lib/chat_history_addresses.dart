part of 'chat.dart';

extension _ChatHistoryAddresses on _ChatPageState {
  bool get canReadOlderHistory =>
      widget.gateway.usable &&
      !busy &&
      !recoveringSession &&
      interactiveHistoryRead == null;

  bool get canRetryRecentHistory =>
      transcriptSession != null &&
      interactiveHistoryRead == null &&
      recentHistoryStable;

  bool get recentHistoryStable =>
      widget.gateway.usable &&
      !busy &&
      !recoveringSession &&
      !running &&
      !slashPending &&
      !queueDraining &&
      rewrite == null &&
      unconfirmedSend == null;

  Future<void> retryRecentHistory() async {
    final session = transcriptSession;
    if (session == null || !canRetryRecentHistory) return;
    final expected = historyTail?.session ?? stored;
    final control = interactiveHistoryRead = FileTransferControl();
    final link = linkRevision;
    final sequence = seq;
    final activity = turnActivityRevision;
    bool current() =>
        mounted &&
        !control.cancelled &&
        recentHistoryStable &&
        transcriptSession == session &&
        linkRevision == link &&
        seq == sequence &&
        turnActivityRevision == activity;
    updateSlash(() {});
    try {
      final page = await widget.gateway.historyPage(
        widget.profile,
        session,
        0,
        control: control,
      );
      if (!current()) return;
      if (expected != null && page.sessionId != expected) {
        throw GatewayError('网关返回的历史页不匹配');
      }
      if (!await prepareHistoryRefresh(current)) return;
      updateSlash(() {
        applyLatestHistory(page, keepLoaded: true);
        stored ??= page.sessionId;
        historyError = null;
      });
    } catch (_) {
      if (current()) {
        updateSlash(() => historyError ??= '未能更新最近消息');
      }
    } finally {
      if (mounted && identical(interactiveHistoryRead, control)) {
        updateSlash(() => interactiveHistoryRead = null);
        scheduleHistoryCheck();
      }
    }
  }

  Future<bool> prepareHistoryRefresh(bool Function() current) async {
    if (!current()) return false;
    if (readingWindow == null && awayFromLatest.value) {
      final position = captureReading();
      if (position == null) return false;
      flushReading();
      await restoreReading(position: position, stillOpen: current);
      if (readingWindow == null && awayFromLatest.value) return false;
    }
    return current();
  }

  void applyLatestHistory(HistoryPage page, {bool keepLoaded = false}) {
    final previous = oldest;
    final canJoin =
        keepLoaded &&
        page.nextOffset != null &&
        page.rows.isNotEmpty &&
        previous?.sessionId == page.sessionId;
    // A tail offset can move while another client writes to the conversation.
    // Retain older pages only when the refreshed page has a known boundary.
    final overlap = canJoin
        ? historyRows.indexWhere((row) => sameHistoryRow(row, page.rows.first))
        : -1;
    final kept = overlap > 0;
    historyRows
      ..removeRange(kept ? overlap : 0, historyRows.length)
      ..addAll(page.rows);
    oldest = kept
        ? HistoryPage(
            sessionId: page.sessionId,
            rows: historyRows.take(previous!.rows.length).toList(),
            offset: historyRows.length - previous.rows.length,
            nextOffset: previous.nextOffset == null
                ? null
                : historyRows.length - 1,
          )
        : page;
    rememberHistoryTail(page);
    taskSnapshot = SessionTaskSnapshot.fromHistory(page.rows);
    recordReadingAddresses(historyRows, newestOffset: 0);
    rows
      ..clear()
      ..addAll(displayRows(historyRows));
    displayedHistoryCount = rows.length;
  }

  void trimRecentPages(int limit) {
    final first = oldest;
    final cut = historyRows.length - limit;
    if (first == null || cut <= 0) return;
    final offset = first.oldestOffset - historyRows.length + 1;
    if (offset < 0) return;

    final retained = historyRows.sublist(cut);
    final keptCount = displayRows(retained).length;
    // Live events can add rows after the persisted portion of the timeline.
    rows.removeRange(0, displayedHistoryCount - keptCount);
    displayedHistoryCount = keptCount;
    historyRows.removeRange(0, cut);
    oldest = HistoryPage(
      sessionId: first.sessionId,
      rows: retained,
      offset: offset,
      nextOffset: offset + retained.length - 1,
    );
    olderHistoryError = null;
    readingTimelines.releaseLatest();
  }

  void rememberHistoryTail(HistoryPage page) {
    final previous = historyTail;
    final boundary = previous?.row;
    if (boundary != null &&
        previous?.session == page.sessionId &&
        (readingWindow != null || awayFromLatest.value) &&
        displayRows(page.after(boundary)).any(_countsConversationMessage)) {
      noteNewMessage();
    }
    historyTail = (session: page.sessionId, row: page.rows.lastOrNull);
    readingWindow?.observeTail(page);
    if (previous == null || previous.session == page.sessionId) {
      transcriptSearch?.acceptLatest(page, boundary);
    }
  }

  bool get watchesHistory {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        widget.keyboardActive &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        gatewayReady &&
        historyTail != null &&
        runtime != null;
  }

  bool get canCheckHistory =>
      watchesHistory &&
      !busy &&
      !running &&
      !opening &&
      !recoveringSession &&
      !stopping &&
      !slashPending &&
      !queueDraining &&
      !hydrating &&
      !readOnly &&
      interactiveHistoryRead == null &&
      !readingLoading &&
      !readingGesture &&
      readingJump == null &&
      rewrite == null &&
      unconfirmedSend == null &&
      remoteFollowups.isEmpty &&
      pendingInteractions.isEmpty;

  void scheduleHistoryCheck({bool changed = false}) {
    if (!watchesHistory) {
      historyCheckTimer?.cancel();
      historyCheckTimer = null;
      historyCheckSoon = false;
      return;
    }
    if (checkingHistory) {
      historyCheckSoon = historyCheckSoon || changed;
      return;
    }
    if (historyCheckTimer != null && (!changed || historyCheckSoon)) return;
    historyCheckTimer?.cancel();
    historyCheckSoon = changed;
    historyCheckTimer = Timer(Duration(seconds: changed ? 2 : 20), () {
      historyCheckTimer = null;
      historyCheckSoon = false;
      unawaited(checkHistoryTail());
    });
  }

  Future<void> checkHistoryTail() async {
    final id = widget.id ?? stored;
    final before = historyTail;
    if (!canCheckHistory || id == null || before == null) {
      scheduleHistoryCheck();
      return;
    }
    final attachment = runtime;
    final link = linkRevision;
    final sequence = seq;
    final activity = turnActivityRevision;
    bool current() =>
        canCheckHistory &&
        runtime == attachment &&
        linkRevision == link &&
        seq == sequence &&
        turnActivityRevision == activity &&
        historyTail == before;
    checkingHistory = true;
    try {
      final tail = await widget.gateway.historyTail(widget.profile, id);
      if (!current()) return;
      if (tail.sessionId == before.session &&
          sameHistoryTail(before.row, tail.rows.lastOrNull)) {
        return;
      }

      final latest = tail.sessionId == before.session
          ? await widget.gateway.historyPage(widget.profile, id, 0)
          : null;
      if (!current()) return;
      if (latest != null &&
          latest.sessionId == before.session &&
          sameHistoryTail(before.row, latest.rows.lastOrNull)) {
        return;
      }

      if (!await prepareHistoryRefresh(current)) return;

      if (latest == null || latest.sessionId != before.session) {
        await requestSessionRecovery();
      } else {
        updateSlash(() {
          applyLatestHistory(latest, keepLoaded: true);
          historyError = null;
        });
      }
    } catch (_) {
      // Preserve the open transcript while an idle history check fails.
    } finally {
      checkingHistory = false;
      scheduleHistoryCheck(changed: historyCheckSoon);
    }
  }

  Future<void> bindCompletedHistory() async {
    final session = stored ?? widget.id;
    final attached = runtime;
    final completion = completedTurns;
    final link = linkRevision;
    final tail = rows.lastOrNull;
    if (session == null || attached == null || tail == null || opening) return;
    bool current() =>
        mounted &&
        !opening &&
        !hydrating &&
        !recoveringSession &&
        !running &&
        gatewayReady &&
        runtime == attached &&
        (stored ?? widget.id) == session &&
        completedTurns == completion &&
        linkRevision == link &&
        identical(rows.lastOrNull, tail);

    // A gateway can settle the stream just before its history read sees the commit.
    var historyChanged = false;
    for (final delay in const [
      Duration.zero,
      Duration(milliseconds: 240),
      Duration(milliseconds: 600),
    ]) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      if (!current()) return;
      try {
        final page = await widget.gateway.historyPage(
          widget.profile,
          session,
          0,
        );
        if (!current() || page.sessionId != session) return;
        historyChanged =
            page.sessionId != historyTail?.session ||
            !sameHistoryTail(historyTail?.row, page.rows.lastOrNull);
        if (_bindAddressedTail(page)) {
          final last = page.rows.lastOrNull;
          final tailId = last == null ? null : historyRowId(last);
          if (tailId != null && rows.any((row) => row.rowId == tailId)) {
            rememberHistoryTail(page);
          } else if (historyChanged) {
            scheduleHistoryCheck(changed: true);
          }
          return;
        }
      } on GatewayError catch (error) {
        if (error is GatewayDisconnected ||
            {401, 403, 404, 405, 501}.contains(error.status)) {
          return;
        }
      } catch (_) {
        // A failed lookup leaves the streamed turn visible.
      }
    }
    if (historyChanged && current()) scheduleHistoryCheck(changed: true);
  }

  bool _bindAddressedTail(HistoryPage page) {
    final tail = <(int, ChatRow)>[];
    ChatRow? boundary;
    for (var index = rows.length - 1; index >= 0; index--) {
      final row = rows[index];
      if (!_isStoredMessage(row)) continue;
      if (row.rowId != null) {
        boundary = row;
        break;
      }
      tail.add((index, row));
    }
    final missing = tail.reversed.toList();
    if (missing.isEmpty) return true;
    final remote = displayRows(page.rows).where(_isStoredMessage).toList();
    final int remoteAnchor;
    if (boundary == null) {
      if (page.nextOffset != null) return false;
      remoteAnchor = -1;
    } else {
      final id = boundary.rowId;
      remoteAnchor = remote.indexWhere((row) => row.rowId == id);
      if (remoteAnchor < 0 || !_sameMessage(boundary, remote[remoteAnchor])) {
        return false;
      }
    }
    final saved = remote.skip(remoteAnchor + 1).toList();
    if (saved.length != missing.length) return false;
    for (var index = 0; index < saved.length; index++) {
      if (saved[index].rowId == null ||
          !_sameMessage(missing[index].$2, saved[index])) {
        return false;
      }
    }

    updateSlash(() {
      recordReadingAddresses(page.rows, newestOffset: 0);
      for (var index = 0; index < saved.length; index++) {
        final (slot, message) = missing[index];
        rows[slot] = message.withRowId(saved[index].rowId!);
      }
    });
    return true;
  }
}

bool _isStoredMessage(ChatRow row) =>
    row.activity == null &&
    row.backgroundNotice == null &&
    row.commandReceipt == null;

bool _sameMessage(ChatRow local, ChatRow stored) =>
    local.user == stored.user && local.body.trim() == stored.body.trim();
