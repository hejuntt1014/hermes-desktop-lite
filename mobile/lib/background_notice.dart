import 'gateway.dart';
import 'message_content.dart';

final _taskHeader = RegExp(
  r'^--- [✓✗⚠] TASK \d+/\d+(?:: [\s\S]*?)? {2}\(status=[^\r\n]*\) ---\r?\n',
  multiLine: true,
);
final _delegationHeader = RegExp(
  r'^\[ASYNC DELEGATION (?:BATCH )?COMPLETE — deleg_[A-Za-z0-9_]+\]$',
);

class BackgroundNotice {
  const BackgroundNotice(
    this.raw,
    this.report, {
    required this.process,
    required this.taskCount,
  });

  final String raw, report;
  final bool process;
  final int taskCount;

  static bool _isProcess(String text, Json row) =>
      row['display_kind'] == 'process_complete' ||
      text.startsWith('[IMPORTANT: Background process ') && text.endsWith(']');

  static bool recognizes(String text, Json row) {
    if (row['role'] != 'user' && row['role'] != 'system') return false;
    final content = text.trim();
    if (content.isEmpty) return false;
    if (row['display_kind'] == 'async_delegation_complete' ||
        _isProcess(content, row)) {
      return true;
    }
    if (!content.startsWith('[ASYNC DELEGATION')) return false;
    final newline = content.indexOf('\n');
    if (newline < 0 ||
        !_delegationHeader.hasMatch(
          content.substring(0, newline).trimRight(),
        )) {
      return false;
    }
    return content.contains('\nA background ') || _taskHeader.hasMatch(content);
  }

  static String _historyText(Json row) {
    final raw = messageBody(row['content']);
    return raw.trim().isEmpty
        ? messageBody(row['display_content'] ?? row['text'])
        : raw;
  }

  static bool isHistoryNotice(Json row) {
    if (row['role'] != 'user' && row['role'] != 'system') return false;
    return recognizes(_historyText(row), row);
  }

  static BackgroundNotice? fromHistory(Json row) {
    if (row['role'] != 'user' && row['role'] != 'system') return null;
    final raw = _historyText(row);
    if (!recognizes(raw, row)) return null;
    final content = raw.trim();
    final process = _isProcess(content, row);
    final reports = <String>[];
    var taskCount = 0;
    if (process) {
      const prefix = '[IMPORTANT: ';
      reports.add(
        content.startsWith(prefix) && content.endsWith(']')
            ? content.substring(prefix.length, content.length - 1)
            : content,
      );
    } else if (content.startsWith('[ASYNC DELEGATION')) {
      final headers = _taskHeader.allMatches(content).toList();
      taskCount = headers.length;
      for (final (index, header) in headers.indexed) {
        final end = index + 1 < headers.length
            ? headers[index + 1].start
            : content.length;
        reports.add(content.substring(header.end, end));
      }
      if (headers.isEmpty) {
        final separator = RegExp(r'\r?\n--- (?:RESULT|ERROR) ---\r?\n')
            .firstMatch(content);
        if (separator != null) reports.add(content.substring(separator.end));
      }
    } else {
      reports.add(content);
    }
    final report = reports
        .map(
          (part) => part
              .split(RegExp(r'\r?\n'))
              .where(
                (line) => !line.startsWith(
                  'Full live transcript (complete tool/assistant trace): ',
                ),
              )
              .join('\n')
              .trim(),
        )
        .where((part) => part.isNotEmpty)
        .join('\n\n');
    return BackgroundNotice(
      raw,
      report,
      process: process,
      taskCount: taskCount,
    );
  }
}
