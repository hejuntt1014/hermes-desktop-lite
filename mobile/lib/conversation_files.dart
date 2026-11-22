import 'dart:isolate';

import 'package:markdown/markdown.dart' as md;

import 'attachment_view.dart';
import 'gateway.dart';
import 'history.dart';
import 'markdown_blocks.dart';
import 'message_content.dart';
import 'timeline.dart' show activityJson;
import 'transcript_navigation.dart';
import 'workspace.dart';

typedef HistoryRecord = ({Json row, int tailOffset});

class ConversationFile {
  const ConversationFile(
    this.name,
    this.address, {
    this.path,
    this.fragment,
    this.inlineIndex,
    this.projectedImages = false,
    this.genericName = false,
    required this.image,
  });

  final String name;
  final MessageAddress address;
  final String? path, fragment;
  final int? inlineIndex;
  final bool image, projectedImages, genericName;

  String? get destination {
    final filePath = path;
    final heading = fragment;
    return heading == null || filePath == null
        ? filePath
        : '$filePath#$heading';
  }

  Future<Json> readSource(
    TranscriptNavigation navigation, {
    bool Function()? stillOpen,
    bool scanHistory = true,
    FileTransferControl? control,
  }) async {
    final row = await navigation.readRow(
      address,
      stillOpen: stillOpen,
      scanHistory: scanHistory,
      control: control,
    );
    if (row == null) throw GatewayError('原消息没有可预览的图片');
    return row;
  }

  Future<String> resolve(TranscriptNavigation navigation) async =>
      path ?? resolveInlineImage(await readSource(navigation));

  String resolveInlineImage(Json row) {
    final reference = _attachmentReferences(row)
        .map((ref) => ref.path)
        .where((path) => path.startsWith('data:image/'))
        .toSet()
        .toList(growable: false);
    final index = inlineIndex ?? -1;
    if (index < 0 || index >= reference.length) {
      throw GatewayError('原消息没有可预览的图片');
    }
    return reference[index];
  }
}

String? _relativePath(String value, String? cwd) {
  if (value.startsWith('data:image/')) return value;
  var path = value.trim();
  if (path.length > 4096 || path.isEmpty) return null;
  if (const ['"', "'", '`'].contains(path[0]) &&
      path.length > 2 &&
      path.endsWith(path[0])) {
    path = path.substring(1, path.length - 1);
  }
  if (path.startsWith('file://')) {
    final uri = Uri.tryParse(path);
    if (uri == null || uri.path.isEmpty) return null;
    final String decoded;
    try {
      decoded = Uri.decodeComponent(uri.path);
    } on FormatException {
      return null;
    }
    path = uri.host.isEmpty || uri.host == 'localhost'
        ? decoded
        : '//${uri.host}$decoded';
    if (RegExp(r'^/[a-zA-Z]:/').hasMatch(path)) path = path.substring(1);
  }
  if (path.endsWith('/') ||
      path.endsWith('\\') ||
      path.startsWith('//') && !value.startsWith('file://') ||
      RegExp(r'[\x00-\x1f]').hasMatch(path)) {
    return null;
  }
  final drive = RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(path);
  if (path.contains(':') && !drive) return null;
  if (drive ||
      path.startsWith('/') ||
      path.startsWith('~/') ||
      path.startsWith('\\\\')) {
    return path;
  }
  if (path == '.' || path == '..') return null;
  return workspaceFilePath(path, cwd);
}

typedef _Reference = ({String path, String? label, String? fragment});
String? _imageMarkerPath(String line) {
  final marker = line.startsWith('@image:')
      ? '@image:'
      : line.startsWith('MEDIA:')
      ? 'MEDIA:'
      : '';
  if (marker.isEmpty) return null;
  final path = line.substring(marker.length).trim();
  return path.isEmpty ? null : path;
}
final _standalone = RegExp(
  r'^(?:/|~/|\.{1,2}/|[a-zA-Z]:[/\\]|\\\\).+\.[\w-]{1,16}$',
);

Iterable<_Reference> _attachmentReferences(Json row) sync* {
  yield* _references(row);
  if ({'user', 'assistant'}.contains(row['role']) &&
      (row['display_content'] != null || row['text'] != null)) {
    for (final path in structuredMessageImages(row['content'])) {
      yield (path: path, label: null, fragment: null);
    }
  }
}

bool _hasProjectedImage(Object? content) {
  if (content is! String || !content.contains('[image]')) return false;
  String? fence;
  for (final line in content.split('\n')) {
    if (messageFence.firstMatch(line) case final marker?) {
      final closing = marker[1]!;
      if (fence == null) {
        fence = closing;
      } else if (closing.startsWith(fence) &&
          line.substring(marker.end).trim().isEmpty) {
        fence = null;
      }
    } else if (fence == null && line.trim() == '[image]') {
      return true;
    }
  }
  return false;
}

Iterable<_Reference> _references(Json row) sync* {
  final role = row['role'];
  final raw = messageBody(
    historyDisplayContent(row),
  );
  if (role == 'tool') {
    if (toolImagePath(activityJson(raw)) case final path?) {
      yield (path: path, label: null, fragment: null);
    }
    return;
  }
  if (role != 'user' && role != 'assistant') return;
  final projected = role == 'user'
      ? projectUserMessage(raw)
      : (body: raw, filePaths: const <String>[]);
  for (final path in projected.filePaths) {
    yield (path: path, label: null, fragment: null);
  }
  final body = projected.body;
  final references = role == 'assistant'
      ? markdownReferenceDefinitions(body)
      : const <String, md.LinkReference>{};
  if (role == 'user') {
    for (final image in messageImageReferences(body, user: true)) {
      yield (path: image.path, label: image.alt, fragment: null);
    }
  }
  for (final line in messageLines(
    body,
    user: role == 'user',
    references: references,
  )) {
    if (line.inFence) continue;
    final trimmed = line.text.trim();
    final attachment = line.attachment;
    if (attachment != null) {
      yield (
        path: attachment.path,
        label: attachment.label,
        fragment: attachment.fragment,
      );
    } else if ((attachedPath(trimmed) ?? _imageMarkerPath(trimmed))
        case final path?) {
      yield (path: path, label: null, fragment: null);
    } else if (role == 'assistant') {
      final loose =
          trimmed.startsWith('`') && trimmed.endsWith('`') && trimmed.length > 2
          ? trimmed.substring(1, trimmed.length - 1)
          : trimmed;
      if (_standalone.hasMatch(loose)) {
        yield (path: loose, label: null, fragment: null);
      }
    }
  }
  if (role != 'assistant' || !body.contains('[')) return;
  Iterable<_Reference> walk(md.Node node) sync* {
    if (node is! md.Element || node.tag == 'code' || node.tag == 'pre') return;
    if (node.tag == 'a' || node.tag == 'img') {
      final raw = node.attributes[node.tag == 'img' ? 'src' : 'href'];
      if (raw == null) return;
      if (raw.startsWith('data:image/') && node.tag == 'img') {
        yield (path: raw, label: node.attributes['alt'], fragment: null);
        return;
      }
      final link = raw.split('#').first.split('?').first;
      if (link.isEmpty || !link.contains(RegExp(r'[/\\.]'))) return;
      String path;
      try {
        path = link.startsWith('file://') ? link : Uri.decodeComponent(link);
      } on FormatException {
        return;
      }
      if (node.tag == 'img' &&
          !workspaceImage(_relativePath(path, null) ?? '')) {
        return;
      }
      final uri = node.tag == 'a' ? Uri.tryParse(raw) : null;
      yield (
        path: path,
        label: node.tag == 'img' ? node.attributes['alt'] : node.textContent,
        fragment: uri == null ? null : workspaceDocumentFragment(uri),
      );
    }
    for (final child in node.children ?? const <md.Node>[]) {
      yield* walk(child);
    }
  }

  final doc = messageMarkdownDocument(references);
  for (final node in doc.parseLines(body.split('\n'))) {
    yield* walk(node);
  }
}

List<ConversationFile> collectConversationFiles(
  List<HistoryRecord> records,
  String? cwd, {
  bool allowProjected = true,
}) {
  final files = <ConversationFile>[];
  for (final item in records) {
    final row = item.row, id = historyRowId(item.row);
    if (id == null ||
        row['display_kind'] == 'hidden' ||
        !{'user', 'assistant', 'tool'}.contains(row['role'])) {
      continue;
    }
    final address = MessageAddress(
      id,
      promptId: row['role'] == 'user' ? id : null,
      tailOffset: item.tailOffset,
    );
    final references = <(String, String?), String>{};
    for (final ref in _attachmentReferences(row)) {
      final path = _relativePath(ref.path, cwd);
      if (path == null ||
          (cwd == null || cwd.isEmpty) && !workspaceFileHasRoot(path)) {
        continue;
      }
      final key = (path, workspaceImage(path) ? null : ref.fragment);
      final name = ref.label?.trim() ?? '';
      final previous = references[key];
      if (previous == null || previous.isEmpty && name.isNotEmpty) {
        references[key] = name;
      }
    }
    var nextInline = 0;
    for (final MapEntry(key: (path, fragment), value: name)
        in references.entries) {
      final inline = path.startsWith('data:image/');
      files.add(
        ConversationFile(
          name.isNotEmpty
              ? name
              : inline
              ? '图片'
              : workspaceName(path),
          address,
          path: inline ? null : path,
          fragment: fragment,
          image: workspaceImage(path),
          inlineIndex: inline ? nextInline++ : null,
          genericName: inline && name.isEmpty,
        ),
      );
    }
    if (allowProjected &&
        row['role'] != 'tool' &&
        _hasProjectedImage(row['content'])) {
      files.add(
        ConversationFile(
          '图片',
          address,
          image: true,
          projectedImages: true,
          genericName: true,
        ),
      );
    }
  }
  return files;
}

Future<List<ConversationFile>> scanConversationFiles(
  List<HistoryRecord> records,
  String? cwd, {
  bool allowProjected = true,
}) => Isolate.run(
  () => collectConversationFiles(records, cwd, allowProjected: allowProjected),
);
