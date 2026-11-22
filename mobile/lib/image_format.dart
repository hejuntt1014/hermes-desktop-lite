import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import 'gateway.dart';

String? detectImageMime(List<int> bytes) {
  if (bytes.length >= 12) {
    if (bytes[0] == 0xff && bytes[1] == 0xd8) return 'image/jpeg';
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return 'image/png';
    }
    final signature = ascii.decode(bytes.sublist(0, 6), allowInvalid: true);
    if (signature == 'GIF87a' || signature == 'GIF89a') {
      return 'image/gif';
    }
    if (ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }
  }
  return null;
}

String imageMime(Uint8List bytes) =>
    detectImageMime(bytes) ??
    (throw GatewayError('请选择 PNG、JPEG、WebP 或 GIF 图片'));

Future<Uint8List> decodeInlineImage(String value) async =>
    value.length >= 256 * 1024
    ? compute(_decodeInlineImage, value)
    : _decodeInlineImage(value);

Uint8List _decodeInlineImage(String value) =>
    UriData.parse(value).contentAsBytes();