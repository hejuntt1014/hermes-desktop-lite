import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import 'attachment_view.dart' show attachedPath, saveLocalFile;
import 'message_content.dart'
    show
        historyDisplayContent,
        messageBody,
        messageFence,
        messageLineAttachment,
        projectUserMessage,
        structuredMessageImages,
        toolImagePath;
import 'gateway.dart';
import 'history.dart';
import 'file_transfer_dialog.dart' show FileTransferDialogCompletion;
import 'mobile_locale.dart';
import 'timeline.dart' show activityJson, activityText, toolInlineDiff;
import 'workspace.dart' show workspaceName;

part 'session_export_markdown.dart';

enum SessionExportFormat { markdown, json }

const _exportChanged = '导出期间会话历史发生变化，请重试';
const _legacyExportPageLimit = 250;
const _exportPageBytes = 8 * 1024 * 1024;
const _exportWriteChars = 256 * 1024;
final _legacyExportLinks = Expando<int>();

typedef _ExportSnapshot = ({int throughId, String version});
typedef _ExportPage = ({
  String session,
  List<Json> rows,
  bool hasMore,
  int bytes,
  _ExportSnapshot? snapshot,
});
typedef _ExportBatch = ({
  _ExportPage page,
  bool overlaps,
  bool single,
  int nextLimit,
});

Future<_ExportPage> _readExportPage(
  Gateway gateway,
  String path, {
  required String id,
  required String profile,
  required int offset,
  required int limit,
  required bool latest,
  required FileTransferControl control,
  bool inlineImages = true,
  int? byteLimit,
  int? exportThrough,
}) async {
  final order = latest ? 'latest' : 'oldest';
  var bytes = 0;
  final Json result;
  try {
    result = await gateway.readConversationPage(
      path,
      backgroundDecode: !latest,
      control: control,
      maxResponseBytes: byteLimit,
      onResponseBytes: (value) => bytes = value,
      query: {
        'profile': profile,
        'limit': '$limit',
        'order': order,
        'offset': '$offset',
        'include_compacted': 'true',
        'inline_images': '$inlineImages',
        if (exportThrough != null) 'export_through': '$exportThrough',
      },
    );
  } on GatewayError catch (failure) {
    if (exportThrough != null && failure.status == 409) {
      throw GatewayError(_exportChanged);
    }
    rethrow;
  }
  final pageId = result['session_id'];
  final pagination = result['pagination'];
  final data = result['messages'];
  if (result['profile'] != null && result['profile'] != profile ||
      data is! List ||
      data.length > limit ||
      !data.every((row) => row is Json) ||
      pagination is! Json ||
      pagination['offset'] != offset ||
      pagination['order'] != null && pagination['order'] != order) {
    throw GatewayError(_exportChanged);
  }
  final appliedLimit = pagination['limit'];
  final pageLimit = appliedLimit is int && appliedLimit > 0
      ? appliedLimit
      : limit;
  final stamp = exportThrough == null ? null : result['export_snapshot'];
  final through = stamp is Json ? stamp['through_id'] : null;
  final version = stamp is Json ? stamp['version'] : null;
  return (
    session: pageId is String && pageId.isNotEmpty ? pageId : id,
    rows: data.cast<Json>(),
    hasMore: data.length >= pageLimit,
    bytes: bytes,
    snapshot: through is int &&
            through > 0 &&
            version is String &&
            version.isNotEmpty
        ? (throughId: through, version: version)
        : null,
  );
}

Future<_ExportPage> _readExportTail(
  Gateway gateway,
  String path, {
  required String id,
  required String profile,
  required FileTransferControl control,
}) async {
  Future<_ExportPage> read({bool metadataOnly = false}) => _readExportPage(
    gateway,
    path,
    id: id,
    profile: profile,
    offset: 0,
    limit: 1,
    latest: true,
    control: control,
    inlineImages: !metadataOnly,
    exportThrough: metadataOnly ? 0 : null,
  );

  final link = gateway.connectionRevision;
  if (_legacyExportLinks[gateway] != link) {
    try {
      final page = await read(metadataOnly: true);
      final row = page.rows.singleOrNull;
      final snapshot = page.snapshot;
      if (row == null) return page;
      if (snapshot != null && snapshot.throughId == historyRowId(row)) {
        return page;
      }
    } on GatewayError catch (failure) {
      if (!{400, 405, 422, 501}.contains(failure.status)) rethrow;
    }
    _legacyExportLinks[gateway] = link;
  }
  return read();
}

Future<_ExportBatch> _readExportBatch(
  Gateway gateway,
  String path, {
  required String session,
  required String profile,
  required int offset,
  required Json? boundary,
  required bool followsSingle,
  required int pageLimit,
  required int preferredLimit,
  required FileTransferControl control,
}) async {
  Future<_ExportPage> read(
    int start,
    int limit, {
    bool inlineImages = true,
    int? byteLimit,
  }) => _readExportPage(
    gateway,
    path,
    id: session,
    profile: profile,
    offset: start,
    limit: limit,
    latest: false,
    inlineImages: inlineImages,
    byteLimit: byteLimit,
    control: control,
  );

  Future<void> checkBoundary() async {
    final previous = boundary;
    if (previous == null) return;
    final hasAddress = historyRowId(previous) != null;
    final page = await read(offset - 1, 1, inlineImages: !hasAddress);
    final row = page.rows.singleOrNull;
    if (page.session != session ||
        row == null ||
        (hasAddress
            ? !sameHistoryTail(previous, row)
            : !sameHistoryRow(previous, row, compareContent: true))) {
      throw GatewayError(_exportChanged);
    }
  }

  // A large preceding row must not be downloaded again just for the overlap.
  if (followsSingle) await checkBoundary();
  final overlaps = boundary != null && !followsSingle;
  var limit = preferredLimit;
  while (limit >= 2) {
    try {
      final page = await read(
        overlaps ? offset - 1 : offset,
        limit,
        byteLimit: _exportPageBytes,
      );
      final nextLimit = page.bytes < _exportPageBytes ~/ 3
          ? math.min(pageLimit, limit * 2)
          : limit;
      return (
        page: page,
        overlaps: overlaps,
        single: false,
        nextLimit: nextLimit,
      );
    } on GatewayResponseTooLarge {
      control.throwIfCancelled();
      limit = limit == 2 ? 1 : math.max(2, limit ~/ 2);
    }
  }

  if (overlaps) await checkBoundary();
  // Export an oversized row on its own, including all of its original data.
  final page = await read(offset, 1);
  return (page: page, overlaps: false, single: true, nextLimit: 2);
}

Future<int?> _exportRevision(
  Gateway gateway,
  String id,
  String profile,
  FileTransferControl control,
) async {
  try {
    final detail = await gateway.readConversationPage(
      'api/sessions/${Uri.encodeComponent(id)}',
      query: {'profile': profile},
      control: control,
    );
    final revision = detail['transcript_revision'];
    if (revision is! int) return null;
    if (detail['id'] != id ||
        detail['profile'] != null && detail['profile'] != profile) {
      throw GatewayError(_exportChanged);
    }
    return revision;
  } on GatewayError catch (failure) {
    if ({403, 404, 405, 501}.contains(failure.status)) return null;
    rethrow;
  }
}

Future<bool> exportConversation(
  BuildContext context,
  Gateway gateway, {
  required String id,
  required String profile,
  required String title,
  required SessionExportFormat format,
  required bool Function() stillOpen,
  Rect? shareOrigin,
}) async {
  final strings = context.strings;
  final directory = await Directory.systemTemp.createTemp('hermes-export-');
  final safe = title.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '-').trim();
  final name = safe.isEmpty
      ? strings.text('会话记录')
      : String.fromCharCodes(safe.runes.take(64));
  final isJson = format == SessionExportFormat.json;
  final file = File('${directory.path}/$name.${isJson ? 'json' : 'md'}');
  Future<bool>? writing;
  try {
    if (!context.mounted || !stillOpen()) return false;
    final preparation = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportProgress(
        prepare: (control, progress) => writing = _writeExport(
          gateway,
          file: file,
          id: id,
          profile: profile,
          title: title,
          strings: strings,
          isJson: isJson,
          control: control,
          stillOpen: stillOpen,
          progress: progress,
        ),
      ),
    );
    if (preparation != true || !stillOpen()) return false;
    if (shareOrigin == null) return await saveLocalFile(file);
    final result = await SharePlus.instance.share(
      ShareParams(
        title: title,
        files: [
          XFile(
            file.path,
            mimeType: isJson ? 'application/json' : 'text/markdown',
          ),
        ],
        sharePositionOrigin: shareOrigin,
      ),
    );
    return result.status == ShareResultStatus.success;
  } finally {
    await writing?.catchError((Object _) => false);
    await directory.delete(recursive: true);
  }
}

Future<bool> _writeExport(
  Gateway gateway, {
  required File file,
  required String id,
  required String profile,
  required String title,
  required MobileStrings strings,
  required bool isJson,
  required FileTransferControl control,
  required bool Function() stillOpen,
  required ValueChanged<int> progress,
}) async {
  final sink = file.openWrite(encoding: utf8);
  final buffer = StringBuffer();

  Future<void> flushText() async {
    if (buffer.isEmpty) return;
    sink.write(buffer.toString());
    buffer.clear();
    await sink.flush();
  }
  try {
    final exportedAt = DateTime.now().toUtc().toIso8601String();
    final markdown = isJson ? null : _MarkdownExport(buffer, strings);
    if (markdown == null) {
      buffer.write(
        '{ "exported_at": ${jsonEncode(exportedAt)}, "session_id": ${jsonEncode(id)}, '
        '"title": ${jsonEncode(title)}, "session": null, "messages": [',
      );
    } else {
      markdown.start(title, id, exportedAt);
    }
    final path = 'api/sessions/${Uri.encodeComponent(id)}/messages';
    final tail = await _readExportTail(
      gateway,
      path,
      id: id,
      profile: profile,
      control: control,
    );
    final last = tail.rows.firstOrNull;
    final cutoff = last == null ? null : historyRowId(last);
    final snapshot = tail.snapshot;
    final revision = last == null || snapshot != null
        ? null
        : await _exportRevision(gateway, tail.session, profile, control);
    Json? boundary;
    var offset = 0, count = 0;
    var pageLimit = gateway.canonical ? 500 : _legacyExportPageLimit;
    var preferredLimit = pageLimit;
    final writeSlice = Stopwatch();
    var followsSingle = false;

    Future<bool> finish() async {
      if (!stillOpen() || control.cancelled) return false;
      if (snapshot != null) {
        final current = await _readExportPage(
          gateway,
          path,
          id: id,
          profile: profile,
          offset: 0,
          limit: 0,
          latest: true,
          inlineImages: false,
          exportThrough: snapshot.throughId,
          control: control,
        );
        if (current.session != tail.session || current.snapshot != snapshot) {
          throw GatewayError(_exportChanged);
        }
      } else if (revision != null &&
          await _exportRevision(gateway, tail.session, profile, control) !=
              revision) {
        throw GatewayError(_exportChanged);
      }
      if (!stillOpen() || control.cancelled) return false;
      if (isJson) buffer.writeln('\n], "message_count": $count }');
      await flushText();
      return stillOpen() && !control.cancelled;
    }

    if (last == null) return await finish();
    while (stillOpen() && !control.cancelled) {
      late final _ExportBatch batch;
      try {
        batch = await _readExportBatch(
          gateway,
          path,
          session: tail.session,
          profile: profile,
          offset: offset,
          boundary: boundary,
          followsSingle: followsSingle,
          pageLimit: pageLimit,
          preferredLimit: preferredLimit,
          control: control,
        );
      } on GatewayError catch (error) {
        if (pageLimit <= _legacyExportPageLimit ||
            !{400, 422}.contains(error.status)) {
          rethrow;
        }
        pageLimit = _legacyExportPageLimit;
        preferredLimit = math.min(preferredLimit, pageLimit);
        continue;
      }
      if (!stillOpen() || control.cancelled) return false;
      final result = batch.page;
      final page = result.rows;
      if (result.session != tail.session ||
          batch.overlaps &&
              (page.isEmpty ||
                  !sameHistoryRow(
                    page.first,
                    boundary!,
                    compareContent: true,
                  ))) {
        throw GatewayError(_exportChanged);
      }
      var reachedCutoff = false;
      final records = page.skip(batch.overlaps ? 1 : 0);
      writeSlice
        ..reset()
        ..start();
      for (final row in records) {
        if (writeSlice.elapsedMilliseconds >= 12) {
          await Future<void>.delayed(Duration.zero);
          writeSlice.reset();
          if (!stillOpen() || control.cancelled) return false;
        }
        reachedCutoff = cutoff != null && historyRowId(row) == cutoff;
        if (reachedCutoff &&
            snapshot == null &&
            !sameHistoryRow(row, last, compareContent: true)) {
          throw GatewayError(_exportChanged);
        }
        if (markdown == null) {
          if (count > 0) buffer.write(',');
          buffer.write('\n${jsonEncode(row)}');
        } else {
          markdown.write(row);
        }
        count++;
        if (buffer.length >= _exportWriteChars) {
          await flushText();
          writeSlice.reset();
          if (!stillOpen() || control.cancelled) return false;
        }
        if (reachedCutoff) break;
      }
      writeSlice.stop();
      await flushText();
      if (!stillOpen() || control.cancelled) return false;
      progress(count);
      if (reachedCutoff) return await finish();
      if (!result.hasMore) {
        if (cutoff != null) throw GatewayError(_exportChanged);
        return await finish();
      }
      // A full overlap with no new rows is possible when the gateway applies
      // a smaller per-request limit. Advance by fetching the next row alone.
      if (records.isEmpty) {
        followsSingle = true;
        preferredLimit = 2;
        continue;
      }
      final lastRow = page.last;
      final lastId = historyRowId(lastRow);
      boundary = batch.single && lastId != null
          ? {'row_id': lastId, 'finish_reason': lastRow['finish_reason']}
          : lastRow;
      followsSingle = batch.single;
      preferredLimit = batch.nextLimit;
      offset += records.length;
    }
    return false;
  } finally {
    await sink.close();
  }
}

class _ExportProgress extends StatefulWidget {
  const _ExportProgress({required this.prepare});

  final Future<bool> Function(FileTransferControl, ValueChanged<int>) prepare;

  @override
  State<_ExportProgress> createState() => _ExportProgressState();
}

class _ExportProgressState extends State<_ExportProgress> {
  var count = 0;
  var cancelling = false;
  var control = FileTransferControl();
  Object? error;
  late final FileTransferDialogCompletion<bool> completion;

  @override
  void initState() {
    super.initState();
    completion = FileTransferDialogCompletion(context, cancelled: false);
    unawaited(run());
  }

  @override
  void dispose() {
    control.cancel();
    completion.dispose();
    super.dispose();
  }

  Future<void> run() async {
    final current = control;
    var complete = false;
    try {
      complete = await widget.prepare(current, (value) {
        if (mounted && !current.cancelled) setState(() => count = value);
      });
    } catch (failure) {
      if (mounted && !current.cancelled) {
        setState(() => error = failure);
        return;
      }
    }
    if (!mounted) return;
    final success = complete && !current.cancelled;
    completion.complete(success, waitForForeground: success);
  }

  void retry() {
    setState(() {
      error = null;
      count = 0;
      control = FileTransferControl();
    });
    unawaited(run());
  }

  void cancel() {
    if (error != null) {
      completion.complete(false);
    } else if (!cancelling) {
      setState(() => cancelling = true);
      control.cancel();
      completion.cancelReady();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) cancel();
    },
    child: AlertDialog(
      title: Text(context.tr('导出会话')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error case final failure?)
            Text(
              context.tr(failure is GatewayError ? failure.message : '无法导出会话'),
            )
          else ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              context.strings.format('已读取 {count} 条消息', {'count': '$count'}),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: cancelling ? null : cancel,
          child: Text(context.tr(cancelling ? '正在取消…' : '取消')),
        ),
        if (error != null)
          FilledButton(onPressed: retry, child: Text(context.tr('重试'))),
      ],
    ),
  );
}
