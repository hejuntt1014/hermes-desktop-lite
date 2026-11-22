import 'dart:convert';

import 'gateway.dart';
import 'history.dart';
import 'message_content.dart';
import 'media_gallery.dart';
import 'command_receipts.dart';
import 'background_notice.dart';
import 'workspace.dart' show workspaceFilePath;

class ChatRow {
  const ChatRow({
    required this.user,
    required this.body,
    this.activity,
    this.rowId,
    this.historySession,
    this.archived = false,
    this.toolId,
    this.arguments = '',
    this.inlineDiff = '',
    this.running = false,
    this.failed = false,
    this.imagePath,
    this.commandReceipt,
    this.backgroundNotice,
  });
  final bool user;
  final String body;
  final int? rowId;
  final String? historySession;
  final bool archived;
  final String? activity, toolId, imagePath;
  final String arguments, inlineDiff;
  final bool running, failed;
  final CommandReceipt? commandReceipt;
  final BackgroundNotice? backgroundNotice;

  ChatRow.command(CommandReceipt receipt)
    : this(user: false, body: receipt.output, commandReceipt: receipt);

  ChatRow.notice(BackgroundNotice notice, {int? rowId})
    : this(
        user: false,
        body: notice.raw,
        backgroundNotice: notice,
        rowId: rowId,
      );

  factory ChatRow.incomingUser(String body, Json payload) {
    final notice = BackgroundNotice.fromHistory({
      'role': 'user',
      'content': body,
      'display_kind': payload['display_kind'],
    });
    return notice == null
        ? ChatRow(user: true, body: displayedUserMessageBody(body))
        : ChatRow.notice(notice);
  }

  static ChatRow? visibleIncomingUser(Object? content, Json payload) {
    if (payload['display_kind'] == 'hidden') return null;
    final body = messageBody(content);
    final row = ChatRow.incomingUser(body, payload);
    return row.body.isEmpty ? null : row;
  }

  factory ChatRow.result(Json event, {int? rowId, Object? callArguments}) {
    final result =
        event['result'] ??
        event['content'] ??
        event['result_text'] ??
        event['text'];
    final body = activityText(result);
    final status = result is Json ? result : activityJson(body);
    return ChatRow(
      user: false,
      body: body,
      rowId: rowId,
      activity: (event['name'] ?? event['tool_name'] ?? '工具').toString(),
      toolId: (event['tool_id'] ?? event['tool_call_id'] ?? event['id'])
          ?.toString(),
      imagePath: toolImagePath(status),
      inlineDiff: toolInlineDiff(event),
      arguments: [
        event['args'],
        event['args_text'],
        event['arguments'],
        callArguments,
      ].map(activityText).firstWhere(
        (text) => text.trim().isNotEmpty,
        orElse: () => '',
      ),
      failed:
          event['failed'] == true ||
          event['status'] == 'error' ||
          status?['success'] == false ||
          status?['ok'] == false ||
          (status?['error'] is String &&
              (status!['error'] as String).trim().isNotEmpty) ||
          (status?['exit_code'] is int && status!['exit_code'] != 0),
    );
  }

  ChatRow mergeResult(ChatRow result) => ChatRow(
    user: false,
    body: result.body.isEmpty ? body : result.body,
    activity: activity,
    rowId: result.rowId ?? rowId,
    toolId: toolId,
    arguments: arguments.isEmpty ? result.arguments : arguments,
    inlineDiff: result.inlineDiff.isEmpty ? inlineDiff : result.inlineDiff,
    failed: failed || result.failed,
    imagePath: result.imagePath ?? imagePath,
  );

  ChatRow withRowId(int id) => ChatRow(
    user: user,
    body: body,
    activity: activity,
    rowId: id,
    historySession: historySession,
    archived: archived,
    toolId: toolId,
    arguments: arguments,
    inlineDiff: inlineDiff,
    running: running,
    failed: failed,
    imagePath: imagePath,
    commandReceipt: commandReceipt,
    backgroundNotice: backgroundNotice,
  );
}

final _toolAnsi = RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]');

String toolInlineDiff(Json row) {
  final metadata = row['display_metadata'];
  final tool = metadata is Json ? metadata['tool_result_metadata'] : null;
  final value = row['inline_diff'] ?? (tool is Json ? tool['inline_diff'] : null);
  return value is String ? value.replaceAll(_toolAnsi, '') : '';
}

String activityText(dynamic value) {
  if (value == null) return '';
  final converted = messageBody(value);
  return converted.isNotEmpty || value is String
      ? converted
      : const JsonEncoder.withIndent('  ').convert(value);
}

Json? activityJson(String text) {
  if (text.length > 64 * 1024 || !text.trimLeft().startsWith('{')) return null;
  try {
    final value = jsonDecode(text);
    return value is Json ? value : null;
  } on FormatException {
    return null;
  }
}

Iterable<ChatRow> displayRows(Iterable<dynamic> records) sync* {
  final calls = <String, ({String name, Object? args})>{};
  for (final row in records.whereType<Json>()) {
    if (row['display_kind'] == 'hidden') continue;
    if (BackgroundNotice.fromHistory(row) case final notice?) {
      yield ChatRow.notice(notice, rowId: historyRowId(row));
      continue;
    }
    final role = row['role'];
    if (role == 'assistant') {
      final reasoning = messageReasoning(row);
      if (reasoning.isNotEmpty) {
        yield ChatRow(user: false, body: reasoning, activity: '思考');
      }
      for (final call in historyToolCalls(row['tool_calls'])) {
        final id = call['id']?.toString();
        final function = call['function'];
        final name = (function is Json ? function['name'] : null) ?? call['name'];
        if (id != null && name is String) {
          calls[id] = (
            name: name,
            args: (function is Json ? function['arguments'] : null) ??
                call['arguments'],
          );
        }
      }
    }
    final content = historyDisplayContent(row);
    if (role == 'system') {
      if (CommandReceipt.fromSystem(messageBody(content)) case final receipt?) {
        yield ChatRow.command(receipt);
      }
    } else if (role == 'tool') {
      final id = row['tool_call_id']?.toString();
      final call = calls.remove(id);
      final name = row['name'] ?? row['tool_name'] ?? call?.name ?? '工具';
      yield ChatRow.result({
        ...row,
        'name': name,
        'content': content,
      }, rowId: historyRowId(row), callArguments: call?.args);
    } else if (role == 'user' || role == 'assistant') {
      final text = messageBody(content);
      if (text.isNotEmpty) {
        yield ChatRow(
          user: role == 'user',
          body: role == 'user' ? displayedUserMessageBody(text) : text,
          rowId: historyRowId(row),
          historySession: row['session_id'] is String
              ? row['session_id'] as String
              : null,
          archived:
              const {true, 1}.contains(row['archived']) ||
              const {false, 0}.contains(row['active']) ||
              const {true, 1}.contains(row['compacted']),
        );
      }
    }
  }
}

sealed class TimelineItem {
  const TimelineItem();
}

class TimelineMessage extends TimelineItem {
  const TimelineMessage(this.row);
  final ChatRow row;
}

class TimelineActivity extends TimelineItem {
  const TimelineActivity(this.rows, {this.expanded = false});
  final List<ChatRow> rows;
  final bool expanded;
}

Iterable<GalleryImage> timelineGallery(
  Iterable<TimelineItem> items, {
  String? Function(Uri)? resolve,
  String? baseDirectory,
}) sync* {
  for (final item in items) {
    switch (item) {
      case TimelineMessage(:final row):
        if (row.commandReceipt == null) {
          final notice = row.backgroundNotice;
          yield* messageGallery(
            notice == null
                ? row.body
                : notice.report.isEmpty
                ? notice.raw
                : notice.report,
            user: row.user,
            resolve: resolve,
            baseDirectory: baseDirectory,
          );
        }
      case TimelineActivity(:final rows):
        for (final row in rows) {
          if (row.imagePath case final path? when !row.failed) {
            yield GalleryImage.path(workspaceFilePath(path, baseDirectory));
          }
        }
    }
  }
}

List<TimelineItem> groupTimeline(
  Iterable<ChatRow> rows, {
  bool showReasoning = true,
  bool expandReasoning = false,
  Iterable<CommandReceipt> receipts = const [],
  bool includeBeginning = false,
  int? revealedRowId,
}) {
  final items = <TimelineItem>[];
  final positions = <int?, List<CommandReceipt>>{};
  for (final receipt in receipts) {
    if (receipt.after != null || includeBeginning) {
      positions.putIfAbsent(receipt.after, () => []).add(receipt);
    }
  }
  var activities = <ChatRow>[];
  void flush() {
    if (activities.isEmpty) return;
    items.add(TimelineActivity(activities));
    activities = [];
  }

  void appendAt(int? id) {
    final notes = positions.remove(id);
    if (notes == null) return;
    flush();
    for (final receipt in notes) {
      items.add(TimelineMessage(ChatRow.command(receipt)));
    }
  }

  appendAt(null);
  for (final row in rows) {
    if (row.activity == null) {
      flush();
      items.add(TimelineMessage(row));
    } else if (row.activity == '思考' && !showReasoning) {
      continue;
    } else if ((revealedRowId != null && row.rowId == revealedRowId) ||
        row.activity == '思考' && expandReasoning) {
      flush();
      items.add(TimelineActivity([row], expanded: true));
    } else {
      activities.add(row);
    }
    if (row.rowId != null) appendAt(row.rowId);
  }
  flush();
  return items;
}
