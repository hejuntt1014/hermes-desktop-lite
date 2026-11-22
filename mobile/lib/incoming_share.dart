import 'dart:io';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';

typedef SharedContent = ({String id, String text, int fileCount});

class IncomingShares extends ChangeNotifier {
  IncomingShares._() {
    if (supported) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'changed') notifyListeners();
      });
    }
  }

  static bool get supported => Platform.isAndroid || Platform.isIOS;
  static final shared = IncomingShares._();
  static const _channel = MethodChannel('hermes_lite/incoming_share');

  Future<SharedContent?> peek() async {
    final item = await _channel.invokeMapMethod<String, Object?>('peek');
    if (item == null) return null;
    return (
      id: item['id'] as String,
      text: item['text'] as String,
      fileCount: item['files'] as int,
    );
  }

  Future<List<XFile>> copy(SharedContent item) async {
    final paths = await _channel.invokeListMethod<String>('copy', {
      'id': item.id,
    });
    return (paths ?? const <String>[]).map(XFile.new).toList();
  }

  Future<void> finish(SharedContent item, {required bool consumed}) => _channel
      .invokeMethod<void>('finish', {'id': item.id, 'consumed': consumed});
}

Future<void> reviewIncomingShare(
  BuildContext context,
  SharedContent item, {
  required Future<void> Function() onAccept,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  isDismissible: false,
  enableDrag: false,
  builder: (_) => _SharedContentSheet(item: item, onAccept: onAccept),
);

class _SharedContentSheet extends StatefulWidget {
  const _SharedContentSheet({required this.item, required this.onAccept});
  final SharedContent item;
  final Future<void> Function() onAccept;

  @override
  State<_SharedContentSheet> createState() => _SharedContentSheetState();
}

class _SharedContentSheetState extends State<_SharedContentSheet> {
  bool importing = false, failed = false;

  Future<void> accept() async {
    setState(() {
      importing = true;
      failed = false;
    });
    try {
      await widget.onAccept();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          importing = false;
          failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    return PopScope(
      canPop: !importing,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.tr('共享内容'), style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              if (item.text.trim().isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    primary: false,
                    child: SelectableText(item.text),
                  ),
                ),
              if (item.fileCount > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    context.strings.format('共享附件 · {count} 个', {
                      'count': item.fileCount,
                    }),
                  ),
                ),
              if (failed)
                Text(
                  context.tr('无法导入共享内容'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: importing ? null : accept,
                icon: importing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.note_add_outlined),
                label: Text(context.tr(importing ? '正在导入…' : '添加到新草稿')),
              ),
              TextButton(
                onPressed: importing ? null : () => Navigator.pop(context),
                child: Text(context.tr('取消')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
