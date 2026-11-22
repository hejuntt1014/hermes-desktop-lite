import 'dart:convert';

import 'gateway.dart';

class HistoryPage {
  const HistoryPage({
    required this.sessionId,
    required this.rows,
    this.offset = 0,
    this.nextOffset,
  });

  final String sessionId;
  final List<Json> rows;
  final int offset;
  final int? nextOffset;

  int get oldestOffset => offset + rows.length - 1;

  Iterable<Json> after(Json boundary) {
    final index = rows.lastIndexWhere((row) => sameHistoryRow(boundary, row));
    if (index >= 0) return rows.skip(index + 1);

    // A full page of new rows can push the last known row outside the tail.
    // Persisted row IDs increase within a profile's history store.
    final boundaryId = historyRowId(boundary);
    if (nextOffset != null &&
        boundaryId != null &&
        rows.every((row) => (historyRowId(row) ?? 0) > boundaryId)) {
      return rows;
    }
    return const [];
  }
}

int? historyRowId(Json row) {
  final id = row['row_id'] ?? row['id'];
  return id is int && id > 0 ? id : null;
}

Iterable<Json> historyToolCalls(Object? calls) {
  if (calls is String) {
    try {
      calls = jsonDecode(calls);
    } on FormatException {
      return const [];
    }
  }
  return calls is List ? calls.whereType<Json>() : const [];
}

String messageReasoning(Json row) {
  if (row.containsKey('display_reasoning')) {
    final projection = row['display_reasoning'];
    return projection is String ? projection.trim() : '';
  }
  for (final source in [row['reasoning'], row['reasoning_content']]) {
    if (source is String && source.trim().isNotEmpty) return source.trim();
  }
  return _reasoningDetails(row['reasoning_details']);
}

String _reasoningDetails(Object? details) {
  if (details is String) {
    final text = details.trim();
    if (!text.startsWith('[') && !text.startsWith('{')) return text;
    try {
      details = jsonDecode(text);
    } on FormatException {
      return '';
    }
  }
  final parts = <String>{};
  void add(Object? value) {
    if (value is String && value.trim().isNotEmpty) parts.add(value.trim());
  }

  for (final block in details is List ? details : [details]) {
    if (block is String) {
      add(block);
    } else if (block is Json && !_encryptedReasoning(block)) {
      for (final key in ['summary', 'thinking', 'content', 'text']) {
        final value = block[key];
        if (value is String && value.trim().isNotEmpty) {
          add(value);
          break;
        }
      }
      _nestedReasoning(block, add);
    }
  }
  return parts.join('\n\n');
}

bool _encryptedReasoning(Json block) {
  final type = block['type'];
  return type is String &&
      type.startsWith('reasoning.') &&
      type.endsWith('encrypted');
}

void _nestedReasoning(Json block, void Function(Object?) add) {
  final pending = <Object?>[block];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (node is List) {
      pending.addAll(node.reversed);
    } else if (node is Json && !_encryptedReasoning(node)) {
      add(switch (node['type']) {
        'reasoning.summary' ||
        'summary_text' => node['summary'] ?? node['text'],
        'reasoning.text' || 'reasoning_text' => node['text'],
        _ => node['thinking'],
      });
      pending.addAll(
        node.entries
            .toList()
            .reversed
            .where(
              (entry) => !const {
                'signature',
                'data',
                'projection',
                'encrypted_content',
              }.contains(entry.key),
            )
            .map((entry) => entry.value),
      );
    }
  }
}

bool sameHistoryRow(Json left, Json right, {bool compareContent = false}) {
  if (compareContent) return _jsonEquals(left, right);
  final leftId = left['row_id'] ?? left['id'];
  final rightId = right['row_id'] ?? right['id'];
  return leftId != null && rightId != null
      ? leftId == rightId
      : _jsonEquals(left, right);
}

bool sameHistoryTail(Json? before, Json? after) {
  if (before == null || after == null) return before == after;
  if (!sameHistoryRow(before, after) ||
      before['finish_reason'] != after['finish_reason']) {
    return false;
  }
  final saved = before['content'];
  final latest = after['content'];
  // The metadata read omits inline image payloads.
  return saved is! String ||
      latest is! String ||
      saved.contains('data:image/') ||
      saved == latest;
}

bool _jsonEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.entries.every(
          (e) => b.containsKey(e.key) && _jsonEquals(e.value, b[e.key]),
        );
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

List<Json> olderPrefix(HistoryPage current, HistoryPage older) {
  if (current.sessionId != older.sessionId || current.rows.isEmpty) {
    throw GatewayError('会话历史已更新，请重新读取');
  }
  final overlap = older.rows.lastIndexWhere(
    (row) => sameHistoryRow(current.rows.first, row),
  );
  if (overlap < 0 || overlap == 0 && older.nextOffset != null) {
    throw GatewayError('会话历史已更新，请重新读取');
  }
  return older.rows.sublist(0, overlap);
}
