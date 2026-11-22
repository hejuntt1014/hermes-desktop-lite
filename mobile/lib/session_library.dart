import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'chat_tabs.dart';
import 'gateway.dart';
import 'mobile_locale.dart';
import 'session_activity.dart';

enum SessionMenuAction {
  open,
  rename,
  pin,
  pinUp,
  pinDown,
  read,
  color,
  copyId,
  archive,
  branch,
  export,
  share,
  delete;

  bool get requiresGateway => switch (this) {
    open || color || copyId || pinUp || pinDown => false,
    _ => true,
  };
}

const sessionListPageSize = 60;
const hiddenSessionSources = 'acp,cron,kanban,oneshot,subagent,tool';

typedef ActiveConversation = ({Json row, ConversationActivity activity});

Future<Json?> chooseUnreadConversation(
  BuildContext context, {
  required ValueListenable<List<Json>?> rows,
  required Listenable activity,
  required Set<String> Function() busySessions,
  required Future<bool> Function(String id) markRead,
}) => showModalBottomSheet<Json>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => _UnreadConversations(
    rows: rows,
    activity: activity,
    busySessions: busySessions,
    markRead: markRead,
  ),
);

class _UnreadConversations extends StatefulWidget {
  const _UnreadConversations({
    required this.rows,
    required this.activity,
    required this.busySessions,
    required this.markRead,
  });

  final ValueListenable<List<Json>?> rows;
  final Listenable activity;
  final Set<String> Function() busySessions;
  final Future<bool> Function(String id) markRead;

  @override
  State<_UnreadConversations> createState() => _UnreadConversationsState();
}

class _UnreadConversationsState extends State<_UnreadConversations> {
  final marking = <String>{};
  bool failed = false;

  Future<void> _mark(String id) async {
    if (!marking.add(id)) return;
    setState(() => failed = false);
    final success = await widget.markRead(id);
    if (!mounted) return;
    setState(() {
      marking.remove(id);
      failed = !success;
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: FractionallySizedBox(
      heightFactor: .64,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Semantics(
              header: true,
              child: Text(
                context.tr('未读会话'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          if (failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                context.tr('暂时无法更新未读状态'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([widget.rows, widget.activity]),
              builder: (context, _) {
                final rows = widget.rows.value;
                if (rows == null)
                  return const Center(child: CircularProgressIndicator());
                final busy = widget.busySessions();
                final entries = rows
                    .where((row) => !busy.contains(tabSessionId(row)))
                    .toList();
                if (entries.isEmpty) {
                  return Center(child: Text(context.tr('没有未读会话')));
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final row = entries[index];
                    final id = tabSessionId(row)!;
                    final pending = marking.contains(id);
                    return ConversationTile(
                      key: ValueKey(id),
                      row: row,
                      onTap: () {
                        if (!pending) Navigator.pop(context, row);
                      },
                      trailing: IconButton(
                        tooltip: context.tr('标记为已读'),
                        onPressed: pending ? null : () => _mark(id),
                        icon: pending
                            ? const SizedBox.square(
                                dimension: 17,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons.mark_chat_read_outlined,
                                size: 19,
                              ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

Future<Json?> chooseActiveConversation(
  BuildContext context, {
  required Gateway gateway,
  required String profile,
  required List<Json> knownRows,
}) {
  Future<List<ActiveConversation>> read() =>
      _readActiveConversations(gateway, profile, knownRows);
  var pending = read();
  return showModalBottomSheet<Json>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => StatefulBuilder(
      builder: (context, update) => SafeArea(
        top: false,
        child: FractionallySizedBox(
          heightFactor: .56,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 8),
                child: Semantics(
                  header: true,
                  child: Text(
                    context.tr('进行中的会话'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              Expanded(
                child: FutureBuilder(
                  future: pending,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: TextButton.icon(
                          onPressed: () => update(() {
                            pending = read();
                          }),
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(context.tr('重新读取')),
                        ),
                      );
                    }
                    final entries =
                        snapshot.data ?? const <ActiveConversation>[];
                    if (entries.isEmpty)
                      return Center(child: Text(context.tr('暂无进行中的会话')));
                    return ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final (:row, :activity) = entries[index];
                        final icon = switch (activity) {
                          ConversationActivity.waiting =>
                            Icons.chat_bubble_outline_rounded,
                          ConversationActivity.running =>
                            Icons.timelapse_rounded,
                          ConversationActivity.background =>
                            Icons.bolt_outlined,
                        };
                        return ListTile(
                          leading: Icon(icon, size: 20),
                          title: Text(
                            sessionTitle(row) ?? context.tr('未命名会话'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(context.tr(activity.label)),
                          onTap: () => Navigator.pop(sheet, row),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<T?> _available<T>(Future<T> pending) async {
  try {
    return await pending;
  } catch (_) {
    return null;
  }
}

Future<List<ActiveConversation>> _readActiveConversations(
  Gateway gateway,
  String profile,
  List<Json> knownRows,
) async {
  final (turns, background) = await (
    _available(SessionActivityService.turns(gateway, profile)),
    _available(SessionActivityService.roster(gateway, profile)),
  ).wait;
  if (turns == null && background == null) throw GatewayError('网关未返回可读取的活动');
  return resolveActiveConversations(
    gateway,
    profile,
    knownRows,
    turns: turns,
    backgroundIds: background ?? const {},
  );
}

Future<List<ActiveConversation>> resolveActiveConversations(
  Gateway gateway,
  String profile,
  List<Json> knownRows, {
  required TurnRoster? turns,
  required Set<String> backgroundIds,
}) async {
  final storedIds = {...?turns?.storedSessions, ...backgroundIds};
  final excluded = hiddenSessionSources.split(',').toSet();
  final seen = <String>{};
  bool owned(Json row) =>
      (row['profile'] == null || row['profile'] == profile) &&
      row['archived'] != true &&
      !excluded.contains(row['source']);
  for (final row in knownRows.where(owned)) {
    if (tabSessionId(row) case final id?) seen.add(id);
    seen.add(sessionLineage(row));
  }
  final missing = await Future.wait([
    for (final id in storedIds.difference(seen))
      _available(
        gateway.readConversationPage(
          'api/sessions/${Uri.encodeComponent(id)}',
          query: {'profile': profile},
          timeout: const Duration(seconds: 8),
        ),
      ).then(
        (row) =>
            row?['profile'] == profile && tabSessionId(row) == id ? row : null,
      ),
  ]);
  final result = <String, ActiveConversation>{};
  const ranks = {
    ConversationActivity.waiting: 0,
    ConversationActivity.running: 1,
    ConversationActivity.background: 2,
  };
  for (final row in [...knownRows, ...missing.nonNulls].where(owned)) {
    final id = tabSessionId(row);
    if (id == null) continue;
    final lineage = sessionLineage(row);
    final direct = turns?.states[id];
    final aliased = turns?.states[lineage];
    final activity =
        direct == ConversationActivity.waiting ||
            aliased == ConversationActivity.waiting
        ? ConversationActivity.waiting
        : direct ??
              aliased ??
              (backgroundIds.contains(id) || backgroundIds.contains(lineage)
                  ? ConversationActivity.background
                  : null);
    if (activity == null) continue;
    final previous = result[lineage];
    if (previous == null ||
        ranks[activity]! < ranks[previous.activity]! ||
        activity == previous.activity &&
            _timestamp(row) > _timestamp(previous.row)) {
      result[lineage] = (row: row, activity: activity);
    }
  }
  return result.values.toList()..sort((a, b) {
    final urgency = ranks[a.activity]!.compareTo(ranks[b.activity]!);
    return urgency == 0
        ? _timestamp(b.row).compareTo(_timestamp(a.row))
        : urgency;
  });
}

typedef SessionHeading = ({String? label, DateTime? month});
typedef LibraryEntry = ({
  Json row,
  int depth,
  bool last,
  SessionHeading? heading,
});

String? _wireId(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

String sessionLineage(Json row) =>
    _wireId(row['_lineage_root_id']) ??
    _wireId(row['lineage_root']) ??
    tabSessionId(row) ??
    '';

String? _parent(Json row) => _wireId(row['_reset_from']) != null
    ? null
    : _wireId(row['_branched_from']) ?? _wireId(row['parent_session_id']);

int _timestamp(Json row) => sessionTime(row)?.millisecondsSinceEpoch ?? 0;

List<LibraryEntry> _tree(List<Json> rows, {bool pin = false}) {
  final continued = <(String, String)>{
    for (final row in rows)
      if (_parent(row) case final parent?) (sessionLineage(row), parent),
  };
  final winners = <String, Json>{};
  bool terminal(Json row) =>
      !continued.contains((sessionLineage(row), tabSessionId(row)));

  for (final row in rows) {
    final lineage = sessionLineage(row);
    final previous = winners[lineage];
    if (previous == null ||
        (terminal(row) != terminal(previous)
            ? terminal(row)
            : _timestamp(row) > _timestamp(previous))) {
      winners[lineage] = row;
    }
  }
  final aliases = <String, Json>{};
  for (final row in rows) {
    final key = sessionLineage(row);
    final winner = winners[key]!;
    aliases[key] = winner;
    if (row['_lineage_ids'] case final List trail) {
      for (final id in trail.whereType<String>()) {
        aliases.putIfAbsent(id, () => winner);
      }
    }
    if (tabSessionId(row) case final id?) aliases[id] = winner;
  }
  final children = <Json, List<Json>>{};
  final roots = <Json>[];
  for (final row in winners.values) {
    final parent = aliases[_parent(row)];
    if (!pin && parent != null && !identical(parent, row)) {
      children.putIfAbsent(parent, () => []).add(row);
    } else {
      roots.add(row);
    }
  }
  for (final group in children.values) {
    group.sort((a, b) => _timestamp(b).compareTo(_timestamp(a)));
  }
  final newest = <Json, int>{};
  int recency(Json row) {
    if (newest[row] case final cached?) return cached;
    var result = _timestamp(row);
    newest[row] = result;
    for (final child in children[row] ?? const <Json>[]) {
      result = math.max(result, recency(child));
    }
    return newest[row] = result;
  }

  roots.sort((a, b) => recency(b).compareTo(recency(a)));

  final output = <LibraryEntry>[];
  final seen = <Json>{};
  final rootGroups = <SessionHeading>{};
  final clock = DateTime.now();
  for (final root in [...roots, ...winners.values]) {
    final date = recency(root);
    final heading = pin || date == 0
        ? null
        : sessionGroup(DateTime.fromMillisecondsSinceEpoch(date), now: clock);
    final stack = [(root, 0, true)];
    while (stack.isNotEmpty) {
      final (row, depth, last) = stack.removeLast();
      if (!seen.add(row)) continue;
      output.add((
        row: row,
        depth: depth,
        last: last,
        heading: depth == 0 && heading != null && rootGroups.add(heading)
            ? heading
            : null,
      ));
      final nested = children[row] ?? const <Json>[];
      for (var i = nested.length - 1; i >= 0; i--) {
        stack.add((nested[i], depth + 1, i == nested.length - 1));
      }
    }
  }
  return output;
}

({List<LibraryEntry> pins, List<LibraryEntry> sessions}) projectLibrary(
  Iterable<Json> rows, {
  required bool searching,
  required bool archived,
  required List<String> pinOrder,
}) {
  if (searching) {
    return (
      pins: const [],
      sessions: [
        for (final (index, row) in rows.indexed)
          (
            row: row,
            depth: 0,
            last: true,
            heading: index == 0 ? (label: '搜索结果', month: null) : null,
          ),
      ],
    );
  }
  if (archived) return (pins: const [], sessions: _tree(rows.toList()));
  final pins = _tree(
    rows.where((row) => row['pinned'] == true).toList(),
    pin: true,
  );
  final ranks = {for (final (index, key) in pinOrder.indexed) key: index};
  final ordered = pins.indexed.toList()
    ..sort((a, b) {
      final left = ranks[sessionLineage(a.$2.row)] ?? pinOrder.length + a.$1;
      final right = ranks[sessionLineage(b.$2.row)] ?? pinOrder.length + b.$1;
      return left.compareTo(right);
    });
  return (
    pins: ordered.map((entry) => entry.$2).toList(),
    sessions: _tree(rows.where((row) => row['pinned'] != true).toList()),
  );
}
