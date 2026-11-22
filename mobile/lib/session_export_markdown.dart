part of 'session_export.dart';

final _ticks = RegExp(r'`+');
final _inlineImageHeader = RegExp(r'^data:image/[a-zA-Z0-9.+-]+;base64,');
final _invalidBase64Character = RegExp(r'[^A-Za-z0-9+/=]');
final _markdownSpecial = RegExp(r'[\\`*_\[\]<>&#~|]');

bool _isInlineImage(String value) {
  final header = _inlineImageHeader.matchAsPrefix(value);
  return header != null &&
      header.end < value.length &&
      _invalidBase64Character.allMatches(value, header.end).isEmpty;
}

String _backticks(String text, int minimum) {
  var width = minimum;
  for (final run in _ticks.allMatches(text)) {
    final needed = run.end - run.start + 1;
    if (needed > width) width = needed;
  }
  return '`' * width;
}

String _code(String text) {
  final singleLine = text.replaceAll(RegExp(r'[\r\n]'), ' ');
  final fence = _backticks(singleLine, 1);
  return '$fence $singleLine $fence';
}

class _MarkdownExport {
  _MarkdownExport(this.sink, this.strings);

  final StringSink sink;
  final MobileStrings strings;
  final _tools = <String, String>{};

  void start(String title, String id, String exportedAt) {
    final plainTitle = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    final escaped = (plainTitle.isEmpty ? strings.text('会话记录') : plainTitle)
        .replaceAllMapped(_markdownSpecial, (match) => '\\${match[0]}');
    sink.writeln('# $escaped\n');
    sink.writeln('- ${strings.format('会话 {value}', {'value': _code(id)})}');
    sink.writeln('- ${strings.format('导出时间 {value}', {'value': exportedAt})}');
  }

  void _heading(String label, Json row) {
    final stamp = row['timestamp'];
    if (stamp is num && stamp.isFinite && stamp > 0 && stamp < 8640000000000) {
      final time = DateTime.fromMillisecondsSinceEpoch(
        (stamp * 1000).round(),
        isUtc: true,
      );
      final utc = time
          .toIso8601String()
          .split('.')
          .first
          .replaceFirst('T', ' ');
      label = '$label · $utc UTC';
    }
    sink.writeln('\n## $label\n');
  }

  void _quoted(String text) {
    final fence = _backticks(text, 3);
    sink.writeln('${fence}text\n$text\n$fence\n');
  }

  void write(Json row) {
    if (row['display_kind'] == 'hidden') return;
    final content = historyDisplayContent(
      row,
      fallback: row['content'] ?? row['text'],
    );
    switch (row['role']) {
      case 'user':
        _writeMessage(row, messageBody(content), user: true);
      case 'assistant':
        _writeMessage(row, messageBody(content), user: false);
      case 'tool':
        final id = row['tool_call_id']?.toString() ?? '';
        final tracked = _tools.remove(id);
        final name =
            row['tool_name'] ?? row['name'] ?? tracked ?? strings.text('工具');
        _heading(
          strings.format('工具结果 · {value}', {'value': _code('$name')}),
          row,
        );
        if (id.isNotEmpty) {
          sink.writeln(
            '${strings.format('调用 ID {value}', {'value': _code(id)})}\n',
          );
        }
        final diff = toolInlineDiff(row);
        if (diff.isNotEmpty) {
          sink.writeln('### ${strings.text('变更')}\n');
          _quoted(diff);
        }
        final output = content is Json
            ? const JsonEncoder.withIndent('  ').convert(content)
            : activityText(content);
        _quoted(output);
        if (toolImagePath(content is Json ? content : activityJson(output))
            case final image?) {
          _writeAttachments(const <String>{}, {image});
        }
      case 'system':
      case 'notice':
        final text = activityText(content);
        if (text.isEmpty) return;
        _heading(strings.text('系统'), row);
        _quoted(text);
    }
  }

  void _writeMessage(Json row, String raw, {required bool user}) {
    final projection = user
        ? projectUserMessage(raw)
        : (body: raw, filePaths: const <String>[]);
    final files = {...projection.filePaths};
    final images = <String>{};
    final prose = <String>[];
    String? fence;
    for (final line in projection.body.split('\n')) {
      final marker = messageFence.firstMatch(line);
      if (marker != null) {
        final mark = marker.group(1)!;
        if (fence == null) {
          fence = mark;
        } else if (mark.startsWith(fence) &&
            line.substring(marker.end).trim().isEmpty) {
          fence = null;
        }
        prose.add(line);
      } else if (fence == null && line.startsWith('@image:data:image/')) {
        images.add(line.substring('@image:'.length).trimRight());
      } else if ((fence == null
              ? messageLineAttachment(line, user: user)
              : null)
          case final image? when image.image) {
        images.add(image.path);
        if (image.caption case final caption?) prose.add(caption);
      } else if ((fence == null && user ? attachedPath(line.trimRight()) : null)
          case final path?) {
        files.add(path);
      } else {
        prose.add(line);
      }
    }
    images.addAll(
      structuredMessageImages(row['content'])
          .where((path) => !path.contains(RegExp(r'[\x00\r\n]'))),
    );
    final text = prose.join('\n');
    final hasText = text.trim().isNotEmpty;
    final reasoning = messageReasoning(row);
    final calls = historyToolCalls(row['tool_calls']).toList();
    final hasBody = hasText || files.isNotEmpty || images.isNotEmpty;
    if (!hasBody && reasoning.isEmpty && calls.isEmpty) return;
    final toolOnly = !user && !hasBody && calls.isNotEmpty;
    _heading(
      strings.text(
        user
            ? '用户'
            : toolOnly
            ? '工具调用'
            : '助手',
      ),
      row,
    );
    if (hasText) {
      if (user) {
        _quoted(text);
      } else {
        sink.writeln('$text\n');
      }
    }
    if (reasoning.isNotEmpty) {
      sink.writeln('### ${strings.text('推理过程')}\n');
      _quoted(reasoning);
    }
    _writeAttachments(files, images);
    for (final call in calls) {
      final function = call['function'] is Json
          ? call['function'] as Json
          : call;
      final name = switch (function['name']) {
        final String value when value.isNotEmpty => value,
        _ => strings.text('工具'),
      };
      if (call['id'] != null) _tools[call['id'].toString()] = name;
      final label = _code(name);
      sink.writeln(
        '### ${toolOnly ? label : strings.format('调用 {value}', {'value': label})}\n',
      );
      final args = activityText(function['arguments'] ?? function['args']);
      if (args.isNotEmpty) _quoted(args);
    }
  }

  void _writeAttachments(Set<String> files, Set<String> images) {
    if (files.isEmpty && images.isEmpty) return;
    sink.writeln('### ${strings.text('附件')}\n');
    for (final file in files) {
      if (images.contains(file)) continue;
      sink.writeln(
        '- ${strings.format('文件 {name} · {path}', {'name': _code(workspaceName(file)), 'path': _code(file)})}',
      );
    }
    for (final image in images) {
      if (_isInlineImage(image)) {
        sink.writeln('- ![${strings.text('图片')}](<$image>)');
      } else {
        sink.writeln(
          '- ${strings.format('远程图片 {value}', {'value': _code(image)})}',
        );
      }
    }
    sink.writeln();
  }
}
