part of 'chat.dart';

typedef _RewriteTarget = ({ChatRow prompt, bool deep});

extension _ChatRewriteTarget on _ChatPageState {
  bool _historyRowMutable(ChatRow row) {
    final current = historyTail?.session;
    return !row.archived &&
        (!widget.gateway.canonical ||
            current == null ||
            row.historySession == null ||
            row.historySession == current);
  }

  List<ChatRow> _rewriteRows(ReadingWindow? history) =>
      history == null ? rows : displayRows(history.records).toList();

  bool _mayRetryFrom(
    List<ChatRow> messages,
    int index,
    ReadingWindow? history,
  ) {
    if (!isRetryableReply(messages, index) ||
        !_historyRowMutable(messages[index])) {
      return false;
    }
    if (retryPromptIndex(messages, index) case final owner?) {
      return _historyRowMutable(messages[owner]);
    }
    final hasOlder = history?.oldest.hasOlder ?? (oldest?.nextOffset != null);
    return hasOlder && !messages.take(index).any(rewriteTurnBoundary);
  }

  Future<_RewriteTarget> _resolveRewriteTarget(
    ChatRow selected,
    ReadingWindow? history,
    String session, {
    required bool retry,
    required bool Function() current,
  }) async {
    var messages = _rewriteRows(history);
    var index = _findRewriteRow(messages, selected);
    if (index < 0 || !_historyRowMutable(messages[index])) {
      throw GatewayError('会话已变化，请刷新后再试');
    }
    if (!retry) {
      return _rewriteTarget(messages, index, history?.latest.hasNewer == true);
    }
    if (!_mayRetryFrom(messages, index, history)) {
      throw GatewayError('无法确定要重试的回复，请重新定位消息');
    }
    final prompt = retryPromptIndex(messages, index);
    final needsNewer =
        history?.latest.hasNewer == true &&
        !messages.skip(index + 1).any(rewriteTurnBoundary);
    if (prompt != null && !needsNewer) {
      return _rewriteTarget(messages, prompt, history?.latest.hasNewer == true);
    }

    final lookup = TranscriptNavigation(
      widget.gateway,
      widget.profile,
      session,
    );
    final ReadingWindow window;
    if (history == null) {
      final id = selected.rowId!;
      final address = readingAddresses[id] ?? MessageAddress(id);
      final page = await lookup.locate(address, stillOpen: current);
      window = ReadingWindow(page, id);
    } else {
      window = ReadingWindow.detached(history);
    }
    while (current()) {
      messages = _rewriteRows(window);
      index = _findRewriteRow(messages, selected);
      if (index < 0 || !isRetryableReply(messages, index)) break;
      final owner = retryPromptIndex(messages, index);
      if (owner != null && !_historyRowMutable(messages[owner])) break;
      final bool older;
      if (owner == null) {
        if (!window.oldest.hasOlder ||
            messages.take(index).any(rewriteTurnBoundary)) {
          break;
        }
        older = true;
      } else if (window.latest.hasNewer &&
          !messages.skip(index + 1).any(rewriteTurnBoundary)) {
        older = false;
      } else {
        return _rewriteTarget(messages, owner, window.latest.hasNewer);
      }
      final boundary = older ? window.oldest : window.latest;
      final page = await lookup.adjacent(boundary, older: older);
      if (!current()) break;
      if (identical(page, boundary)) break;
      final length = window.records.length;
      window.extend(page, older: older);
      final hasMore = older ? window.oldest.hasOlder : window.latest.hasNewer;
      if (window.records.length == length && hasMore) break;
    }
    throw GatewayError('无法确定要重试的回复，请重新定位消息');
  }
}

int _findRewriteRow(List<ChatRow> rows, ChatRow selected) => rows.indexWhere(
  (row) =>
      row.rowId != null &&
      row.rowId == selected.rowId &&
      row.user == selected.user &&
      row.body == selected.body,
);

_RewriteTarget _rewriteTarget(List<ChatRow> rows, int index, bool hasNewer) => (
  prompt: rows[index],
  deep: hasNewer || rows.skip(index + 1).any((row) => row.user),
);
