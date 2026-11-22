import 'gateway.dart';
import 'history.dart';
import 'message_content.dart';

class MessageAddress {
  const MessageAddress(this.rowId, {this.promptId, this.tailOffset});
  final int rowId;
  final int? promptId, tailOffset;

  Json toWire() => {
    'row_id': rowId,
    'prompt_id': ?promptId,
    'tail_offset': ?tailOffset,
  };

  static MessageAddress? fromWire(Json data) {
    final id = historyRowId(data);
    if (id == null) return null;
    final prompt = data['prompt_id'];
    final tail = data['tail_offset'];
    return MessageAddress(
      id,
      promptId: prompt is int && prompt > 0 ? prompt : null,
      tailOffset: tail is int && tail >= 0 ? tail : null,
    );
  }
}

typedef TranscriptMatchExcerpt = ({String text, int start, int end});

class TranscriptTarget {
  const TranscriptTarget(
    this.profile,
    this.session,
    this.title,
    this.address, {
    this.match,
  });

  final String profile, session, title;
  final MessageAddress address;
  final TranscriptMatchExcerpt? match;
}

class TranscriptWindow {
  const TranscriptWindow(
    this.session,
    this.rows, {
    required this.offset,
    required this.latestFirst,
    required this.hasOlder,
    required this.hasNewer,
    this.total,
  });

  final String session;
  final List<Json> rows;
  final int offset;
  final int? total;
  final bool latestFirst, hasOlder, hasNewer;

  bool contains(int id) => rows.any((row) => historyRowId(row) == id);

  int positionOf(int index) =>
      offset + (latestFirst ? rows.length - 1 - index : index);
}

typedef TranscriptRecord = ({Json row, int tailOffset});

class TranscriptHistoryChanged extends GatewayError {
  TranscriptHistoryChanged() : super('会话历史已更新，请重新搜索');
}

class TranscriptScan {
  TranscriptScan(this.navigation);
  final TranscriptNavigation navigation;
  TranscriptWindow? _page;
  int _index = -1;
  bool _finished = false;

  Future<TranscriptRecord?> next({FileTransferControl? control}) async {
    control?.throwIfCancelled();
    if (_finished) return null;
    if (_index < 0) {
      final page = await navigation._scanPage(_page, control);
      control?.throwIfCancelled();
      if (page == null || page.rows.isEmpty) {
        _finished = true;
        return null;
      }
      _page = page;
      _index = page.rows.length - 1;
    }
    final page = _page!;
    final index = _index--;
    return (row: page.rows[index], tailOffset: page.positionOf(index));
  }
}

class TranscriptNavigation {
  const TranscriptNavigation(this.gateway, this.profile, this.session);
  final Gateway gateway;
  final String profile, session;

  static const _readSize = 80;
  static const _scanSize = 160;
  static const _linearScanSize = 320;
  String get _path => 'api/sessions/${Uri.encodeComponent(session)}';

  static const _pageByteBudget = 8 * 1024 * 1024;

  Future<TranscriptWindow> _read(
    int offset, {
    required bool latestFirst,
    required int limit,
    required bool inlineImages,
    int? anchor,
    FileTransferControl? control,
  }) async {
    final order = latestFirst ? 'latest' : 'oldest';
    Future<TranscriptWindow> resize(int size) {
      // Preserve the target or shared boundary as the window shrinks.
      final distance = (anchor ?? offset) - offset;
      return _read(
        offset + distance - distance * (size - 1) ~/ (limit - 1),
        latestFirst: latestFirst,
        limit: size,
        inlineImages: inlineImages,
        anchor: anchor,
        control: control,
      );
    }

    final Json response;
    try {
      response = await gateway.readConversationPage(
        '$_path/messages',
        control: control,
        backgroundDecode: !inlineImages,
        maxResponseBytes: limit > 2 ? _pageByteBudget : null,
        query: {
          'profile': profile,
          'limit': '$limit',
          'offset': '$offset',
          'order': order,
          'include_compacted': 'true',
          'inline_images': '$inlineImages',
        },
      );
    } on GatewayResponseTooLarge {
      return resize((limit ~/ 2).clamp(2, limit));
    } on GatewayError catch (error) {
      if (limit > _scanSize && {400, 422}.contains(error.status)) {
        return resize(_scanSize);
      }
      rethrow;
    }
    final records = _records(response, limit);
    final page = response['pagination'];
    if (page is! Json ||
        page['offset'] != offset ||
        page['order'] != null && page['order'] != order) {
      throw GatewayError('网关返回的会话分页位置不一致');
    }
    final replyLimit = page['limit'] as int? ?? limit;
    final hasMore = replyLimit > 0 && records.length >= replyLimit;
    return TranscriptWindow(
      response['session_id'] as String? ?? session,
      records,
      offset: offset,
      latestFirst: latestFirst,
      hasOlder: latestFirst ? hasMore : offset > 0,
      hasNewer: latestFirst ? offset > 0 : hasMore,
    );
  }

  List<Json> _records(Json reply, int limit) {
    final records = reply['messages'];
    if (reply['profile'] != null && reply['profile'] != profile ||
        records is! List ||
        records.length > limit) {
      throw GatewayError('网关返回的会话记录范围不一致');
    }
    return records.cast<Json>();
  }

  Stream<TranscriptRecord> scan({FileTransferControl? control}) async* {
    final cursor = TranscriptScan(this);
    while (true) {
      final record = await cursor.next(control: control);
      if (record == null) break;
      yield record;
    }
  }

  /// A cancelled request leaves the previously consumed page as the cursor boundary.
  Future<TranscriptWindow?> _scanPage(
    TranscriptWindow? page,
    FileTransferControl? control,
  ) async {
    if (page == null) {
      return _read(
        0,
        latestFirst: true,
        limit: _linearScanSize,
        inlineImages: false,
        control: control,
      );
    }
    if (!page.hasOlder || page.rows.isEmpty) return null;
    final next = await _neighbor(
      page,
      older: true,
      metadataOnly: true,
      size: _linearScanSize,
      control: control,
    );
    if (next == null) throw TranscriptHistoryChanged();
    final boundary = next.rows.lastIndexWhere(
      (row) => sameHistoryRow(page.rows.first, row),
    );
    if (next.session != page.session ||
        boundary < 0 ||
        boundary == 0 && next.hasOlder) {
      throw TranscriptHistoryChanged();
    }
    if (boundary == 0) return null;
    return TranscriptWindow(
      next.session,
      next.rows.sublist(0, boundary),
      offset: next.offset + next.rows.length - boundary,
      latestFirst: true,
      hasOlder: next.hasOlder,
      hasNewer: true,
    );
  }

  Future<Json?> readRow(
    MessageAddress address, {
    bool Function()? stillOpen,
    bool scanHistory = true,
    bool inlineImages = true,
    FileTransferControl? control,
  }) async {
    bool active() => control?.cancelled != true && stillOpen?.call() != false;
    Future<Json?> readExact(int offset) async {
      if (!active()) return null;
      final page = await _read(
        offset,
        latestFirst: true,
        limit: 1,
        inlineImages: inlineImages,
        control: control,
      );
      final row = page.rows.singleOrNull;
      return row != null && historyRowId(row) == address.rowId ? row : null;
    }

    if (address.tailOffset case final hint?) {
      if (await readExact(hint) case final row?) return row;
      if (!active()) return null;
      final nearby = await _read(
        hint > 40 ? hint - 40 : 0,
        latestFirst: true,
        limit: _scanSize,
        inlineImages: false,
        control: control,
      );
      if (_tailPosition(nearby, address.rowId) case final offset?) {
        if (await readExact(offset) case final row?) return row;
      }
    }
    if (!scanHistory || !active()) return null;
    await for (final item in scan(control: control)) {
      if (!active()) return null;
      if (historyRowId(item.row) == address.rowId) {
        return readExact(item.tailOffset);
      }
    }
    return null;
  }

  Future<TranscriptWindow> locate(
    MessageAddress address, {
    bool Function()? stillOpen,
    bool fallbackToPrompt = false,
    bool scanHistory = true,
    FileTransferControl? control,
  }) async {
    final prompt = address.promptId;
    bool active() => control?.cancelled != true && stillOpen?.call() != false;
    Future<TranscriptWindow?> readAnchor(int anchor) async {
      if (!active()) return null;
      try {
        return await _around(anchor, control: control);
      } on GatewayError catch (error) {
        if (!{404, 405, 501}.contains(error.status)) rethrow;
        return null;
      }
    }

    final initial = await readAnchor(prompt ?? address.rowId);
    if (initial?.contains(address.rowId) == true) return initial!;
    final hint = address.tailOffset;
    if (hint != null && active()) {
      final page = await _locateNearTail(
        address.rowId,
        hint,
        active,
        control: control,
      );
      if (page != null) return page;
    }
    if (prompt != null && prompt != address.rowId) {
      if (initial != null && initial.contains(prompt)) {
        final reply = await _locateAfterPrompt(
          initial,
          address.rowId,
          active,
          control: control,
        );
        if (reply != null) return reply;
      }
      final exact = await readAnchor(address.rowId);
      if (exact?.contains(address.rowId) == true) return exact!;
    }
    if (active()) {
      if (fallbackToPrompt &&
          prompt != null &&
          initial?.contains(prompt) == true) {
        return initial!;
      }
      if (scanHistory) {
        await for (final item in scan(control: control)) {
          if (!active()) break;
          if (historyRowId(item.row) != address.rowId) continue;
          final page = await _locateNearTail(
            address.rowId,
            item.tailOffset,
            active,
            control: control,
          );
          if (page != null) return page;
          break;
        }
      }
    }
    throw GatewayError('这条消息不在当前会话历史中，或记录已变化');
  }

  Future<String?> storedToolResult(
    String toolId, {
    MessageAddress? address,
    required bool Function() stillOpen,
  }) async {
    bool matches(Json row) =>
        row['role'] == 'tool' &&
        row['display_kind'] != 'hidden' &&
        row['tool_call_id'] == toolId;
    String? body(Json row) => [
      row['content'],
      row['result'],
      row['result_text'],
    ].map(messageBody).where((text) => text.isNotEmpty).firstOrNull;

    if (address != null && stillOpen()) {
      try {
        final hint = address.tailOffset;
        if (hint != null) {
          final nearby = await _locateNearTail(
            address.rowId,
            hint,
            stillOpen,
            inlineImages: false,
          );
          if (!stillOpen()) return null;
          final row = nearby?.rows.where(matches).firstOrNull;
          if (row != null) return body(row);
        }
        final page = await locate(
          MessageAddress(address.rowId, promptId: address.promptId),
          stillOpen: stillOpen,
          scanHistory: false,
        );
        if (!stillOpen()) return null;
        final row = page.rows.where(matches).firstOrNull;
        if (row != null) return body(row);
      } on GatewayError catch (error) {
        if (error.status != null && !{404, 405, 501}.contains(error.status) ||
            error is GatewayDisconnected)
          rethrow;
      }
    }
    if (!stillOpen()) return null;
    const desktopResultScanSize = 64 * _scanSize;
    var read = 0;
    await for (final item in scan().take(desktopResultScanSize)) {
      if (!stillOpen()) return null;
      if (matches(item.row)) return body(item.row);
      read++;
    }
    if (read == desktopResultScanSize) {
      throw GatewayError('工具记录超出可读取的历史范围');
    }
    return null;
  }

  Future<TranscriptWindow?> _locateAfterPrompt(
    TranscriptWindow anchor,
    int rowId,
    bool Function() active, {
    FileTransferControl? control,
  }) async {
    var current = anchor;
    // A long tool run can separate a reply from its prompt by several pages.
    for (var page = 0; page < 4 && current.hasNewer && active(); page++) {
      final next = await _neighbor(
        current,
        older: false,
        metadataOnly: true,
        control: control,
      );
      if (!active() || next == null || next.rows.isEmpty) return null;
      final index = next.rows.indexWhere((row) => historyRowId(row) == rowId);
      if (index < 0) {
        current = next;
        continue;
      }
      final position = next.positionOf(index);
      if (next.latestFirst)
        return _locateNearTail(rowId, position, active, control: control);
      final offset = position > 24 ? position - 24 : 0;
      final full = await _read(
        offset,
        latestFirst: false,
        limit: _readSize,
        inlineImages: true,
        anchor: position,
        control: control,
      );
      return active() && full.session == next.session && full.contains(rowId)
          ? full
          : null;
    }
    return null;
  }

  Future<TranscriptWindow?> _locateNearTail(
    int rowId,
    int hint,
    bool Function() active, {
    bool inlineImages = true,
    FileTransferControl? control,
  }) async {
    Future<TranscriptWindow> read(int offset, {bool probe = false}) => _read(
      offset > 24 ? offset - 24 : 0,
      latestFirst: true,
      limit: probe ? _scanSize : _readSize,
      inlineImages: !probe && inlineImages,
      anchor: offset,
      control: control,
    );
    final page = await read(hint);
    if (page.contains(rowId)) return page;
    if (!active()) return null;
    final nearby = await read(hint, probe: true);
    final offset = _tailPosition(nearby, rowId);
    if (nearby.session != page.session || offset == null || !active()) {
      return null;
    }
    final corrected = await read(offset);
    return corrected.session == nearby.session && corrected.contains(rowId)
        ? corrected
        : null;
  }

  Future<TranscriptWindow> _around(
    int rowId, {
    int limit = 120,
    FileTransferControl? control,
  }) async {
    final Json response;
    try {
      response = await gateway.readConversationPage(
        '$_path/messages/around',
        control: control,
        maxResponseBytes: limit > 2 ? _pageByteBudget : null,
        query: {'profile': profile, 'row_id': '$rowId', 'limit': '$limit'},
      );
    } on GatewayResponseTooLarge {
      return _around(rowId, limit: (limit ~/ 2).clamp(2, limit), control: control);
    }
    final raw = _records(response, limit);
    final page = response['pagination'];
    if (page is! Json ||
        page['offset'] is! int ||
        (page['offset'] as int) < 0 ||
        page['order'] != null && page['order'] != 'oldest') {
      throw GatewayError('网关返回的会话分页位置不一致');
    }
    return TranscriptWindow(
      response['session_id'] as String? ?? session,
      raw,
      offset: page['offset'] as int,
      latestFirst: false,
      hasOlder: page['has_older'] == true,
      hasNewer: page['has_newer'] == true,
      total: page['total'] is int ? page['total'] as int : null,
    );
  }

  Future<TranscriptWindow> adjacent(
    TranscriptWindow window, {
    required bool older,
    FileTransferControl? control,
  }) async {
    if (window.rows.isEmpty || !(older ? window.hasOlder : window.hasNewer)) {
      return window;
    }
    return await _neighbor(
          window,
          older: older,
          metadataOnly: false,
          control: control,
        ) ??
        (throw GatewayError('会话历史已更新，请重新定位消息'));
  }

  Future<({HistoryPage page, int offset})?> recoverOlderTail(
    HistoryPage current,
    int boundaryOffset, {
    FileTransferControl? control,
  }) async {
    final moved = await _locateMovedBoundary(
      current.sessionId,
      current.rows,
      0,
      boundaryOffset,
      requireTail: true,
      control: control,
    );
    if (moved == null || moved.offset == boundaryOffset) return null;
    final page = await gateway.historyPage(
      profile,
      session,
      moved.offset,
      control: control,
    );
    return (page: page, offset: moved.offset);
  }

  Future<TranscriptWindow?> _neighbor(
    TranscriptWindow window, {
    required bool older,
    required bool metadataOnly,
    int? size,
    FileTransferControl? control,
  }) async {
    final boundaryIndex = older ? 0 : window.rows.length - 1;
    final boundary = window.rows[boundaryIndex];
    final position = window.positionOf(boundaryIndex);
    bool joins(TranscriptWindow page) {
      if (page.session != window.session) return false;
      final overlap = page.rows.indexWhere(
        (row) => sameHistoryRow(boundary, row),
      );
      if (overlap < 0) return false;
      return older
          ? overlap > 0 || !page.hasOlder
          : overlap + 1 < page.rows.length || !page.hasNewer;
    }

    final page = await _fromBoundary(
      position,
      latestFirst: window.latestFirst,
      older: older,
      metadataOnly: metadataOnly,
      size: size,
      control: control,
    );
    if (joins(page)) return page;
    final total = window.total;
    final tailPosition = window.latestFirst
        ? position
        : total == null
        ? null
        : total - 1 - position;
    if (tailPosition != null &&
        tailPosition >= 0 &&
        page.session == window.session) {
      // A tail probe also finds pages whose prompt-relative offset omitted ancestors.
      final moved = await _locateMovedBoundary(
        window.session,
        window.rows,
        boundaryIndex,
        tailPosition,
        requireTail: metadataOnly,
        control: control,
      );
      if (moved != null) {
        final rebased = await _fromBoundary(
          moved.offset,
          latestFirst: moved.latestFirst,
          older: older,
          metadataOnly: metadataOnly,
          size: size,
          control: control,
        );
        if (joins(rebased)) return rebased;
      }
    }
    return null;
  }

  Future<TranscriptWindow> _fromBoundary(
    int position, {
    required bool latestFirst,
    required bool older,
    required bool metadataOnly,
    int? size,
    FileTransferControl? control,
  }) {
    final increases = older == latestFirst;
    final pageSize = size ?? (metadataOnly ? _scanSize : _readSize);
    final offset = increases
        ? position
        : position > pageSize - 1
        ? position - (pageSize - 1)
        : 0;
    return _read(
      offset,
      latestFirst: latestFirst,
      limit: increases ? pageSize : position - offset + 1,
      inlineImages: !metadataOnly,
      anchor: position,
      control: control,
    );
  }

  Future<({int offset, bool latestFirst})?> _locateMovedBoundary(
    String resolvedSession,
    List<Json> rows,
    int boundaryIndex,
    int position, {
    required bool requireTail,
    FileTransferControl? control,
  }) async {
    final boundary = rows[boundaryIndex];
    const margin = _scanSize ~/ 4;
    final probe = await _read(
      position > margin ? position - margin : 0,
      latestFirst: true,
      limit: _scanSize,
      inlineImages: false,
      control: control,
    );
    if (probe.session != resolvedSession) return null;
    if (_tailPosition(probe, historyRowId(boundary)) case final found?) {
      return (offset: found, latestFirst: true);
    }

    final prompts = rows.asMap().entries.where(
      (entry) =>
          entry.value['role'] == 'user' &&
          historyRowId(entry.value) != null &&
          transcriptText(entry.value).trim().isNotEmpty,
    );
    final prompt = boundaryIndex == 0
        ? prompts.firstOrNull
        : prompts.lastOrNull;
    if (prompt != null) {
      try {
        final anchor = await _around(
          historyRowId(prompt.value)!,
          limit: 1,
          control: control,
        );
        final offset = anchor.offset + boundaryIndex - prompt.key;
        if (offset >= 0 &&
            anchor.session == resolvedSession &&
            anchor.rows.length == 1 &&
            sameHistoryRow(anchor.rows.single, prompt.value)) {
          if (!requireTail) return (offset: offset, latestFirst: false);
          final total = anchor.total;
          if (total != null && offset < total) {
            return (offset: total - 1 - offset, latestFirst: true);
          }
        }
      } on GatewayError catch (error) {
        if (!{404, 405, 501}.contains(error.status)) rethrow;
      }
    }

    // Tool-only pages may lack a usable prompt when the tail advances past the first probe.
    final later = await _read(
      probe.offset + _scanSize,
      latestFirst: true,
      limit: _scanSize,
      inlineImages: false,
      control: control,
    );
    if (later.session != resolvedSession) return null;
    final rebased = _tailPosition(later, historyRowId(boundary));
    return rebased == null ? null : (offset: rebased, latestFirst: true);
  }

  Future<({List<Json> items, int? next})> timeline(int? cursor) async {
    final page = await gateway.readConversationPage(
      '$_path/timeline',
      query: {
        'profile': profile,
        'after_row_id': '${cursor ?? 0}',
        'limit': '200',
      },
    );
    if (page['profile'] != null && page['profile'] != profile ||
        page['entries'] is! List ||
        page['pagination'] is! Json) {
      throw GatewayError('网关返回的时间线范围不一致');
    }
    final info = page['pagination'] as Json;
    final next = info['next_cursor'] as int?;
    if (info['has_more'] == true && (next == null || next <= (cursor ?? 0))) {
      throw GatewayError('网关返回了无效的时间线分页位置');
    }
    final items = (page['entries'] as List)
        .whereType<Json>()
        .where((item) => historyRowId(item) != null)
        .toList();
    return (items: items, next: info['has_more'] == true ? next : null);
  }
}

int? _tailPosition(TranscriptWindow page, int? rowId) {
  if (rowId == null) return null;
  final index = page.rows.indexWhere((row) => historyRowId(row) == rowId);
  return index < 0 ? null : page.positionOf(index);
}

String transcriptText(Json row) {
  if (row['display_kind'] == 'hidden' ||
      !{'user', 'assistant'}.contains(row['role'])) {
    return '';
  }
  final body = messageBody(
    historyDisplayContent(row),
  );
  return row['role'] == 'user' ? displayedUserMessageBody(body) : body;
}
