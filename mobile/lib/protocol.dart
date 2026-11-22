import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

@Native<Pointer<Utf8> Function(Bool, Bool, Bool, Pointer<Utf8>)>(
  symbol: 'hermes_session_params',
)
external Pointer<Utf8> _params(
  bool create,
  bool canonical,
  bool paged,
  Pointer<Utf8> key,
);

@Native<Void Function(Pointer<Utf8>)>(symbol: 'hermes_free')
external void _free(Pointer<Utf8> value);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Uint32)>(
  symbol: 'hermes_workbook_sheet',
)
external Pointer<Utf8> _workbook(Pointer<Utf8> path, int sheet);

Map<String, dynamic> workbookSheet(String path, int sheet) {
  final input = path.toNativeUtf8();
  try {
    final output = _workbook(input, sheet);
    if (output == nullptr) throw const FormatException('Cannot open workbook');
    try {
      return jsonDecode(output.toDartString()) as Map<String, dynamic>;
    } finally {
      _free(output);
    }
  } finally {
    malloc.free(input);
  }
}

Map<String, dynamic> sessionParams({
  required bool create,
  required bool canonical,
  required String key,
  bool paged = false,
}) {
  final input = key.toNativeUtf8();
  try {
    final output = _params(create, canonical, paged, input);
    if (output == nullptr) throw const FormatException('Invalid session ID');
    try {
      return jsonDecode(output.toDartString()) as Map<String, dynamic>;
    } finally {
      _free(output);
    }
  } finally {
    malloc.free(input);
  }
}

@Native<Int32 Function(Bool, Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'hermes_theme_archive',
)
external int _themeArchive(
  bool pack,
  Pointer<Utf8> archive,
  Pointer<Utf8> directory,
);

int themeArchive(String archive, String directory, {required bool pack}) {
  final input = archive.toNativeUtf8();
  final scratch = directory.toNativeUtf8();
  try {
    return _themeArchive(pack, input, scratch);
  } finally {
    malloc.free(scratch);
    malloc.free(input);
  }
}
