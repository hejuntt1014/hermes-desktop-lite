import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel, PlatformException;

import 'package:material_ui/material_ui.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:share_plus/share_plus.dart';

import 'mobile_locale.dart';
import 'gateway.dart';
import 'image_format.dart';
import 'workspace.dart';
import 'file_transfer_dialog.dart';
import 'markdown_blocks.dart';

String? attachedPath(String line) {
  if (!line.startsWith('@file:')) return null;
  var path = line.substring('@file:'.length);
  if (path.isEmpty) return null;
  const delimiters = ['`', "'", '"'];
  if (delimiters.contains(path[0])) {
    if (path.length < 3 || !path.endsWith(path[0])) return null;
    path = path.substring(1, path.length - 1);
  } else if (RegExp(r'\s').hasMatch(path)) {
    return null;
  }
  if (path == '.' ||
      path == '..' ||
      path.endsWith('/') ||
      path.endsWith('\\') ||
      path.contains('\x00')) {
    return null;
  }
  return path;
}

typedef MessageFileReference = ({String path, String? label, String? fragment});

final _windowsDrive = RegExp(r'^[a-zA-Z]:[/\\]');
final _localFile = RegExp(r'^(?:/|~/|\.{1,2}/|[a-zA-Z]:[/\\])');
final _fileExtension = RegExp(r'\.[a-zA-Z0-9_-]{1,16}$');

MessageFileReference? messageFileReference(
  String line, {
  required bool user,
  String? Function(Uri)? resolve,
  Map<String, md.LinkReference> references = const {},
}) {
  if (line.trimLeft() != line) return null;
  final value = line.trimRight();
  if (attachedPath(value) case final path?) {
    return _fileReference(path, explicit: true, allowExtensionless: true);
  }
  if (user) return null;
  if (value.startsWith('MEDIA:')) {
    return _fileReference(value.substring(6), explicit: true);
  }
  if (!value.startsWith('[')) return _fileReference(value);
  final parsed = messageMarkdownDocument(references).parseLines([value]);
  if (parsed.length != 1 || parsed.single is! md.Element) return null;
  final children = (parsed.single as md.Element).children;
  if (children?.length != 1 || children!.single is! md.Element) return null;
  final link = children.single as md.Element;
  if (link.tag != 'a') return null;
  final href = link.attributes['href'];
  if (href == null) return null;
  final uri = Uri.tryParse(href);
  if (uri == null) return null;
  try {
    final path = _windowsDrive.hasMatch(href)
        ? Uri.decodeComponent(href.split('#').first.split('?').first)
        : resolve?.call(uri) ?? workspaceDocumentPath(uri);
    return path == null
        ? null
        : _fileReference(
            path,
            explicit: true,
            label: link.textContent,
            fragment: workspaceDocumentFragment(uri),
          );
  } on FormatException {
    return null;
  }
}

MessageFileReference? _fileReference(
  String source, {
  bool explicit = false,
  bool allowExtensionless = false,
  String? label,
  String? fragment,
}) {
  var path = source.trim();
  if (path.length > 2 &&
      (path.startsWith('<') && path.endsWith('>') ||
          "'\"`".contains(path[0]) && path.endsWith(path[0]))) {
    path = path.substring(1, path.length - 1);
  }
  if (path.startsWith('file://')) {
    final uri = Uri.tryParse(path);
    if (uri == null) return null;
    try {
      final local = workspaceDocumentPath(uri);
      if (local == null) return null;
      path = local;
    } on FormatException {
      return null;
    }
  }
  if (path.isEmpty ||
      path.length > 4096 ||
      path.startsWith('//') ||
      path.endsWith('/') ||
      path.endsWith('\\') ||
      RegExp(r'[\x00-\x1f]').hasMatch(path) ||
      path.contains(':') && !_windowsDrive.hasMatch(path) ||
      (!explicit && !_localFile.hasMatch(path)) ||
      !allowExtensionless && !_fileExtension.hasMatch(workspaceName(path))) {
    return null;
  }
  final title = label?.trim();
  return (
    path: path,
    label: title?.isEmpty == true ? null : title,
    fragment: fragment,
  );
}

const _fileExport = MethodChannel('hermes_lite/file_export');

Rect fileShareOrigin(BuildContext context) {
  final box = context.findRenderObject();
  if (box is RenderBox && box.attached && box.hasSize && !box.size.isEmpty) {
    return box.localToGlobal(Offset.zero) & box.size;
  }
  final center = MediaQuery.sizeOf(context).center(Offset.zero);
  return Rect.fromCenter(center: center, width: 1, height: 1);
}

Future<bool> saveRemoteFile(
  BuildContext context,
  Gateway gateway, {
  required String path,
  required String profile,
  required bool Function() stillOpen,
  String? session,
  Uint8List? original,
}) => _stageRemoteFile(
  context,
  gateway,
  path: path,
  profile: profile,
  session: session,
  original: original,
  consume: (file) async => stillOpen() && await saveLocalFile(file),
);

Future<bool> saveLocalFile(File file) async {
  try {
    return await _fileExport.invokeMethod<bool>('save', {'file': file.path}) ==
        true;
  } on PlatformException catch (error) {
    throw GatewayError(switch (error.code) {
      'export_in_progress' => '已有一个文件正在保存',
      'picker_unavailable' => '系统文件选择器不可用',
      _ => '无法保存文件',
    });
  }
}

Future<bool> _shareLocalFile(File file, Rect origin) async {
  final result = await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path)], sharePositionOrigin: origin),
  );
  return result.status == ShareResultStatus.success;
}

String _safeExportName(String name, String fallback) {
  final safe = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
  return safe.isEmpty || safe == '.' || safe == '..' ? fallback : safe;
}

Future<bool> exportLocalAttachment(
  XFile source, {
  required String fallbackName,
  required bool Function() stillOpen,
  Rect? shareOrigin,
}) async {
  final name = _safeExportName(attachmentName(source), fallbackName);
  // Drafts use generated storage names. Export from a copy named for the user.
  final directory = await Directory.systemTemp.createTemp('hermes-export-');
  try {
    final file = File('${directory.path}/$name');
    await source.saveTo(file.path);
    if (!stillOpen()) return false;
    return shareOrigin == null
        ? await saveLocalFile(file)
        : await _shareLocalFile(file, shareOrigin);
  } finally {
    await directory.delete(recursive: true);
  }
}

Future<void> shareRemoteFile(
  BuildContext context,
  Gateway gateway, {
  required String path,
  required String profile,
  required Rect origin,
  required bool Function() stillOpen,
  String? session,
  Uint8List? original,
}) async {
  await _stageRemoteFile(
    context,
    gateway,
    path: path,
    profile: profile,
    session: session,
    original: original,
    consume: (file) async => stillOpen() && await _shareLocalFile(file, origin),
  );
}

Future<bool> _stageRemoteFile(
  BuildContext context,
  Gateway gateway, {
  required String path,
  required String profile,
  required Future<bool> Function(File) consume,
  String? session,
  Uint8List? original,
}) async {
  final strings = context.strings;
  final directory = await Directory.systemTemp.createTemp('hermes-download-');
  try {
    final inline = path.startsWith('data:image/');
    final comma = inline ? path.indexOf(',') : -1;
    final data = inline
        ? UriData.parse(comma >= 0 ? path.substring(0, comma + 1) : path)
        : null;
    final extension = switch (data?.mimeType) {
      null => null,
      'image/jpeg' => 'jpg',
      'image/svg+xml' => 'svg',
      final mime => mime.split('/').last,
    };
    final name = extension == null
        ? path.split(RegExp(r'[/\\]')).last
        : '${strings.text('图片')}.$extension';
    final filename = _safeExportName(name, strings.text('附件'));
    final destination = File('${directory.path}/$filename');
    final bytes = original ?? (inline ? await decodeInlineImage(path) : null);
    if (bytes != null) {
      await destination.writeAsBytes(bytes);
    } else {
      if (!context.mounted) return false;
      final ready = await downloadWithProgress(
        context,
        gateway,
        path: path,
        destination: destination,
        name: filename,
        session: session,
        profile: profile,
      );
      if (!ready) return false;
    }
    return await consume(destination);
  } finally {
    await directory.delete(recursive: true);
  }
}

class RemoteFileTile extends StatefulWidget {
  const RemoteFileTile({
    super.key,
    required this.gateway,
    required this.sessionId,
    required this.profile,
    required this.path,
    this.label,
    this.onOpen,
  });
  final Gateway gateway;
  final String? sessionId, label;
  final String profile, path;
  final VoidCallback? onOpen;

  @override
  State<RemoteFileTile> createState() => _RemoteFileTileState();
}

class _RemoteFileTileState extends State<RemoteFileTile> {
  bool saving = false;
  String get fileName => workspaceName(widget.path);

  Future<void> save({bool share = false}) async {
    if (saving) return;
    final origin = fileShareOrigin(context);
    setState(() => saving = true);
    try {
      if (share) {
        await shareRemoteFile(
          context,
          widget.gateway,
          path: widget.path,
          session: widget.sessionId,
          profile: widget.profile,
          origin: origin,
          stillOpen: () => mounted,
        );
      } else {
        final saved = await saveRemoteFile(
          context,
          widget.gateway,
          path: widget.path,
          session: widget.sessionId,
          profile: widget.profile,
          stillOpen: () => mounted,
        );
        if (saved && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(context.tr('文件已保存'))));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr(e.toString()))));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: ListTile(
          minTileHeight: 52,
          contentPadding: const EdgeInsetsDirectional.only(start: 12, end: 2),
          leading: Icon(
            Icons.insert_drive_file_outlined,
            size: 20,
            color: colors.onSurfaceVariant,
          ),
          title: Text(
            widget.label ?? fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: widget.label == null || widget.label == fileName
              ? null
              : Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: saving
              ? const SizedBox.square(
                  dimension: 40,
                  child: Center(
                    child: SizedBox.square(
                      dimension: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: context.tr('下载附件'),
                      onPressed: save,
                      icon: const Icon(Icons.download_outlined, size: 19),
                    ),
                    PopupMenuButton<bool>(
                      tooltip: context.tr('附件操作'),
                      icon: const Icon(Icons.more_horiz_rounded, size: 18),
                      onSelected: (_) => save(share: true),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: true,
                          child: Text(context.tr('分享文件')),
                        ),
                      ],
                    ),
                  ],
                ),
          onTap: saving ? null : widget.onOpen ?? save,
        ),
      ),
    );
  }
}
