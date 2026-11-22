part of 'chat.dart';

class _ReadingCopyButton extends StatefulWidget {
  const _ReadingCopyButton({required this.text});

  final String text;

  @override
  State<_ReadingCopyButton> createState() => _ReadingCopyButtonState();
}

class _ReadingCopyButtonState extends State<_ReadingCopyButton> {
  Timer? _confirmation;

  Future<void> _copy() async {
    final text = widget.text;
    final copied = await writeMobileText(text);
    if (!mounted || widget.text != text) return;
    if (!copied) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.tr('无法复制到剪贴板'))));
      return;
    }
    _confirmation?.cancel();
    setState(() {
      _confirmation = Timer(const Duration(milliseconds: 1300), () {
        if (mounted) setState(() => _confirmation = null);
      });
    });
  }

  @override
  void didUpdateWidget(covariant _ReadingCopyButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == oldWidget.text) return;
    _confirmation?.cancel();
    _confirmation = null;
  }

  @override
  void dispose() {
    _confirmation?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final copied = _confirmation != null;
    return IconButton(
      tooltip: context.tr(copied ? '已复制消息' : '复制消息'),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 42, minHeight: 28),
      icon: Icon(
        copied ? Icons.check_rounded : Icons.content_copy_rounded,
        color: copied ? colors.primary : colors.onSurfaceVariant,
        size: 15,
      ),
      onPressed: _copy,
    );
  }
}

typedef _TimelineStyle = ({
  bool showReasoning,
  bool expandReasoning,
  bool includeBeginning,
  List<CommandReceipt> receipts,
  int? revealedRowId,
});

typedef _ReadingSlice = ({
  int start,
  int step,
  int count,
  Map<Object, int> indices,
});

typedef _ReadingCellInfo = ({TimelineItem item, MessageAddress? address});
typedef _PinnedQuestion = ({ChatRow row, String preview});

const _pinnedQuestionHeight = 44.0;

ChatRow? _questionRow(TimelineItem item) => switch (item) {
  TimelineMessage(:final row) when row.user && row.backgroundNotice == null =>
    row,
  _ => null,
};

bool _countsConversationMessage(ChatRow row) =>
    row.activity == null &&
    row.commandReceipt == null &&
    row.backgroundNotice == null &&
    row.body.isNotEmpty;

class _ReadingTimeline {
  _ReadingTimeline(Iterable<ChatRow> rows, _TimelineStyle style)
    : items = groupTimeline(
        rows,
        showReasoning: style.showReasoning,
        expandReasoning: style.expandReasoning,
        receipts: style.receipts,
        includeBeginning: style.includeBeginning,
        revealedRowId: style.revealedRowId,
      );

  final List<TimelineItem> items;
  late final latestIndices = {
    for (final (index, item) in items.indexed)
      _readingItemIdentity(item): items.length - index,
  };
  late final Map<int, int> _recordIndices = _indexRecords();
  late final indices = {for (final (index, item) in items.indexed) item: index};
  late final List<int> remainingMessages = _countRemainingMessages();
  late final List<ChatRow?> questionsBefore = _indexQuestions();
  int? _splitAt;
  (_ReadingSlice, _ReadingSlice)? _split;

  List<int> _countRemainingMessages() {
    final counts = List<int>.filled(items.length + 1, 0);
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      counts[i] =
          counts[i + 1] +
          (item is TimelineMessage && _countsConversationMessage(item.row)
              ? 1
              : 0);
    }
    return counts;
  }

  List<ChatRow?> _indexQuestions() {
    final questions = List<ChatRow?>.filled(items.length, null);
    ChatRow? lastQuestion;
    for (final (i, item) in items.indexed) {
      if (_questionRow(item) case final question?) {
        lastQuestion = question.rowId == null ? null : question;
      } else {
        questions[i] = lastQuestion;
      }
    }
    return questions;
  }

  Map<int, int> _indexRecords() {
    final indices = <int, int>{};
    for (final (index, item) in items.indexed) {
      final rows = switch (item) {
        TimelineMessage(:final row) => [row],
        TimelineActivity(:final rows) => rows,
      };
      for (final row in rows) {
        if (row.rowId case final id?) indices.putIfAbsent(id, () => index);
      }
    }
    return indices;
  }

  bool contains(int id) => _recordIndices.containsKey(id);

  (_ReadingSlice, _ReadingSlice)? split(int id) {
    if (_splitAt == id) return _split;
    _splitAt = id;
    final center = _recordIndices[id];
    return _split = center == null
        ? null
        : (
            _slice(center - 1, -1, center),
            _slice(center, 1, items.length - center),
          );
  }

  _ReadingSlice _slice(int start, int step, int count) => (
    start: start,
    step: step,
    count: count,
    indices: {
      for (var i = 0; i < count; i++)
        _readingItemIdentity(items[start + i * step], fromNewest: step < 0): i,
    },
  );
}

class _ReadingTimelines {
  List<ChatRow>? _latestRows;
  _TimelineStyle? _latestStyle;
  _ReadingTimeline? _latest;
  (ReadingWindow, int)? _windowSource;
  List<ChatRow> _windowRows = const [];
  _TimelineStyle? _windowStyle;
  _ReadingTimeline? _window;

  void releaseLatest() {
    _latestRows = null;
    _latestStyle = null;
    _latest = null;
  }

  _ReadingTimeline latest(List<ChatRow> rows, _TimelineStyle style) {
    _windowSource = null;
    _windowRows = const [];
    _windowStyle = null;
    _window = null;
    if (_latestStyle == style && listEquals(_latestRows, rows)) return _latest!;
    final layout = _ReadingTimeline(rows, style);
    _latestRows = List.of(rows, growable: false);
    _latestStyle = style;
    return _latest = layout;
  }

  _ReadingTimeline history(ReadingWindow window, _TimelineStyle style) {
    final source = (window, window.revision);
    if (_windowSource != source) {
      _windowRows = displayRows(window.records).toList(growable: false);
      _windowSource = source;
      _windowStyle = null;
    }
    if (_windowStyle == style) return _window!;
    final layout = _ReadingTimeline(_windowRows, style);
    _windowStyle = style;
    return _window = layout;
  }
}

const _retainedReadingRows = 240;

extension _ChatReading on _ChatPageState {
  bool _ownsTranscriptTarget(TranscriptTarget target) =>
      target.profile == widget.profile &&
      (target.session == widget.id || target.session == stored);

  Future<void> openTranscriptTarget(TranscriptTarget target) async {
    if (_ownsTranscriptTarget(target)) {
      await revealReadingMessage(target.address, match: target.match);
    } else if (widget.onOpenMessage case final open?) {
      open(target);
    } else {
      await readAround(
        context,
        gateway: widget.gateway,
        profile: target.profile,
        session: target.session,
        title: target.title,
        address: target.address,
        match: target.match,
      );
    }
  }

  void openMessageTarget() {
    final target = widget.messageTarget;
    if (!widget.keyboardActive ||
        target == null ||
        !_ownsTranscriptTarget(target)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !widget.keyboardActive ||
          !identical(widget.messageTarget, target)) {
        return;
      }
      widget.onMessageTargetOpened?.call(target);
      unawaited(revealReadingMessage(target.address, match: target.match));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  ReadingPositions? get readingStore {
    final id = widget.id ?? stored;
    return id == null
        ? null
        : ReadingPositions(widget.gateway, widget.profile, id);
  }

  void flushReading() {
    readingTimer?.cancel();
    if (!readingDirty) return;
    readingDirty = false;
    final store = readingStore;
    if (store != null) {
      unawaited(store.write(latestReading).catchError((Object _) {}));
    }
  }

  void storeReading(ReadingPosition? position) {
    latestReading = position;
    readingDirty = true;
    readingTimer?.cancel();
    readingTimer = Timer(const Duration(milliseconds: 190), flushReading);
  }

  void recordReadingAddresses(List<Json> source, {int? newestOffset}) {
    int? prompt;
    for (var i = 0; i < source.length; i++) {
      final wire = source[i];
      final id = historyRowId(wire);
      if (id == null || wire['display_kind'] == 'hidden') continue;
      if (wire['role'] == 'user' && !BackgroundNotice.isHistoryNotice(wire)) {
        prompt = id;
      }
      final prior = readingAddresses[id];
      readingAddresses[id] = MessageAddress(
        id,
        promptId: prompt ?? prior?.promptId,
        tailOffset: newestOffset == null
            ? prior?.tailOffset
            : newestOffset + source.length - 1 - i,
      );
    }
  }

  bool trackReading(ScrollNotification notice) {
    if (notice.depth != 0 || notice.metrics.axis != Axis.vertical) return false;
    if (notice is UserScrollNotification &&
        notice.direction != ScrollDirection.idle &&
        !readingGesture) {
      readingGesture = true;
      readingEpoch++;
    }
    final window = readingWindow;
    final delta = switch (notice) {
      ScrollUpdateNotification(:final scrollDelta) => scrollDelta,
      OverscrollNotification(:final overscroll) => overscroll,
      _ => null,
    };
    if (delta != null && delta != 0) {
      if ((notice is ScrollUpdateNotification && notice.dragDetails != null) ||
          (notice is OverscrollNotification && notice.dragDetails != null)) {
        readingGesture = true;
        readingEpoch++;
      }
      final metrics = notice.metrics;
      if (window == null) {
        final away = metrics.extentBefore > 48;
        if (!away) newHistoryWhileReading = false;
        awayFromLatest.value = away;
      }
      scheduleReadingIndicators();
      if (readingGesture && (window != null || metrics.extentBefore > 5)) {
        captureReading();
      }
      if (readingGesture) {
        readingTowardNewer = window != null && delta > 0;
        _prefetchReading(metrics, delta, window);
      }
    }
    if (notice is ScrollEndNotification && readingGesture) {
      readingGesture = false;
      final rejoin =
          readingTowardNewer &&
          window != null &&
          !window.latest.hasNewer &&
          !readingLoading &&
          notice.metrics.extentAfter <= 5 &&
          rows.isNotEmpty;
      readingTowardNewer = false;
      if (rejoin) {
        final revision = readingEpoch;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              readingEpoch == revision &&
              identical(window, readingWindow)) {
            returnToLatest();
          }
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      } else if (window == null && notice.metrics.extentBefore <= 5) {
        if (latestReading != null) storeReading(null);
      } else {
        captureReading();
      }
    }
    return false;
  }

  void _prefetchReading(
    ScrollMetrics metrics,
    double delta,
    ReadingWindow? window,
  ) {
    final threshold = math.max(220.0, metrics.viewportDimension * .45);
    if (window == null) {
      if (delta > 0 &&
          metrics.extentAfter < threshold &&
          olderHistoryError == null) {
        unawaited(loadOlder());
      }
      return;
    }
    if (readingJump != null || readingError != null) return;
    final older = delta < 0;
    if (older
        ? metrics.extentBefore < threshold
        : metrics.extentAfter < threshold) {
      unawaited(loadReadingWindow(older: older));
    }
  }

  ReadingPosition? captureReading() {
    final viewport = readingViewport.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize || !viewport.attached) {
      return null;
    }
    MessageAddress? anchor;
    var closest = double.infinity;
    for (final cell in readingCells.entries) {
      final address = cell.value.address;
      if (address == null) continue;
      final render = cell.key.findRenderObject();
      if (render is! RenderBox || !render.hasSize || !render.attached) continue;
      final top = render.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (top >= viewport.size.height ||
          top + render.size.height <= 1 ||
          top >= closest) {
        continue;
      }
      closest = top;
      anchor = address;
    }
    if (anchor == null) return null;
    final position = ReadingPosition(anchor, closest < 0 ? -closest : 0);
    storeReading(position);
    return position;
  }

  void noteNewMessage() {
    if (readingWindow != null || awayFromLatest.value) {
      newHistoryWhileReading = true;
    }
  }

  void scheduleReadingIndicators() {
    if (readingIndicatorsScheduled ||
        readingWindow == null &&
            !awayFromLatest.value &&
            messagesBelow.value == null &&
            pinnedQuestion.value == null) {
      return;
    }
    readingIndicatorsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      readingIndicatorsScheduled = false;
      if (mounted) updateReadingIndicators();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void updateReadingIndicators() {
    final timeline = shownReadingTimeline;
    final window = readingWindow;
    final viewport = readingViewport.currentContext?.findRenderObject();
    if (timeline == null ||
        window == null && !awayFromLatest.value ||
        viewport is! RenderBox ||
        !viewport.hasSize ||
        !viewport.attached) {
      messagesBelow.value = null;
      pinnedQuestion.value = null;
      return;
    }
    int? firstVisible, cutoff;
    var questionNearTop = false;
    for (final cell in readingCells.entries) {
      final index = timeline.indices[cell.value.item];
      if (index == null) continue;
      final render = cell.key.findRenderObject();
      if (render is! RenderBox || !render.hasSize || !render.attached) continue;
      final top = render.localToGlobal(Offset.zero, ancestor: viewport).dy;
      final bottom = top + render.size.height;
      if (top >= viewport.size.height || bottom <= 0) continue;
      firstVisible = firstVisible == null
          ? index
          : math.min(firstVisible, index);
      if (top < _pinnedQuestionHeight + 6 &&
          _questionRow(cell.value.item) != null) {
        questionNearTop = true;
      }
      final after = index + (bottom <= viewport.size.height + 1 ? 1 : 0);
      cutoff = cutoff == null ? after : math.max(cutoff, after);
    }
    messagesBelow.value = cutoff == null || window?.latest.hasNewer == true
        ? null
        : timeline.remainingMessages[cutoff];
    final question = firstVisible == null || questionNearTop
        ? null
        : timeline.questionsBefore[firstVisible];
    if (!identical(question, pinnedQuestion.value?.row)) {
      pinnedQuestion.value = question == null
          ? null
          : (row: question, preview: turnMessagePreview(question.body));
    }
  }

  Future<void> restoreReading({
    ReadingPosition? position,
    bool Function()? stillOpen,
  }) async {
    final id = widget.id ?? stored;
    if (id == null || readingJump != null) return;
    stopReadingLookup();
    final control = readingLookup = FileTransferControl();
    final revision = readingEpoch;
    bool valid() =>
        mounted &&
        !control.cancelled &&
        transcriptSession == id &&
        readingEpoch == revision &&
        readingJump == null &&
        stillOpen?.call() != false;
    try {
      final saved = position ?? await readingStore!.read();
      if (!valid() || saved == null) return;
      latestReading = saved;
      final lookup = TranscriptNavigation(widget.gateway, widget.profile, id);
      final address = saved.address;
      final page = await lookup.locate(
        address,
        stillOpen: valid,
        fallbackToPrompt: true,
        control: control,
      );
      if (!valid()) return;
      final center = page.contains(address.rowId)
          ? address.rowId
          : address.promptId;
      if (center == null) return;
      final window = ReadingWindow(page, center);
      if (!_projectHistory(window).contains(center)) return;
      recordReadingAddresses(
        page.rows,
        newestOffset: page.latestFirst ? page.offset : null,
      );
      showReadingWindow(
        window,
        center,
        offset: center == saved.address.rowId ? saved.offset : 0,
      );
    } catch (_) {
      // The recent timeline remains available when the saved row cannot be read.
    } finally {
      if (identical(readingLookup, control)) readingLookup = null;
    }
  }

  void stopReadingLookup() {
    readingLookup?.cancel();
    readingLookup = null;
  }

  void stopAdjacentHistoryRead() {
    adjacentHistoryRead?.cancel();
    adjacentHistoryRead = null;
  }

  void trimInactiveReading() {
    if (loadingOlder) interactiveHistoryRead?.cancel();
    if (readingJump != null) return;
    var window = readingWindow;
    var compacted = false;
    if (window == null &&
        awayFromLatest.value &&
        historyRows.length > _retainedReadingRows) {
      final saved = captureReading() ?? latestReading;
      if (saved == null) return;
      window = _windowFromRecentHistory(saved.address.rowId);
      if (window == null) return;
      stopReadingLookup();
      readingEpoch++;
      readingWindow = window;
      _resetReadingScroll(saved.offset);
      compacted = true;
    } else if (window != null && window.records.length > _retainedReadingRows) {
      final saved = captureReading() ?? latestReading;
      if (saved != null &&
          window.trimAround(saved.address.rowId, limit: _retainedReadingRows)) {
        _resetReadingScroll(saved.offset);
        compacted = true;
      }
    }
    final previouslyLoaded = historyRows.length;
    trimRecentPages(_retainedReadingRows);
    if (!compacted && historyRows.length == previouslyLoaded) return;
    final retained = {
      for (final row in rows) row.rowId,
      if (window != null)
        for (final record in window.records) historyRowId(record),
    };
    readingAddresses.removeWhere((id, _) => !retained.contains(id));
    if (!retained.contains(revealedRowId)) {
      revealedRowId = null;
      revealedMatch = null;
    }
    flushReading();
  }

  ReadingWindow? _windowFromRecentHistory(int center) {
    final first = oldest;
    if (first == null) return null;
    final index = historyRows.indexWhere((row) => historyRowId(row) == center);
    if (index < 0) return null;
    final count = historyRows.length;
    final newestOffset = first.oldestOffset - count + 1;
    if (newestOffset < 0) return null;
    final length = count < _retainedReadingRows ? count : _retainedReadingRows;
    final start = (index - length ~/ 2).clamp(0, count - length).toInt();
    final end = start + length;
    final offset = newestOffset + count - end;
    return ReadingWindow(
      TranscriptWindow(
        first.sessionId,
        historyRows.sublist(start, end),
        offset: offset,
        latestFirst: true,
        hasOlder: first.nextOffset != null || start > 0,
        hasNewer: offset > 0,
      ),
      center,
    );
  }

  void _resetReadingScroll(double offset) {
    final previous = readingScroll;
    readingScroll = ScrollController(
      initialScrollOffset: offset,
      keepScrollOffset: false,
    );
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  void cancelReadingJump() {
    if (readingJump == null) return;
    readingEpoch++;
    stopReadingLookup();
    updateSlash(() => readingJump = null);
  }

  void showReadingWindow(
    ReadingWindow window,
    int center, {
    double offset = 0,
    bool reveal = false,
    TranscriptMatchExcerpt? match,
  }) {
    updateSlash(() {
      stopAdjacentHistoryRead();
      window.center = center;
      readingWindow = window;
      revealedRowId = reveal ? center : null;
      revealedMatch = reveal ? match : null;
      readingError = null;
      _resetReadingScroll(offset);
    });
  }

  Future<void> revealReadingMessage(
    MessageAddress address, {
    TranscriptMatchExcerpt? match,
    bool latestOnMiss = false,
  }) async {
    final id = transcriptSession;
    if (id == null) return;
    stopReadingLookup();
    final target = address.rowId;
    final revision = ++readingEpoch;
    stopAdjacentHistoryRead();
    readingGesture = false;
    readingTowardNewer = false;
    final existing = readingWindow;
    final location = MessageAddress(
      target,
      promptId: address.promptId ?? readingAddresses[target]?.promptId,
      tailOffset: address.tailOffset ?? readingAddresses[target]?.tailOffset,
    );
    final cached = existing != null && _projectHistory(existing).contains(target)
        ? existing
        : _windowFromRecentHistory(target);
    if (cached != null && _projectHistory(cached).contains(target)) {
      updateSlash(() => readingJump = null);
      showReadingWindow(cached, target, reveal: true, match: match);
      readingAddresses[target] = location;
      storeReading(ReadingPosition(location, 0));
      flushReading();
      return;
    }
    final control = readingLookup = FileTransferControl();
    final request = (target: target, token: control);
    updateSlash(() => readingJump = request);
    bool valid() =>
        mounted &&
        !control.cancelled &&
        readingEpoch == revision &&
        transcriptSession == id;
    try {
      final page =
          await TranscriptNavigation(widget.gateway, widget.profile, id).locate(
            location,
            stillOpen: valid,
            scanHistory: !latestOnMiss,
            control: control,
          );
      if (!valid()) return;
      final window = ReadingWindow(page, target);
      if (!_projectHistory(window).contains(target)) {
        throw GatewayError('这条消息不在当前会话历史中，或记录已变化');
      }
      recordReadingAddresses(
        page.rows,
        newestOffset: page.latestFirst ? page.offset : null,
      );
      showReadingWindow(window, target, reveal: true, match: match);
      final known = readingAddresses[target];
      final located = MessageAddress(
        target,
        promptId: known?.promptId ?? location.promptId,
        tailOffset: known?.tailOffset ?? location.tailOffset,
      );
      readingAddresses[target] = located;
      storeReading(ReadingPosition(located, 0));
      flushReading();
    } catch (_) {
      if (mounted && valid()) {
        if (latestOnMiss) {
          returnToLatest();
        } else {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(context.tr('无法定位此消息'))));
        }
      }
    } finally {
      if (identical(readingLookup, control)) readingLookup = null;
      if (mounted && readingJump == request) {
        updateSlash(() => readingJump = null);
      }
    }
  }

  Future<void> loadReadingWindow({required bool older}) async {
    final window = readingWindow;
    final id = transcriptSession;
    if (window == null || id == null || readingLoading || readingJump != null) {
      return;
    }
    if (!(older ? window.oldest.hasOlder : window.latest.hasNewer)) return;
    final control = adjacentHistoryRead = FileTransferControl();
    bool current() =>
        mounted &&
        identical(adjacentHistoryRead, control) &&
        identical(readingWindow, window) &&
        transcriptSession == id;
    updateSlash(() => readingError = null);
    try {
      final page = await TranscriptNavigation(
        widget.gateway,
        widget.profile,
        id,
      ).adjacent(
        older ? window.oldest : window.latest,
        older: older,
        control: control,
      );
      if (!current()) return;
      updateSlash(() {
        window.extend(page, older: older);
        recordReadingAddresses(
          page.rows,
          newestOffset: page.latestFirst ? page.offset : null,
        );
      });
    } catch (e) {
      if (current()) {
        updateSlash(() => readingError = (older: older, message: e.toString()));
      }
    } finally {
      if (mounted && identical(adjacentHistoryRead, control)) {
        updateSlash(() => adjacentHistoryRead = null);
      }
    }
  }

  void returnToLatest() {
    final wasReading = readingWindow != null || awayFromLatest.value;
    stopReadingLookup();
    stopAdjacentHistoryRead();
    final revision = ++readingEpoch;
    readingGesture = false;
    readingTowardNewer = false;
    if (readingWindow != null || readingJump != null) {
      final previous = readingScroll;
      updateSlash(() {
        readingJump = null;
        readingWindow = null;
        revealedRowId = null;
        revealedMatch = null;
        readingScroll = null;
        readingError = null;
      });
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    }
    if (latestReading != null) {
      storeReading(null);
      flushReading();
    }
    newHistoryWhileReading = false;
    messagesBelow.value = null;
    pinnedQuestion.value = null;
    awayFromLatest.value = false;
    if (wasReading && readOnly) {
      unawaited(retryRecentHistory());
    } else {
      scheduleHistoryCheck(changed: true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && readingEpoch == revision && latestScroll.hasClients) {
        latestScroll.jumpTo(latestScroll.position.minScrollExtent);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Widget _buildLiveReadingTail() {
    final session = stored ?? transcriptSession;
    return ValueListenableBuilder<String>(
      valueListenable: thought,
      builder: (context, thinking, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (thinking.isNotEmpty && showsReasoning)
            ReasoningPreview(
              key: ValueKey(reasoningPresentation),
              text: thinking,
              preview: reasoningPresentation == ReasoningPresentation.preview,
              initiallyExpanded:
                  reasoningPresentation == ReasoningPresentation.expanded,
            ),
          _LiveReplyText(
            source: live,
            active: widget.keyboardActive,
            render: (value) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: MessageContent(
                body: value,
                streaming: true,
                gateway: widget.gateway,
                profile: widget.profile,
                session: session,
                baseDirectory: workspaceDir,
                documentPath: (uri) =>
                    workspaceDocumentPath(uri, baseDirectory: workspaceDir),
                onOpenDocument: (path, fragment) =>
                    openChatFile(path, fragment, session),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEarlierButton() {
    return Center(
      child: TextButton(
        onPressed: canReadOlderHistory ? loadOlder : null,
        child: Text(context.tr(olderHistoryError ?? '查看更早消息')),
      ),
    );
  }

  Widget _buildReadingItem(
    TimelineItem item,
    List<TimelineItem> timeline, {
    bool fromNewest = true,
  }) {
    final id = _readingId(item);
    final original = _renderReadingItem(item, timeline);
    final match = id != null && id == revealedRowId ? revealedMatch : null;
    final message = match == null
        ? original
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [TranscriptMatchPreview(match), original],
          );
    final child = switch (revealedRowId) {
      final target? when _containsReadingId(item, target) => Semantics(
        container: true,
        label: context.tr('已定位消息'),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            message,
            PositionedDirectional(
              start: -8,
              top: 6,
              bottom: 6,
              width: 2,
              child: ColoredBox(color: Theme.of(context).colorScheme.primary),
            ),
          ],
        ),
      ),
      _ => message,
    };
    final key = ValueKey<Object>(
      _readingItemIdentity(item, fromNewest: fromNewest),
    );
    return _ReadingCell(
      key: key,
      info: (
        item: item,
        address: id == null ? null : readingAddresses[id] ?? MessageAddress(id),
      ),
      registry: readingCells,
      child: child,
    );
  }

  Widget _renderReadingItem(TimelineItem item, List<TimelineItem> timeline) {
    String? resolve(Uri uri) =>
        workspaceDocumentPath(uri, baseDirectory: workspaceDir);
    Iterable<GalleryImage> gallery() => timelineGallery(
      timeline,
      resolve: resolve,
      baseDirectory: workspaceDir,
    );
    final session = stored ?? transcriptSession;
    final colors = Theme.of(context).colorScheme;
    if (item is TimelineActivity) {
      final target = revealedRowId;
      return ActivityGroup(
        key: ValueKey(item.expanded),
        activity: item,
        expansion: activityExpansion,
        revealed: target != null && _containsReadingId(item, target),
        mediaScope: WorkspaceScope(
          widget.gateway,
          widget.profile,
          session: session,
          cwd: workspaceDir,
        ),
        gallery: gallery,
        addressFor: (rowId) => readingAddresses[rowId],
      );
    }
    final row = (item as TimelineMessage).row;
    if (row.commandReceipt case final receipt?) {
      return CommandReceiptTile(
        receipt: receipt,
        onClosed: restoreChatKeyboard,
      );
    }
    if (row.backgroundNotice case final notice?) {
      final reveal = row.rowId != null && row.rowId == revealedRowId;
      return BackgroundNoticeTile(
        key: ValueKey((row.rowId ?? notice.raw, reveal)),
        notice: notice,
        gateway: widget.gateway,
        profile: widget.profile,
        session: session,
        gallery: gallery,
        baseDirectory: workspaceDir,
        initiallyExpanded: reveal,
        documentPath: resolve,
        onOpenDocument: (path, fragment) =>
            openChatFile(path, fragment, session),
      );
    }
    final bubble = Align(
      alignment: row.user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: row.user
              ? math.min(560, MediaQuery.sizeOf(context).width * .84)
              : double.infinity,
        ),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: row.user
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
            : const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: row.user ? colors.secondaryContainer : null,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(19),
            topRight: Radius.circular(19),
            bottomLeft: Radius.circular(19),
            bottomRight: Radius.circular(7),
          ),
        ),
        child: MessageContent(
          user: row.user,
          body: row.body,
          gateway: widget.gateway,
          profile: widget.profile,
          session: session,
          gallery: gallery,
          baseDirectory: workspaceDir,
          documentPath: resolve,
          onOpenDocument: (path, fragment) =>
              openChatFile(path, fragment, stored ?? transcriptSession),
        ),
      ),
    );
    if (row.rowId == null) return bubble;
    return Column(
      crossAxisAlignment: row.user
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        bubble,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!row.user && row.body.isNotEmpty)
              _ReadingCopyButton(text: row.body),
            IconButton(
              tooltip: context.tr('消息操作'),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 42, minHeight: 28),
              icon: Icon(
                Icons.more_horiz_rounded,
                color: colors.onSurfaceVariant,
                size: 18,
              ),
              onPressed: () => messageActions(row),
            ),
          ],
        ),
      ],
    );
  }

  _TimelineStyle _timelineStyle({required bool beginning, int? reveal}) => (
    showReasoning: showsReasoning,
    expandReasoning: reasoningPresentation == ReasoningPresentation.expanded,
    includeBeginning: beginning,
    receipts: commandReceipts,
    revealedRowId: reveal,
  );

  _ReadingTimeline _projectHistory(ReadingWindow window) =>
      readingTimelines.history(
        window,
        _timelineStyle(
          beginning: !window.oldest.hasOlder,
          reveal: revealedRowId,
        ),
      );

  Widget buildReadingTimeline() {
    final window = readingWindow;
    final timeline = shownReadingTimeline = window == null
        ? readingTimelines.latest(
            rows,
            _timelineStyle(beginning: oldest?.nextOffset == null),
          )
        : _projectHistory(window);
    scheduleReadingIndicators();
    final viewport = _trackedTranscript(
      window == null
          ? _latestTranscript(timeline)
          : _buildHistoryWindow(window, timeline),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        viewport,
        if (readingJump != null || readingLoading || loadingOlder)
          const PositionedDirectional(
            top: 0,
            start: 0,
            end: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (readingJump != null)
          PositionedDirectional(
            top: 8,
            end: 16,
            child: ActionChip(
              avatar: const Icon(Icons.close_rounded, size: 16),
              label: Text(context.tr('取消定位')),
              onPressed: cancelReadingJump,
            ),
          )
        else if (readingError case final failure?)
          PositionedDirectional(
            top: 8,
            start: 16,
            end: 16,
            child: _readingRetry(failure.older, failure.message),
          ),
        if (readingError == null &&
            readingJump == null &&
            !readingLoading &&
            !loadingOlder)
          PositionedDirectional(
            top: 6,
            start: 18,
            end: 18,
            child: _pinnedQuestionButton(),
          ),
        Align(
          alignment: Alignment.bottomCenter,
          child: ValueListenableBuilder<bool>(
            valueListenable: awayFromLatest,
            builder: (context, away, _) => window != null || away
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: _jumpToLatestButton(),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  Widget _pinnedQuestionButton() => ValueListenableBuilder<_PinnedQuestion?>(
    valueListenable: pinnedQuestion,
    builder: (context, question, _) {
      final rowId = question?.row.rowId;
      if (question == null || rowId == null) return const SizedBox.shrink();
      final colors = Theme.of(context).colorScheme;
      final action = context.tr('回到这条提问');
      final preview = question.preview;
      void jump() {
        if (shownReadingTimeline?.contains(rowId) != true) return;
        unawaited(
          revealReadingMessage(
            readingAddresses[rowId] ?? MessageAddress(rowId, promptId: rowId),
          ),
        );
      }

      return Align(
        alignment: AlignmentDirectional.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Semantics(
            container: true,
            button: true,
            label: preview.isEmpty ? action : '$action · $preview',
            onTap: jump,
            excludeSemantics: true,
            child: Material(
              color: colors.secondaryContainer,
              elevation: 1,
              shadowColor: colors.shadow.withValues(alpha: .16),
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: jump,
                child: SizedBox(
                  height: _pinnedQuestionHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            preview.isEmpty ? action : preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSecondaryContainer),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.arrow_upward_rounded,
                          color: colors.onSecondaryContainer,
                          size: 17,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _jumpToLatestButton() => ValueListenableBuilder<int?>(
    valueListenable: messagesBelow,
    builder: (context, count, _) {
      final jump = context.tr('回到最新');
      final label = switch (count) {
        1 => context.tr('1 条消息'),
        final int n when n > 1 => context.strings.format('{count} 条消息', {
          'count': n,
        }),
        null when newHistoryWhileReading => context.tr('有新消息'),
        _ => jump,
      };
      return Semantics(
        container: true,
        button: true,
        label: label == jump ? jump : '$jump · $label',
        onTap: returnToLatest,
        excludeSemantics: true,
        child: FilledButton.tonalIcon(
          onPressed: returnToLatest,
          icon: const Icon(Icons.arrow_downward_rounded, size: 17),
          label: Text(label),
        ),
      );
    },
  );

  Widget _trackedTranscript(Widget child) => SizedBox.expand(
    key: readingViewport,
    child: NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical) {
          scheduleReadingIndicators();
        }
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: trackReading,
        child: child,
      ),
    ),
  );

  Widget _latestTranscript(_ReadingTimeline presentation) {
    final timeline = presentation.items;
    return ListView.builder(
      controller: latestScroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      itemCount: timeline.length + 1 + (oldest?.nextOffset != null ? 1 : 0),
      findChildIndexCallback: (key) => key is ValueKey<Object>
          ? presentation.latestIndices[key.value]
          : null,
      itemBuilder: (context, index) {
        if (index == 0) return _buildLiveReadingTail();
        if (index > timeline.length) return _buildEarlierButton();
        return _buildReadingItem(timeline[timeline.length - index], timeline);
      },
    );
  }

  Widget _readingRetry(bool older, String message) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 14, end: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.tr(message),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () => loadReadingWindow(older: older),
              child: Text(context.tr('重试')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryWindow(ReadingWindow window, _ReadingTimeline timeline) {
    final split = timeline.split(window.center);
    if (split == null) {
      return const SizedBox.expand();
    }
    const centerKey = ValueKey('chat-reading-center');
    return CustomScrollView(
      key: ValueKey(readingScroll),
      controller: readingScroll,
      center: centerKey,
      slivers: [
        if (window.oldest.hasOlder)
          SliverToBoxAdapter(
            key: const ValueKey('older-page'),
            child: _historyEdge(older: true),
          ),
        SliverPadding(
          key: const ValueKey('older-reading-items'),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          sliver: _readingSliver(timeline.items, split.$1),
        ),
        SliverPadding(
          key: centerKey,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          sliver: _readingSliver(timeline.items, split.$2),
        ),
        if (window.latest.hasNewer)
          SliverToBoxAdapter(
            key: const ValueKey('newer-page'),
            child: _historyEdge(older: false),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 56)),
      ],
    );
  }

  Widget _readingSliver(List<TimelineItem> timeline, _ReadingSlice slice) {
    return SliverList.builder(
      itemCount: slice.count,
      findChildIndexCallback: (key) =>
          key is ValueKey<Object> ? slice.indices[key.value] : null,
      itemBuilder: (_, index) => _buildReadingItem(
        timeline[slice.start + index * slice.step],
        timeline,
        fromNewest: slice.step < 0,
      ),
    );
  }

  Widget _historyEdge({required bool older}) => Center(
    child: TextButton(
      onPressed: readingLoading ? null : () => loadReadingWindow(older: older),
      child: Text(older ? context.tr('查看更早消息') : context.tr('查看更新消息')),
    ),
  );
}

class _LiveReplyText extends StatefulWidget {
  const _LiveReplyText({
    required this.source,
    required this.active,
    required this.render,
  });

  final ValueNotifier<String> source;
  final bool active;
  final Widget Function(String body) render;

  @override
  State<_LiveReplyText> createState() => _LiveReplyTextState();
}

class _LiveReplyTextState extends State<_LiveReplyText> {
  late String _rendered = widget.source.value;
  Timer? _update;

  @override
  void initState() {
    super.initState();
    if (widget.active) widget.source.addListener(_onDelta);
  }

  @override
  void didUpdateWidget(_LiveReplyText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.source, oldWidget.source) &&
        widget.active == oldWidget.active) {
      return;
    }
    oldWidget.source.removeListener(_onDelta);
    _update?.cancel();
    _update = null;
    if (widget.active) {
      _rendered = widget.source.value;
      widget.source.addListener(_onDelta);
    }
  }

  void _onDelta() {
    final body = widget.source.value;
    // Clearing a finished segment and showing its persisted row happen together.
    if (body.isEmpty || _rendered.isEmpty) {
      _update?.cancel();
      _update = null;
      setState(() => _rendered = body);
      return;
    }
    _update ??= Timer(const Duration(milliseconds: 80), () {
      _update = null;
      setState(() => _rendered = widget.source.value);
    });
  }

  @override
  void dispose() {
    widget.source.removeListener(_onDelta);
    _update?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _rendered.isEmpty ? const SizedBox.shrink() : widget.render(_rendered);
}

Object _readingItemIdentity(TimelineItem item, {bool fromNewest = true}) {
  if (item case TimelineActivity(:final rows)) {
    final row = fromNewest ? rows.last : rows.first;
    return ('activity', row.rowId ?? row.toolId ?? row);
  }
  final row = (item as TimelineMessage).row;
  return ('message', row.rowId ?? row.commandReceipt ?? row);
}

int? _readingId(TimelineItem item) => switch (item) {
  TimelineMessage(:final row) => row.rowId,
  TimelineActivity(:final rows) =>
    rows.map((row) => row.rowId).nonNulls.firstOrNull,
};

bool _containsReadingId(TimelineItem item, int id) => switch (item) {
  TimelineMessage(:final row) => row.rowId == id,
  TimelineActivity(:final rows) => rows.any((row) => row.rowId == id),
};

class _ReadingCell extends StatefulWidget {
  const _ReadingCell({
    super.key,
    required this.info,
    required this.registry,
    required this.child,
  });
  final _ReadingCellInfo info;
  final Map<BuildContext, _ReadingCellInfo> registry;
  final Widget child;

  @override
  State<_ReadingCell> createState() => _ReadingCellState();
}

class _ReadingCellState extends State<_ReadingCell> {
  @override
  void initState() {
    super.initState();
    widget.registry[context] = widget.info;
  }

  @override
  void didUpdateWidget(_ReadingCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.registry[context] = widget.info;
  }

  @override
  void dispose() {
    widget.registry.remove(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
