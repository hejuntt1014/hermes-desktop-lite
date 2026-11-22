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

class SessionTasks extends StatefulWidget {
  const SessionTasks({
    super.key,
    required this.snapshot,
    required this.running,
  });
  final SessionTaskSnapshot snapshot;
  final bool running;

  @override
  State<SessionTasks> createState() => _SessionTasksState();
}

class _SessionTasksState extends State<SessionTasks> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final tasks = widget.snapshot.tasks;
    final done = tasks.where((row) => row['status'] == 'completed').length;
    final current = tasks
        .where((row) => row['status'] == 'in_progress')
        .map((row) => row['content'])
        .whereType<String>()
        .firstOrNull;
    final label = widget.running ? '当前任务' : '以往任务';
    final style = Theme.of(context).textTheme.labelMedium;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
      child: Material(
        color: c.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (open)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.builder(
                    primary: false,
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(top: 6),
                    itemCount: tasks.length,
                    itemBuilder: (context, index) {
                      final row = tasks[index];
                      final status = row['status'];
                      final icon = switch (status) {
                        'completed' => Icons.check_circle_rounded,
                        'cancelled' => Icons.remove_circle_outline,
                        'in_progress' => Icons.timelapse_rounded,
                        _ => Icons.radio_button_unchecked,
                      };
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: Icon(
                          icon,
                          size: 16,
                          color: status == 'completed'
                              ? c.primary
                              : c.onSurfaceVariant,
                        ),
                        minLeadingWidth: 16,
                        title: Text(
                          row['content'] as String,
                          style: TextStyle(
                            fontSize: 13,
                            color: status == 'completed'
                                ? c.onSurfaceVariant
                                : c.onSurface,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              InkWell(
                onTap: () => setState(() => open = !open),
                child: SizedBox(
                  height: 36,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            value: tasks.isEmpty ? 0 : done / tasks.length,
                            strokeWidth: 2.4,
                            backgroundColor: c.outlineVariant,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Text(
                          '${context.tr(label)} $done/${tasks.length}',
                          style: style?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        if (current != null && !open) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              current,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: style?.copyWith(color: c.onSurfaceVariant),
                            ),
                          ),
                        ] else
                          const Spacer(),
                        Icon(
                          open
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.keyboard_arrow_up_rounded,
                          size: 18,
                          color: c.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
