import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:file_selector/file_selector.dart' show XFile;

class ComposerFileDrop {
  ComposerFileDrop({
    required this.onChanged,
    required this.onFiles,
    required this.onFailure,
  }) {
    if (!supported) return;
    if (_targets.isEmpty) _channel.setMethodCallHandler(_receive);
    _targets[_id] = this;
  }

  static bool get supported => Platform.isAndroid || Platform.isIOS;
  static const _channel = MethodChannel('hermes_lite/file_drop');
  static final _targets = <int, ComposerFileDrop>{};
  static int _nextId = 0;

  final VoidCallback onChanged, onFailure;
  final Future<void> Function(List<XFile>) onFiles;
  final key = GlobalKey();
  final int _id = ++_nextId;
  Rect? _published;
  bool _enabled = false, _scheduled = false, _disposed = false;
  bool hovering = false, receiving = false;

  void update(bool enabled) {
    if (!supported) return;
    _enabled = enabled;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed) return;
      final render = key.currentContext?.findRenderObject();
      final bounds = _enabled && render is RenderBox && render.hasSize
          ? render.localToGlobal(Offset.zero) & render.size
          : null;
      if (bounds == _published) return;
      _published = bounds;
      unawaited(_publish(bounds));
    });
  }

  Future<void> _publish(Rect? bounds) async {
    try {
      await _channel.invokeMethod<void>('target', {
        'id': _id,
        if (bounds != null) ...{
          'left': bounds.left,
          'top': bounds.top,
          'right': bounds.right,
          'bottom': bounds.bottom,
        },
      });
    } on MissingPluginException {
      // Flutter desktop tools do not register the mobile receiver.
    } on PlatformException {
      // File selection is still available if the native view is detached.
    }
  }

  static Future<void> _receive(MethodCall call) async {
    final args = call.arguments as Map<Object?, Object?>;
    final target = _targets[args['id']];
    if (target == null) return;
    switch (call.method) {
      case 'hover':
        target.hovering = args['on'] == true;
        target.onChanged();
      case 'reading':
        target.receiving = true;
        target.onChanged();
      case 'files':
      case 'failed':
        try {
          if (call.method == 'failed') {
            target.onFailure();
          } else {
            final files = (args['paths'] as List).whereType<String>();
            await target.onFiles(files.map(XFile.new).toList());
          }
        } finally {
          if (!target._disposed) {
            target.receiving = false;
            target.onChanged();
          }
        }
    }
  }

  void dispose() {
    _disposed = true;
    if (!supported) return;
    if (_published != null) unawaited(_publish(null));
    _targets.remove(_id);
  }
}
