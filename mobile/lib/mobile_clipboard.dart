import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        MethodChannel,
        MissingPluginException,
        PlatformException;
import 'package:material_ui/material_ui.dart';

import 'gateway.dart';
import 'image_format.dart';
import 'mobile_locale.dart';

const _clipboardImages = MethodChannel('hermes_lite/image_clipboard');

Future<List<XFile>> readClipboardImages(Directory directory, int limit) async {
  final List<String> names;
  try {
    names =
        await _clipboardImages.invokeListMethod<String>('readImages', {
          'directory': directory.path,
          'limit': limit,
        }) ??
        const [];
  } on MissingPluginException {
    return const [];
  } on PlatformException catch (error) {
    throw GatewayError(
      error.code == 'too_many_images' ? '一次最多发送 10 张图片' : '无法读取剪贴板图片',
    );
  }
  final pattern = RegExp(r'^clipboard-[0-9]+$');
  if (names.any((name) => !pattern.hasMatch(name))) {
    throw GatewayError('无法读取剪贴板图片');
  }
  return [
    for (final name in names)
      await preparePastedImage(File('${directory.path}/$name'), name),
  ];
}

Future<XFile> preparePastedImage(File file, String name) async {
  final header = await file.open();
  final String mime;
  try {
    mime = imageMime(await header.read(12));
  } on GatewayError {
    return _convertToPng(file, name);
  } finally {
    await header.close();
  }
  final extension = mime == 'image/jpeg' ? 'jpg' : mime.substring(6);
  final original = await file.rename('${file.parent.path}/$name.$extension');
  return XFile(original.path, mimeType: mime);
}

Future<XFile> _convertToPng(File file, String name) async {
  try {
    final codec = await ui.instantiateImageCodec(await file.readAsBytes());
    try {
      final frame = await codec.getNextFrame();
      try {
        final bytes = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (bytes == null) throw GatewayError('无法读取剪贴板图片');
        final png = File('${file.path}.png');
        await png.writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
        return XFile(png.path, name: '$name.png', mimeType: 'image/png');
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    throw GatewayError('无法读取剪贴板图片');
  }
}

Future<void> copyMobileText(
  BuildContext context,
  String value,
  String feedback,
) async {
  final copied = await writeMobileText(value);
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(content: Text(context.tr(copied ? feedback : '无法复制到剪贴板'))),
  );
}

Future<bool> writeMobileText(String value) async {
  try {
    await Clipboard.setData(ClipboardData(text: value));
    return true;
  } on PlatformException {
    return false;
  }
}
