import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'gateway.dart';
import 'mobile_locale.dart';

typedef _DownloadOutcome = ({bool complete, Object? error});

class FileTransferDialogCompletion<T extends Object> {
  FileTransferDialogCompletion(this.context, {required this.cancelled}) {
    _lifecycle = AppLifecycleListener(onResume: _deliver);
  }

  final BuildContext context;
  final T cancelled;
  late final AppLifecycleListener _lifecycle;
  T? _result;
  bool _waitForForeground = false;

  void complete(T result, {bool waitForForeground = false}) {
    _result = result;
    _waitForForeground = waitForForeground;
    _deliver();
  }

  void cancelReady() {
    if (_result != null) complete(cancelled);
  }

  void _deliver() {
    final result = _result;
    if (result == null || !context.mounted) return;
    final route = ModalRoute.of<T>(context);
    final navigator = route?.navigator;
    if (route == null || !route.isActive || navigator == null) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_waitForForeground &&
        lifecycle != null &&
        lifecycle != AppLifecycleState.resumed) {
      return;
    }
    _result = null;
    if (route.isCurrent) {
      navigator.pop(result);
    } else {
      navigator.removeRoute(route, cancelled);
    }
  }

  void dispose() => _lifecycle.dispose();
}

Future<bool> downloadWithProgress(
  BuildContext context,
  Gateway gateway, {
  required String path,
  required String profile,
  required File destination,
  required String name,
  String? session,
}) async {
  final outcome = await showDialog<_DownloadOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DownloadDialog(
      name: name,
      transfer: (control, progress) => gateway.downloadFile(
        path,
        destination,
        profile: profile,
        sessionId: session,
        control: control,
        progress: progress,
      ),
    ),
  );
  if (outcome?.error case final error?) throw error;
  return outcome?.complete == true;
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.name, required this.transfer});

  final String name;
  final Future<void> Function(FileTransferControl, FileTransferProgress)
  transfer;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  final control = FileTransferControl();
  final updates = Stopwatch()..start();
  late final FileTransferDialogCompletion<_DownloadOutcome> completion;
  int received = 0;
  int? total;
  bool cancelling = false;

  @override
  void initState() {
    super.initState();
    completion = FileTransferDialogCompletion(
      context,
      cancelled: (complete: false, error: null),
    );
    unawaited(run());
  }

  @override
  void dispose() {
    control.cancel();
    completion.dispose();
    super.dispose();
  }

  Future<void> run() async {
    var complete = false;
    Object? error;
    try {
      await widget.transfer(control, update);
      complete = true;
    } on FileTransferCancelled {
      // An aborted transfer is not a download error.
    } catch (failure) {
      if (!cancelling) error = failure;
    }
    if (!mounted) return;
    final success = complete && !cancelling;
    completion.complete(
      (complete: success, error: error),
      waitForForeground: success,
    );
  }

  void update(int bytes, int? length) {
    if (!mounted || cancelling) return;
    if (total == length &&
        bytes != length &&
        updates.elapsedMilliseconds < 100) {
      return;
    }
    updates.reset();
    setState(() {
      received = bytes;
      total = length;
    });
  }

  void cancel() {
    if (cancelling) return;
    setState(() => cancelling = true);
    control.cancel();
    completion.cancelReady();
  }

  @override
  Widget build(BuildContext context) {
    final length = total;
    final amount = length == null
        ? formatTransferSize(received)
        : '${formatTransferSize(received)} / ${formatTransferSize(length)}';
    final label = context.strings.format('已下载 {value}', {'value': amount});
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) cancel();
      },
      child: AlertDialog(
        title: Text(context.tr('下载文件')),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: length == null || length == 0
                  ? null
                  : (received / length).clamp(0.0, 1.0),
            ),
            const SizedBox(height: 9),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: cancelling ? null : cancel,
            child: Text(context.tr(cancelling ? '正在取消…' : '取消')),
          ),
        ],
      ),
    );
  }
}

String formatTransferSize(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB'];
  var value = bytes.toDouble(), unit = 0;
  while (unit < units.length - 1 && value >= 1024) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
