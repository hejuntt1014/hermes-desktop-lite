import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import 'mobile_locale.dart';
import 'gateway.dart';
import 'attachment_view.dart';
import 'document_outline.dart';
import 'media_gallery.dart';
import 'mobile_themes.dart';
import 'markdown_blocks.dart';
import 'workspace.dart';

Object? historyDisplayContent(Json row, {Object? fallback}) {
  if (row['display_content'] case final content?) return content;
  if (row['role'] == 'user' && row['display_kind'] == 'steer') {
    const opening = '[OUT-OF-BAND USER MESSAGE';
    const closing = '[/OUT-OF-BAND USER MESSAGE]';
    for (final source in [row['api_content'], row['text'], row['content']]) {
      final text = messageBody(source).trim();
      if (!text.startsWith(opening) || !text.endsWith(closing)) continue;
      final firstLine = text.indexOf('\n');
      final end = text.length - closing.length;
      if (firstLine >= 0 && firstLine + 1 < end) {
        final correction = text.substring(firstLine + 1, end).trim();
        if (correction.isNotEmpty) return correction;
      }
    }
  }
  return fallback ?? row['text'] ?? row['content'];
}

String messageBody(dynamic content) {
  if (content is String) return content;
  final parts = switch (content) {
    List values => values,
    Json value => [value],
    _ => const <Object?>[],
  };
  return parts
      .map((part) {
        if (part is String) return part;
        if (part is! Json) return '';
        if (part['text'] is String) return part['text'] as String;
        final path = _structuredImageSource(part);
        return path == null ? '' : '@image:$path';
      })
      .where((v) => v.isNotEmpty)
      .join('\n');
}

String? _structuredImageSource(Json part) {
  final image = part['image_url'];
  final kind = part['type'];
  if (image == null &&
      kind != null &&
      !const {'image', 'image_url', 'input_image'}.contains(kind)) {
    return null;
  }
  final source = image is Json ? image['url'] : image ?? part['url'];
  return source is String && source.isNotEmpty ? source : null;
}

Iterable<String> structuredMessageImages(Object? content) sync* {
  final parts = switch (content) {
    List values => values.whereType<Json>(),
    Json value => [value],
    _ => const <Json>[],
  };
  for (final part in parts) {
    if (part['text'] is String) continue;
    if (_structuredImageSource(part) case final path?) yield path;
  }
}

String displayedUserMessageBody(String body) => projectUserMessage(body).body;

({String body, List<String> filePaths}) projectUserMessage(String raw) {
  final paths = <String, String>{};
  var caption = raw;
  for (
    var note = _leadingVisionNote(caption);
    note != null;
    note = _leadingVisionNote(caption)
  ) {
    paths[_visionAttachmentIdentity(note.path)] = note.path;
    caption = note.rest;
  }
  final projected = _projectAttachedUserContext(caption);
  if (paths.isEmpty) return projected;

  final lines = <String>[];
  if (projected.body.isNotEmpty) {
    for (final line in messageLines(
      projected.body,
      user: true,
      references: const {},
    )) {
      final attachment = line.attachment;
      final retained =
          line.text.startsWith('@image:') && attachment != null && attachment.image
          ? paths.remove(_visionAttachmentIdentity(attachment.path))
          : null;
      lines.add(retained == null ? line.text : '@image:$retained');
    }
  }
  final firstCaption = lines.indexWhere((line) => attachedPath(line) == null);
  lines.insertAll(
    firstCaption < 0 ? lines.length : firstCaption,
    paths.values.map((path) => '@image:$path'),
  );
  return (body: lines.join('\n'), filePaths: projected.filePaths);
}

final _retainedVisionAttachment = RegExp(
  r'^(.*[/]cache)/documents/native-inputs/[a-f0-9]{64}/([^/]+)$',
);

String _visionAttachmentIdentity(String path) {
  final normalized = path.replaceAll('\\', '/');
  final retained = _retainedVisionAttachment.firstMatch(normalized);
  // The gateway retains a copy of a staged image when admitting the prompt.
  return retained == null ? normalized : '${retained[1]}/images/${retained[2]}';
}

final _legacyVisionFailure = RegExp(
  r"^\[The user (?:attached an image but (?:analysis failed|it couldn't be analyzed)|sent an image but (?:I couldn't quite see it|something went wrong))",
);
final _legacyVisionDescription = RegExp(
  r"^\[The user (?:attached an image(?:: |\. Here's what it contains:)|sent an image~ Here's what I can see)",
);
final _legacyVisionInstruction = RegExp(
  r'vision_analyze(?: tool)? (?:using|with) image_url:[ \t]*([^\r\n]+)\][ \t]*(?=\r?$)',
  multiLine: true,
);
final _legacyVisionFooter = RegExp(
  r'\]\r?\n\[(?:If you need a closer look, use vision_analyze with|Examine it with the vision_analyze tool using) image_url:[ \t]*([^\r\n]+)\][ \t]*(?=\r?$)',
  multiLine: true,
);
final _visionBlankLines = RegExp(r'^(?:[ \t]*\r?\n)+');
final _visionParagraphBreak = RegExp(r'\r?\n[ \t]*\r?\n');

({String path, String rest})? _leadingVisionNote(String input) {
  final raw = input.trimLeft();
  if (!raw.startsWith('[The user ')) return null;
  final Match? reference;
  if (_legacyVisionDescription.hasMatch(raw)) {
    reference = _legacyVisionFooter.firstMatch(raw);
  } else if (_legacyVisionFailure.hasMatch(raw)) {
    final limit = _visionParagraphBreak.firstMatch(raw)?.start ?? raw.length;
    reference = _legacyVisionInstruction.firstMatch(raw.substring(0, limit));
  } else {
    return null;
  }
  if (reference == null) return null;
  final referencePath = reference[1]!.trimRight().replaceFirst(
    RegExp(r'[ \t]+~$'),
    '',
  );
  final path = _imagePath(referencePath);
  if (path == null || (!path.startsWith('data:image/') && path.length > 4096)) {
    return null;
  }
  return (
    path: path,
    rest: raw.substring(reference.end).replaceFirst(_visionBlankLines, ''),
  );
}

({String body, List<String> filePaths}) _projectAttachedUserContext(
  String raw,
) {
  const attached = '--- Attached Context ---';
  const warnings = '--- Context Warnings ---';
  if (!raw.contains(attached) && !raw.contains(warnings)) {
    return (body: _imagePlaceholdersRemoved(raw), filePaths: const []);
  }

  final lines = raw.split('\n');
  int? contextStart, warningsStart;
  String? fence;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimRight();
    final marker = messageFence.firstMatch(line);
    if (marker != null) {
      final mark = marker[1]!;
      if (fence == null) {
        fence = mark;
      } else if (mark.startsWith(fence) && line.substring(marker.end).isEmpty) {
        fence = null;
      }
      continue;
    }
    if (fence != null || i == 0 || lines[i - 1].trim().isNotEmpty) continue;
    if (line == warnings && warningsStart == null) warningsStart = i;
    if (line == attached) {
      final first = lines
          .skip(i + 1)
          .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
      if (const [
        '📄 @',
        '📁 @',
        '🌐 @',
        '📌 @',
        '📎 @',
        '🧾 ',
      ].any(first.startsWith)) {
        contextStart = i;
        break;
      }
    }
  }

  var end = contextStart ?? lines.length;
  if (warningsStart case final start?) {
    final items = lines
        .sublist(start + 1, end)
        .where((line) => line.trim().isNotEmpty);
    if (items.isNotEmpty &&
        items.first.startsWith('- @') &&
        items.every((line) => line.startsWith('- '))) {
      end = start;
    }
  }
  if (end == lines.length) {
    return (body: _imagePlaceholdersRemoved(raw), filePaths: const []);
  }

  final visible = _imagePlaceholdersRemoved(
    lines.take(end).join('\n').trimRight(),
  );
  final references = <String, String>{};
  if (contextStart case final index?) {
    String? fence;
    for (final line in lines.skip(index + 1)) {
      if (messageFence.firstMatch(line) case final marker?) {
        final mark = marker[1]!;
        if (fence == null) {
          fence = mark;
        } else if (mark.startsWith(fence) &&
            line.substring(marker.end).trim().isEmpty) {
          fence = null;
        }
        continue;
      }
      if (fence != null ||
          !(line.startsWith('📄 @file:') || line.startsWith('📎 @file:'))) {
        continue;
      }
      final metadata = line.lastIndexOf(' (');
      final reference = metadata < 0 ? null : line.substring(3, metadata);
      if (reference == null) continue;
      if (attachedPath(reference) case final path?) {
        references[reference] = path;
      }
    }
  }
  final missing = references.keys.where(
    (reference) => !visible.contains(reference),
  );
  return (
    body: [
      missing.join('\n'),
      visible,
    ].where((part) => part.isNotEmpty).join('\n\n'),
    filePaths: references.values.toList(growable: false),
  );
}

String _imagePlaceholdersRemoved(String body) {
  const placeholder = '[screenshot]';
  if (!body.endsWith('\n$placeholder')) return body;
  final lines = body.split('\n');
  var end = lines.length;
  while (end > 0 && lines[end - 1] == placeholder) {
    end--;
  }
  final start = end - (lines.length - end);
  if (start < 0 || (start > 0 && lines[start - 1].isNotEmpty)) return body;
  for (var i = start; i < end; i++) {
    if (!lines[i].startsWith('@image:') ||
        standaloneMessageImage(lines[i], user: true) == null) {
      return body;
    }
  }
  return lines.take(end).join('\n');
}

String speechText(String body) {
  final lines = body.split('\n').where((line) {
    final text = line.trimLeft();
    return !text.startsWith('MEDIA:') &&
        !text.startsWith('@image:') &&
        !text.startsWith('@file:') &&
        !text.startsWith('data:') &&
        standaloneMessageImage(text, user: false) == null &&
        messageFileReference(text, user: false) == null;
  });
  return md.Document(extensionSet: md.ExtensionSet.gitHubFlavored)
      .parseLines(lines.toList())
      .map((node) => node.textContent.trim())
      .where((text) => text.isNotEmpty)
      .join('\n');
}

typedef _ImageReference = ({String path, String? alt});
typedef MessageLineAttachment = ({
  String path,
  String? label,
  String? fragment,
  bool image,
  String? caption,
});

final _listMarker = RegExp(r'^ {0,3}([-+*]|[0-9]{1,9}[.)])[ \t]+');
final _listAttachmentLabel = RegExp(r'^([^:：\r\n]{1,120})[:：][ \t]*(.+)$');

String? _imagePath(String source) {
  var text = source.trim();
  if (text.length > 1 &&
      ((text.startsWith('<') && text.endsWith('>')) ||
          ("'\"`".contains(text[0]) && text.endsWith(text[0])))) {
    text = text.substring(1, text.length - 1);
  }
  if (text.startsWith('data:image/')) return text;
  final drive = RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(text);
  final uri = Uri.tryParse(text);
  if (!drive && uri != null && (uri.hasScheme || uri.hasAuthority)) {
    if (uri.scheme != 'file' ||
        uri.host.isNotEmpty && uri.host != 'localhost') {
      return null;
    }
    try {
      text = Uri.decodeComponent(uri.path);
    } on FormatException {
      return null;
    }
    if (RegExp(r'^/[a-zA-Z]:/').hasMatch(text)) text = text.substring(1);
  }
  if (text.contains(RegExp(r'[\x00-\x1f]')) ||
      !RegExp(
        r'\.(png|jpe?g|webp|gif|bmp|tiff?)$',
        caseSensitive: false,
      ).hasMatch(text)) {
    return null;
  }
  return text;
}

({String path, String? alt})? standaloneMessageImage(
  String line, {
  required bool user,
  String? Function(Uri)? resolve,
  Map<String, md.LinkReference> references = const {},
}) {
  if (line.trimLeft() != line) return null;
  final value = line.trimRight();
  final prefixLength = value.startsWith('@image:')
      ? '@image:'.length
      : value.startsWith('MEDIA:')
      ? 'MEDIA:'.length
      : 0;
  final source = prefixLength > 0
      ? value.substring(prefixLength)
      : value.startsWith('data:image/')
      ? value
      : attachedPath(value);
  if (source != null) {
    final path = _imagePath(source);
    return path == null ? null : (path: path, alt: null);
  }
  if (user && value.startsWith('[Image attached at: ') && value.endsWith(']')) {
    final path = _imagePath(
      value.substring('[Image attached at: '.length, value.length - 1),
    );
    return path == null ? null : (path: path, alt: null);
  }
  if (!value.startsWith('![')) {
    if (user) return null;
    final candidate =
        value.startsWith('`') && value.endsWith('`') && value.length > 2
        ? value.substring(1, value.length - 1)
        : value;
    final absolute =
        candidate.startsWith('/') && !candidate.startsWith('//') ||
        candidate.startsWith('file:///') ||
        RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(candidate);
    final path = absolute ? _imagePath(candidate) : null;
    return path == null ? null : (path: path, alt: null);
  }
  final ast = messageMarkdownDocument(references).parseLines([value]);
  if (ast.length != 1 || ast.single is! md.Element) return null;
  final nodes = (ast.single as md.Element).children ?? [];
  if (nodes.length != 1 || nodes.single is! md.Element) return null;
  final node = nodes.single as md.Element;
  if (node.tag != 'img') return null;
  final uri = Uri.tryParse(node.attributes['src'] ?? '');
  final path = uri == null ? null : _imageSource(uri, resolve: resolve);
  return path == null ? null : (path: path, alt: node.attributes['alt']);
}

MessageLineAttachment? messageLineAttachment(
  String line, {
  required bool user,
  String? Function(Uri)? resolve,
  Map<String, md.LinkReference> references = const {},
}) {
  MessageLineAttachment? read(String value, {String? caption, String? title}) {
    final file = messageFileReference(
      value,
      user: user,
      resolve: resolve,
      references: references,
    );
    final image =
        standaloneMessageImage(
          value,
          user: user,
          resolve: resolve,
          references: references,
        ) ??
        _linkedImage(file);
    if (image != null) {
      return (
        path: image.path,
        label: image.alt ?? title,
        fragment: null,
        image: true,
        caption: caption,
      );
    }
    return file == null
        ? null
        : (
            path: file.path,
            label: file.label,
            fragment: file.fragment,
            image: false,
            caption: caption,
          );
  }

  final standalone = read(line);
  if (standalone != null || user) return standalone;
  final bullet = _listMarker.firstMatch(line);
  if (bullet == null) return null;
  final prefix = bullet.group(1)!;
  final value = line.substring(bullet.end);
  final direct = read(value);
  if (direct != null) return direct;
  final named = _listAttachmentLabel.firstMatch(value);
  if (named == null) return null;
  final title = named.group(1)!.trim();
  if (title.isEmpty) return null;
  return read(named.group(2)!, title: title, caption: '$prefix $title');
}

String? toolImagePath(Json? result) {
  if (result == null || result['success'] == false || result['ok'] == false) {
    return null;
  }
  for (final key in ['host_image', 'image']) {
    if (result[key] case final String source) {
      if (_imagePath(source) case final path?) return path;
    }
  }
  return null;
}

final messageFence = RegExp(
  r'^ {0,3}(?:(?:[-+*]|[0-9]{1,9}[.)])[ \t]+)?(`{3,}|~{3,})',
);

String composeAttachedPrompt(
  String caption,
  List<String> files,
  List<String> images,
) {
  if (files.isEmpty && images.isEmpty) return caption;
  final attachments = [...files, ...images].join('\n');
  if (caption.isEmpty) return attachments;

  // Keep the caption first for the gateway's title, unless that would put the
  // attachments inside an unfinished code block.
  final openFence = messageLines(
    caption,
    user: true,
    references: const {},
  ).last.inFence;
  return openFence ? '$attachments\n\n$caption' : '$caption\n\n$attachments';
}

Iterable<GalleryImage> messageGallery(
  String body, {
  required bool user,
  String? Function(Uri)? resolve,
  String? baseDirectory,
}) => messageImageReferences(body, user: user, resolve: resolve).map(
  (source) => GalleryImage.path(
    workspaceFilePath(source.path, baseDirectory),
    alt: source.alt,
  ),
);

Iterable<({String path, String? alt})> messageImageReferences(
  String body, {
  required bool user,
  String? Function(Uri)? resolve,
}) sync* {
  if (!body.contains(
    RegExp(
      r'!\[|@image:|@file:|MEDIA:|data:image/|\.(?:png|jpe?g|webp|gif|bmp|tiff?)',
      caseSensitive: false,
    ),
  )) {
    return;
  }
  final references = user
      ? const <String, md.LinkReference>{}
      : markdownReferenceDefinitions(body);
  final inline = <String>[];
  Iterable<_ImageReference> inlineImages() sync* {
    if (inline.any((line) => line.contains('!['))) {
      final ast = messageMarkdownDocument(references).parseLines(inline);
      yield* ast.expand((node) => _inlineImages(node, resolve: resolve));
    }
    inline.clear();
  }

  for (final line in messageLines(
    body,
    user: user,
    resolve: resolve,
    references: references,
  )) {
    if (line.attachment case final attachment?) {
      yield* inlineImages();
      if (attachment.image) {
        yield (path: attachment.path, alt: attachment.label);
      }
    } else if (!user) {
      inline.add(line.text);
    }
  }
  yield* inlineImages();
}

({int index, MessageLineAttachment attachment})? _listContinuation(
  List<String> lines,
  int index, {
  required String? Function(Uri)? resolve,
  required Map<String, md.LinkReference> references,
}) {
  final heading = lines[index];
  final bullet = _listMarker.firstMatch(heading);
  if (bullet == null || heading.substring(bullet.end).trim().isEmpty) {
    return null;
  }
  var next = index + 1;
  if (next < lines.length && lines[next].trim().isEmpty) next++;
  if (next == lines.length || !lines[next].startsWith(' ' * bullet.end)) {
    return null;
  }
  final indented = lines[next].substring(bullet.end);
  final value = indented.trimLeft();
  final extraIndent = indented.length - value.length;
  if (extraIndent >= 4 ||
      indented.substring(0, extraIndent).contains('\t') ||
      _listMarker.hasMatch(value)) {
    return null;
  }
  final attachment = messageLineAttachment(
    value,
    user: false,
    resolve: resolve,
    references: references,
  );
  if (attachment == null) return null;

  final title = messageMarkdownDocument(references)
      .parseLines([heading.substring(bullet.end)])
      .map((node) => node.textContent)
      .join()
      .trim()
      .replaceFirst(RegExp(r'[:：]$'), '')
      .trimRight();
  return (
    index: next,
    attachment: (
      path: attachment.path,
      label: attachment.label ?? (title.isEmpty ? null : title),
      fragment: attachment.fragment,
      image: attachment.image,
      caption: heading.trimRight(),
    ),
  );
}

Iterable<({String text, MessageLineAttachment? attachment, bool inFence})>
messageLines(
  String body, {
  required bool user,
  bool deferTrailingAttachment = false,
  String? Function(Uri)? resolve,
  required Map<String, md.LinkReference> references,
}) sync* {
  String? fence;
  final lines = body.split('\n');
  final tail = deferTrailingAttachment && lines.last.isNotEmpty
      ? lines.removeLast()
      : null;
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final marker = messageFence.firstMatch(line);
    if (marker != null) {
      final mark = marker[1]!;
      if (fence == null) {
        fence = mark;
      } else if (mark.startsWith(fence) &&
          line.substring(marker.end).trim().isEmpty) {
        fence = null;
      }
      yield (text: line, attachment: null, inFence: fence != null);
      continue;
    }
    if (fence != null) {
      yield (text: line, attachment: null, inFence: true);
      continue;
    }
    final attachment = messageLineAttachment(
      line,
      user: user,
      resolve: resolve,
      references: references,
    );
    if (!user && attachment == null) {
      final continuation = _listContinuation(
        lines,
        index,
        resolve: resolve,
        references: references,
      );
      if (continuation != null) {
        yield (
          text: lines.sublist(index, continuation.index + 1).join('\n'),
          attachment: continuation.attachment,
          inFence: false,
        );
        index = continuation.index;
        continue;
      }
    }
    yield (text: line, attachment: attachment, inFence: false);
  }
  if (tail != null) {
    final directive =
        tail.startsWith('MEDIA:') ||
        tail.startsWith('@image:') ||
        tail.startsWith('@file:') ||
        tail.startsWith('data:image/');
    if (!directive || fence != null) {
      yield (text: tail, attachment: null, inFence: fence != null);
    }
  }
}

_ImageReference? _linkedImage(MessageFileReference? file) {
  if (file == null) return null;
  final path = _imagePath(file.path);
  return path == null ? null : (path: path, alt: file.label);
}

Iterable<_ImageReference> _inlineImages(
  md.Node node, {
  String? Function(Uri)? resolve,
}) sync* {
  if (node is! md.Element || node.tag == 'code' || node.tag == 'pre') return;
  if (node.tag == 'img') {
    final uri = Uri.tryParse(node.attributes['src'] ?? '');
    if (uri != null) {
      if (_imageSource(uri, resolve: resolve) case final path?) {
        yield (path: path, alt: node.attributes['alt']);
      }
    }
  }
  for (final child in node.children ?? const <md.Node>[]) {
    yield* _inlineImages(child, resolve: resolve);
  }
}

String? _imageSource(Uri uri, {String? Function(Uri)? resolve}) {
  try {
    return switch (uri) {
      Uri(scheme: 'data') when uri.toString().startsWith('data:image/') =>
        uri.toString(),
      Uri(scheme: 'file') => _imagePath(uri.toString()),
      Uri(hasScheme: false, hasAuthority: false) =>
        resolve?.call(uri) ?? _imagePath(Uri.decodeComponent(uri.path)),
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

class MessageContent extends StatelessWidget {
  const MessageContent({
    super.key,
    required this.body,
    this.user = false,
    this.streaming = false,
    required this.gateway,
    required this.profile,
    required this.session,
    this.documentPath,
    this.baseDirectory,
    this.onOpenDocument,
    this.scrollDocument = false,
    this.initialFragment,
    this.documentOutline,
    this.gallery,
  });
  final bool user, streaming, scrollDocument;
  final String body, profile;
  final String? session;
  final Gateway gateway;
  final String? Function(Uri uri)? documentPath;
  final String? baseDirectory;
  final void Function(String path, String? fragment)? onOpenDocument;
  final String? initialFragment;
  final DocumentOutline? documentOutline;
  final Iterable<GalleryImage> Function()? gallery;

  Iterable<GalleryImage> images() =>
      gallery?.call() ??
      messageGallery(
        body,
        user: user,
        resolve: documentPath,
        baseDirectory: baseDirectory,
      );
  @override
  Widget build(BuildContext context) {
    final seenImages = <String>{};
    final seenFiles = <(String, String?)>{};
    final widgets = <Widget>[], lines = <String>[];
    final colors = Theme.of(context).colorScheme;
    final bodyStyle = TextStyle(
      fontSize: 16,
      height: 1.52,
      color: user ? colors.onSecondaryContainer : colors.onSurface,
    );
    final anchors = scrollDocument
        ? documentOutline ?? DocumentOutline()
        : null;
    final references = !user && !scrollDocument
        ? markdownReferenceDefinitions(body)
        : const <String, md.LinkReference>{};
    final referenceVersion = Object.hashAll(
      references.values.map(
        (ref) => Object.hash(ref.label, ref.destination, ref.title),
      ),
    );
    Future<void> followLocal(String? path, String? fragment) async {
      if (path != null) {
        onOpenDocument?.call(path, fragment);
      } else if (fragment != null) {
        await anchors?.jump(fragment);
      }
    }

    Future<void> followLink(String text, String? href, String title) async {
      final uri = Uri.tryParse(href ?? '');
      if (uri == null) return;
      final fragment = workspaceDocumentFragment(uri);
      if ({'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else if (!uri.hasScheme &&
          !uri.hasAuthority &&
          uri.path.isEmpty &&
          fragment != null) {
        await followLocal(null, fragment);
      } else if (documentPath?.call(uri) case final path?) {
        await followLocal(path, fragment);
      }
    }

    Widget renderMarkdown(
      String text, {
      bool document = false,
      bool codeSample = false,
    }) {
      final builders = <String, MarkdownElementBuilder>{
        if (document)
          for (var level = 1; level <= 6; level++)
            'h$level': _HeadingMarker(anchors!, followLink, level),
        'pre': MarkdownCodeBuilder(
          (source) => renderMarkdown(source, codeSample: true),
          streaming: streaming,
        ),
      };
      final style = MarkdownStyleSheet(
        p: bodyStyle,
        h1: bodyStyle.copyWith(fontSize: 24, fontWeight: FontWeight.w700),
        h2: bodyStyle.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
        h3: bodyStyle.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
        a: bodyStyle.copyWith(
          color:
              CustomThemeTokens.read(context, ThemeColor.link) ??
              colors.primary,
          decoration: TextDecoration.underline,
        ),
        code: CustomThemeTokens.codeStyle(context).copyWith(
          fontSize: 13,
          color: colors.onSurface,
          backgroundColor: colors.surfaceContainerHighest,
        ),
        codeblockDecoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        tableColumnWidth: const ReadableTableColumnWidth(),
        tableScrollbarThumbVisibility: true,
        blockquoteDecoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(
            left: BorderSide(width: 3, color: colors.outlineVariant),
          ),
        ),
        blockquotePadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        tableBorder: TableBorder.all(color: colors.outlineVariant),
        tableHead: bodyStyle.copyWith(fontWeight: FontWeight.w600),
        tableBody: bodyStyle,
        tableCellsPadding: const EdgeInsets.all(8),
      );
      Widget buildImage(Uri uri, String? title, String? alt) {
        final source = _imageSource(uri, resolve: documentPath);
        if (source != null) {
          final path = workspaceFilePath(source, baseDirectory);
          return ChatImage(
            path: path,
            alt: alt,
            gallery: scrollDocument ? null : images,
            gateway: gateway,
            profile: profile,
            session: session,
          );
        }
        return Text(
          alt?.isNotEmpty == true ? alt! : context.tr('图片'),
          style: TextStyle(color: colors.onSurfaceVariant),
        );
      }

      if (document) {
        final links = anchors!.linksFor(
          text,
          onOpenDocument == null ? null : documentPath,
        );
        return _DocumentMarkdown(
          data: text,
          builders: builders,
          inlineSyntaxes: messageMarkdownInlineSyntaxes,
          extensionSet: md.ExtensionSet.gitHubWeb,
          softLineBreak: true,
          styleSheet: style,
          onTapLink: followLink,
          imageBuilder: buildImage,
          footer: links.isEmpty
              ? null
              : _DocumentLinksFooter(
                  links: links,
                  onTap: (link) => followLocal(link.path, link.fragment),
                ),
        );
      }
      final seedReferences = !codeSample && references.isNotEmpty;
      return MarkdownBody(
        key: seedReferences
            ? ValueKey((widgets.length, referenceVersion))
            : null,
        data: seedReferences ? '\n$text' : text,
        blockSyntaxes: seedReferences
            ? [MessageReferenceSyntax(references)]
            : null,
        selectable: true,
        builders: builders,
        inlineSyntaxes: messageMarkdownInlineSyntaxes,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        softLineBreak: true,
        styleSheet: style,
        onTapLink: followLink,
        imageBuilder: buildImage,
      );
    }

    if (scrollDocument) {
      if (initialFragment case final fragment? when fragment.isNotEmpty) {
        anchors!.openFragment(fragment);
      }
      final document = renderMarkdown(body, document: true);
      return documentOutline == null
          ? document
          : KeyedSubtree(key: PageStorageKey(documentOutline), child: document);
    }
    void flush() {
      if (lines.isEmpty) return;
      final paragraph = lines.join('\n');
      widgets.add(
        user
            ? SelectableText(paragraph, style: bodyStyle)
            : renderMarkdown(paragraph),
      );
      lines.clear();
    }

    var inFence = false;
    for (final line in messageLines(
      body,
      user: user,
      deferTrailingAttachment: streaming,
      resolve: documentPath,
      references: references,
    )) {
      inFence = line.inFence;
      final attachment = line.attachment;
      if (attachment == null) {
        lines.add(line.text);
        continue;
      }
      final path = workspaceFilePath(attachment.path, baseDirectory);
      final first = attachment.image
          ? seenImages.add(path)
          : seenFiles.add((path, attachment.fragment));
      if (attachment.caption case final caption?) {
        flush();
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: renderMarkdown(caption),
          ),
        );
      }
      if (!first) continue;
      if (attachment.image) {
        flush();
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ChatImage(
              key: ValueKey('$session:$path'),
              path: path,
              alt: attachment.label,
              gallery: images,
              gateway: gateway,
              profile: profile,
              session: session,
            ),
          ),
        );
      } else {
        flush();
        final open = onOpenDocument;
        widgets.add(
          RemoteFileTile(
            key: ValueKey((path, attachment.fragment)),
            gateway: gateway,
            sessionId: session,
            profile: profile,
            path: path,
            label: attachment.label,
            onOpen: open == null ? null : () => open(path, attachment.fragment),
          ),
        );
      }
    }
    if (user && seenImages.isNotEmpty && !inFence) {
      while (lines.isNotEmpty &&
          {'[screenshot]', '[image]', '[图片]', ''}.contains(lines.last.trim())) {
        lines.removeLast();
      }
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }
}

class _DocumentMarkdown extends MarkdownWidget {
  const _DocumentMarkdown({
    required super.data,
    super.builders,
    super.inlineSyntaxes,
    super.extensionSet,
    super.softLineBreak,
    super.styleSheet,
    super.onTapLink,
    super.imageBuilder,
    this.footer,
  });
  final Widget? footer;

  @override
  Widget build(BuildContext context, List<Widget>? children) =>
      SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [...?children, ?footer],
        ),
      );
}

class _DocumentLinksFooter extends StatelessWidget {
  const _DocumentLinksFooter({required this.links, required this.onTap});

  final List<DocumentLink> links;
  final ValueChanged<DocumentLink> onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Semantics(
            header: true,
            child: Text(
              context.tr('文档链接'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final link in links)
              ActionChip(
                avatar: Icon(switch (link.path) {
                  null => Icons.tag_rounded,
                  final path when path.endsWith('/') || path.endsWith('\\') =>
                    Icons.folder_open_outlined,
                  _ => Icons.insert_drive_file_outlined,
                }, size: 16),
                label: Text(
                  link.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () => onTap(link),
              ),
          ],
        ),
      ],
    ),
  );
}

class _HeadingMarker extends MarkdownElementBuilder {
  _HeadingMarker(this.outline, this.follow, this.level);
  final DocumentOutline outline;
  final MarkdownTapLinkCallback follow;
  final int level;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final parsed = element.children;
    if (parsed == null || parsed.isEmpty) return null;
    final children = [...parsed];
    String? explicit;
    if (children.last case final md.Text tail) {
      final marker = RegExp(r'\s*\{#([^\s{}]+)\}\s*$').firstMatch(tail.text);
      if (marker != null) {
        explicit = marker[1];
        final before = tail.text.substring(0, marker.start).trimRight();
        children.removeLast();
        if (before.isNotEmpty) children.add(md.Text(before));
      }
    }
    final title = children.map((node) => node.textContent).join().trim();
    final content = MarkdownBody(
      data: children.map(_inline).join(),
      inlineSyntaxes: messageMarkdownInlineSyntaxes,
      styleSheet: MarkdownStyleSheet(p: preferredStyle),
      onTapLink: follow,
    );
    return title.isEmpty
        ? content
        : DocumentHeadingAnchor(
            outline: outline,
            explicitId: explicit,
            title: title,
            level: level,
            child: content,
          );
  }

  String _inline(md.Node node) {
    if (node is! md.Element) {
      return node.textContent.replaceAllMapped(
        RegExp(r'[\\`*_~\[\]<>#]'),
        (match) => r'\' + match[0]!,
      );
    }
    final contents = node.children?.map(_inline).join() ?? '';
    switch (node.tag) {
      case 'strong':
        return '**$contents**';
      case 'em':
        return '*$contents*';
      case 'del':
        return '~~$contents~~';
      case 'code':
        final inner = node.textContent;
        var marker = '`';
        while (inner.contains(marker)) {
          marker += '`';
        }
        return '$marker $inner $marker';
      case 'a':
        return '[$contents](<${node.attributes['href'] ?? ''}>)';
      default:
        return contents;
    }
  }
}

class ChatImage extends StatefulWidget {
  const ChatImage({
    super.key,
    required this.path,
    required this.gateway,
    required this.profile,
    required this.session,
    this.alt,
    this.gallery,
  });
  final String path, profile;
  final String? session, alt;
  final Gateway gateway;
  final Iterable<GalleryImage> Function()? gallery;
  @override
  State<ChatImage> createState() => _ChatImageState();
}

enum _ImageAction { view, save, share }

class _ChatImageState extends State<ChatImage> {
  FileTransferControl? _preview;
  late Future<LoadedGalleryImage> image = load();
  bool exporting = false;

  WorkspaceScope get scope =>
      WorkspaceScope(widget.gateway, widget.profile, session: widget.session);
  GalleryImage get source => GalleryImage.path(widget.path, alt: widget.alt);

  @override
  void didUpdateWidget(covariant ChatImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.gateway != widget.gateway ||
        oldWidget.profile != widget.profile ||
        oldWidget.session != widget.session) {
      image = load();
    }
  }

  @override
  void dispose() {
    _preview?.cancel();
    super.dispose();
  }

  Future<LoadedGalleryImage> load() {
    _preview?.cancel();
    final control = _preview = FileTransferControl();
    return loadGalleryImage(scope, source, control: control);
  }

  Future<void> openOriginal([LoadedGalleryImage? preview]) => openImageGallery(
    context,
    scope: scope,
    images: widget.gallery?.call() ?? [source],
    selected: source,
    initialPreview: preview,
  );

  bool canExport(LoadedGalleryImage? preview) =>
      preview != null || !widget.path.startsWith('data:');

  Future<void> exportOriginal(
    LoadedGalleryImage? preview, {
    Rect? shareOrigin,
  }) async {
    if (exporting || !canExport(preview)) return;
    setState(() => exporting = true);
    try {
      await exportRemoteGalleryImage(
        context,
        scope,
        path: preview?.path ?? widget.path,
        preview: preview,
        shareOrigin: shareOrigin,
        stillOpen: () => mounted,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr(error.toString()))));
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> showImageActions(LoadedGalleryImage preview) async {
    if (exporting) return;
    final origin = fileShareOrigin(context);
    final action = await showModalBottomSheet<_ImageAction>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.open_in_full_rounded),
                title: Text(sheet.tr('查看原图')),
                onTap: () => Navigator.pop(sheet, _ImageAction.view),
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: Text(sheet.tr('保存原图')),
                onTap: () => Navigator.pop(sheet, _ImageAction.save),
              ),
              ListTile(
                leading: const Icon(Icons.ios_share_outlined),
                title: Text(sheet.tr('分享原图')),
                onTap: () => Navigator.pop(sheet, _ImageAction.share),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == _ImageAction.view) {
      await openOriginal(preview);
    } else {
      await exportOriginal(
        preview,
        shareOrigin: action == _ImageAction.share ? origin : null,
      );
    }
  }

  Widget unavailable(Object? failure) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 9, 10, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.tr(imagePreviewError(failure)),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            Wrap(
              spacing: 6,
              children: [
                TextButton.icon(
                  onPressed: openOriginal,
                  icon: const Icon(Icons.open_in_full_rounded, size: 17),
                  label: Text(context.tr('查看原图')),
                ),
                if (canExport(null))
                  TextButton.icon(
                    onPressed: exporting ? null : () => exportOriginal(null),
                    icon: const Icon(Icons.download_outlined, size: 17),
                    label: Text(context.tr('保存原图')),
                  ),
                TextButton.icon(
                  onPressed: () => setState(() {
                    image = load();
                  }),
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: Text(context.tr('重新加载图片')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: image,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      final data = snapshot.data;
      if (data == null) return unavailable(snapshot.error);
      final label = widget.alt?.isNotEmpty == true
          ? context.strings.format('查看原图 · {alt}', {'alt': widget.alt!})
          : context.tr('查看原图');
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          return Image.memory(
            data.bytes,
            excludeFromSemantics: true,
            cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(1, 3072),
            fit: BoxFit.contain,
            frameBuilder: (_, child, frame, _) =>
                frame == null ? child : imageFrame(child, data, label),
            errorBuilder: (_, failure, _) => unavailable(failure),
          );
        },
      );
    },
  );

  Widget imageFrame(Widget child, LoadedGalleryImage data, String label) {
    final colors = Theme.of(context).colorScheme;
    void actions() => showImageActions(data);
    void open() => openOriginal(data);
    return Stack(
      children: [
        Semantics(
          container: true,
          button: true,
          label: label,
          onTap: open,
          onLongPress: actions,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: open,
            onLongPress: actions,
            onSecondaryTap: actions,
            child: child,
          ),
        ),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, size) {
              if (size.maxWidth < 116 || size.maxHeight < 92) {
                return const SizedBox.shrink();
              }
              return Align(
                alignment: AlignmentDirectional.topEnd,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton.filledTonal(
                    tooltip: context.tr('保存原图'),
                    style: IconButton.styleFrom(
                      backgroundColor: colors.surface.withValues(alpha: .92),
                      foregroundColor: colors.onSurface,
                    ),
                    onPressed: exporting ? null : () => exportOriginal(data),
                    icon: exporting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined, size: 19),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
