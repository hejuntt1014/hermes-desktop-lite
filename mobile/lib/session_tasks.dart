import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'gateway.dart';

class SessionTaskSnapshot {
  const SessionTaskSnapshot(this.tasks, this.revision);
  final List<Json> tasks;
  final int? revision;

  static SessionTaskSnapshot? parse(dynamic value, [int depth = 0]) {
    if (depth > 2) return null;
    if (value is String && value.length < 512000) {
      try {
        return parse(jsonDecode(value), depth + 1);
      } on FormatException {
        return null;
      }
    }
    if (value is! Json ||
        value['success'] == false ||
        value['ok'] == false ||
        value['error'] != null) {
      return null;
    }
    final rows = value['todos'];
    if (rows is! List) return parse(value['result'], depth + 1);
    final tasks = rows
        .whereType<Json>()
        .where(
          (row) =>
              row['content'] is String &&
              (row['content'] as String).trim().isNotEmpty &&
              {
                'pending',
                'in_progress',
                'completed',
                'cancelled',
              }.contains(row['status']),
        )
        .toList();
    final revision = value['revision'] as int?;
    if (tasks.isEmpty && (rows.isNotEmpty || revision == 0)) return null;
    return SessionTaskSnapshot(tasks, revision);
  }

  static SessionTaskSnapshot? fromHistory(List<Json> rows) {
    for (final row in rows.reversed) {
      if (row['role'] != 'tool' ||
          !{'todo', 'todo_list'}.contains(row['name'] ?? row['tool_name'])) {
        continue;
      }
      final snapshot = parse(row['content']);
      if (snapshot != null) return snapshot;
    }
    return null;
  }
}

class SessionTasks extends StatelessWidget {
  const SessionTasks({
    super.key,
    required this.snapshot,
    required this.running,
  });
  final SessionTaskSnapshot snapshot;
  final bool running;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final done = snapshot.tasks
        .where((row) => row['status'] == 'completed')
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      child: Material(
        color: c.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          dense: true,
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: const Icon(Icons.checklist_rounded, size: 18),
          title: Text(
            '${running ? context.tr('当前任务') : context.tr('以往任务')} $done/${snapshot.tasks.length}',
            style: const TextStyle(fontSize: 13),
          ),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.builder(
                primary: false,
                shrinkWrap: true,
                itemCount: snapshot.tasks.length,
                itemBuilder: (context, index) {
                  final row = snapshot.tasks[index];
                  final status = row['status'];
                  final icon = switch (status) {
                    'completed' => Icons.check_circle_rounded,
                    'cancelled' => Icons.remove_circle_outline,
                    'in_progress' => Icons.timelapse_rounded,
                    _ => Icons.radio_button_unchecked,
                  };
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      icon,
                      size: 16,
                      color: status == 'completed'
                          ? c.primary
                          : c.onSurfaceVariant,
                    ),
                    title: Text(
                      row['content'] as String,
                      style: const TextStyle(fontSize: 13),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
