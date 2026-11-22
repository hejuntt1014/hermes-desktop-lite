import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'file_transfer_dialog.dart' show formatTransferSize;
import 'gateway.dart';
import 'protocol.dart';
import 'workspace.dart';

class WorkbookPreview extends StatefulWidget {
  const WorkbookPreview({super.key, required this.scope, required this.path});
  final WorkspaceScope scope;
  final String path;

  @override
  State<WorkbookPreview> createState() => _WorkbookPreviewState();
}

Future<Json> _readSheet(String path, int index) =>
    Isolate.run(() => workbookSheet(path, index));

class _Sheet {
  _Sheet(Json wire)
    : names = (wire['sheets'] as List).cast<String>(),
      rows = wire['rows'] as int,
      columns = wire['columns'] as int,
      clipped = wire['clipped'] == true {
    for (final row in (wire['cells'] as List).whereType<List>()) {
      final index = row[0] as int;
      values.putIfAbsent(index, () => {})[row[1] as int] = row[2] as String;
    }
  }
  final List<String> names;
  final int rows, columns;
  final bool clipped;
  final values = <int, Map<int, String>>{};
}

class _WorkbookPreviewState extends State<WorkbookPreview> {
  Directory? directory;
  File? downloaded;
  final _recentSheets = <int, _Sheet>{};
  _Sheet? sheet;
  String? error;
  int active = 0;
  bool loading = false, parsing = false;
  int received = 0;
  int? total;
  FileTransferControl? transfer;
  final progressClock = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    read(0);
  }

  Future<void> clean() async {
    final temp = directory;
    directory = null;
    if (temp != null) await temp.delete(recursive: true);
  }

  @override
  void dispose() {
    transfer?.cancel();
    if (!loading) unawaited(clean());
    super.dispose();
  }

  Future<void> read(int index) async {
    if (loading) return;
    if (_recentSheets.remove(index) case final cached?) {
      _recentSheets[index] = cached;
      setState(() {
        active = index;
        sheet = cached;
        error = null;
      });
      return;
    }
    setState(() {
      loading = true;
      parsing = downloaded != null;
      received = 0;
      total = null;
      error = null;
      active = index;
    });
    try {
      if (downloaded == null) {
        directory ??= await Directory.systemTemp.createTemp('hermes-workbook-');
        if (!mounted) return;
        final file = File('${directory!.path}/preview.xlsx');
        final scope = widget.scope;
        final control = transfer = FileTransferControl();
        await scope.gateway.downloadFile(
          widget.path,
          file,
          sessionId: scope.session,
          profile: scope.profile,
          maxBytes: 24 * 1024 * 1024,
          control: control,
          progress: updateProgress,
        );
        transfer = null;
        downloaded = file;
        if (mounted) setState(() => parsing = true);
      }
      if (!mounted) return;
      final wire = await _readSheet(downloaded!.path, index);
      if (!mounted) return;
      if (wire['error'] case final String issue) {
        throw GatewayError(switch (issue) {
          'size' => '工作簿超过预览大小限制，请下载查看',
          'no_sheet' => '工作簿中没有可预览的工作表',
          _ => '无法读取 XLSX 工作簿',
        });
      }
      final parsed = _Sheet(wire);
      _recentSheets[index] = parsed;
      if (_recentSheets.length > 2) {
        _recentSheets.remove(_recentSheets.keys.first);
      }
      setState(() => sheet = parsed);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      transfer = null;
      if (mounted) {
        setState(() => loading = false);
      } else {
        await clean();
      }
    }
  }

  void updateProgress(int bytes, int? length) {
    if (!mounted) return;
    if (length == total &&
        bytes != length &&
        progressClock.elapsedMilliseconds < 100) {
      return;
    }
    progressClock.reset();
    setState(() {
      received = bytes;
      total = length;
    });
  }

  Widget progress(BuildContext context) {
    final length = total;
    final percent = !parsing && length != null && length > 0
        ? (received / length).clamp(0.0, 1.0)
        : null;
    final title = context.tr(parsing ? '正在解析工作簿…' : '正在读取文件…');
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 330),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: percent, semanticsLabel: title),
              if (!parsing && (received > 0 || length != null)) ...[
                const SizedBox(height: 8),
                Text(
                  length == null
                      ? context.strings.format('已读取 {value}', {
                          'value': formatTransferSize(received),
                        })
                      : '${formatTransferSize(received)} / ${formatTransferSize(length)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final model = sheet;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (model != null)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            child: Row(
              children: [
                for (var i = 0; i < model.names.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: ChoiceChip(
                      label: Text(model.names[i]),
                      showCheckmark: false,
                      selected: i == active,
                      onSelected: loading
                          ? null
                          : (select) {
                              if (select) read(i);
                            },
                    ),
                  ),
              ],
            ),
          ),
        if (loading)
          Expanded(child: progress(context))
        else if (error != null)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.tr(error!),
                    style: TextStyle(color: colors.error),
                  ),
                  TextButton(
                    onPressed: () => read(active),
                    child: Text(context.tr('重试')),
                  ),
                ],
              ),
            ),
          )
        else if (model != null) ...[
          if (model.clipped)
            Padding(
              padding: const EdgeInsets.fromLTRB(17, 6, 17, 10),
              child: Text(
                context.tr('部分内容超出预览范围，可下载查看完整工作表'),
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          Expanded(
            child: model.rows == 0
                ? Center(child: Text(context.tr('此工作表为空')))
                : _WorkbookGrid(
                    key: ValueKey(active),
                    sheet: model,
                    scope: (widget.path, active),
                  ),
          ),
        ],
      ],
    );
  }
}

class _WorkbookGrid extends StatefulWidget {
  const _WorkbookGrid({super.key, required this.sheet, required this.scope});
  final _Sheet sheet;
  final (String, int) scope;

  @override
  State<_WorkbookGrid> createState() => _WorkbookGridState();
}

class _WorkbookGridState extends State<_WorkbookGrid> {
  static const rowHeaderWidth = 43.0;
  final horizontal = ScrollController();

  @override
  void dispose() {
    horizontal.dispose();
    super.dispose();
  }

  String columnName(int index) {
    var name = '';
    for (var value = index + 1; value > 0; value = (value - 1) ~/ 26) {
      name = String.fromCharCode(65 + (value - 1) % 26) + name;
    }
    return name;
  }

  Widget row(int? index) {
    final colors = Theme.of(context).colorScheme;
    final heading = index == null;
    final record = widget.sheet.values[index];
    final background = heading || index.isEven
        ? colors.surfaceContainerLow
        : colors.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        border: Border(
          bottom: BorderSide(color: colors.outlineVariant, width: .6),
        ),
      ),
      child: Stack(
        children: [
          Row(
            children: [
              const SizedBox(width: rowHeaderWidth),
              for (var col = 0; col < widget.sheet.columns; col++)
                cell(
                  heading ? columnName(col) : record?[col] ?? '',
                  header: heading,
                ),
            ],
          ),
          ListenableBuilder(
            listenable: horizontal,
            child: ColoredBox(
              color: background,
              child: cell(
                heading ? '' : '${index + 1}',
                width: rowHeaderWidth,
                header: true,
              ),
            ),
            builder: (context, child) => Transform.translate(
              offset: Offset(horizontal.hasClients ? horizontal.offset : 0, 0),
              child: child,
            ),
          ),
        ],
      ),
    );
  }

  Widget cell(String value, {double width = 126, required bool header}) {
    final colors = Theme.of(context).colorScheme;
    final label = Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        color: header ? colors.onSurfaceVariant : colors.onSurface,
        fontWeight: header ? FontWeight.w600 : FontWeight.normal,
      ),
    );
    return Container(
      width: width,
      height: 36,
      alignment: header ? Alignment.center : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: colors.outlineVariant, width: .6),
        ),
      ),
      child: header || value.isEmpty
          ? label
          : GestureDetector(
              onLongPress: () async {
                await Clipboard.setData(ClipboardData(text: value));
                if (mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(context.tr('已复制单元格'))));
                }
              },
              child: value.length > 14
                  ? Tooltip(
                      message: value,
                      triggerMode: TooltipTriggerMode.tap,
                      child: label,
                    )
                  : label,
            ),
    );
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: horizontal,
    notificationPredicate: (note) => note.metrics.axis == Axis.horizontal,
    child: SingleChildScrollView(
      key: PageStorageKey((widget.scope, Axis.horizontal)),
      controller: horizontal,
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: rowHeaderWidth + widget.sheet.columns * 126,
        child: Column(
          children: [
            row(null),
            Expanded(
              child: ListView.builder(
                key: PageStorageKey((widget.scope, Axis.vertical)),
                itemCount: widget.sheet.rows,
                itemExtent: 36,
                itemBuilder: (_, index) => row(index),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
