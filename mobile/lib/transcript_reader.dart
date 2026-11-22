import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'gateway.dart';
import 'history.dart' show historyRowId;
import 'activity_view.dart';
import 'message_content.dart';
import 'media_gallery.dart';
import 'workspace.dart';
import 'workspace_files.dart';
import 'timeline.dart';
import 'transcript_navigation.dart';
import 'transcript_match_view.dart';
import 'command_receipts.dart';
import 'command_receipt_view.dart';
import 'background_notice_view.dart';
import 'chat_display.dart';
import 'mobile_settings.dart';

Future<void> readAround(
  BuildContext context, {
  required Gateway gateway,
  required String profile,
  required String session,
  required String title,
  required MessageAddress address,
  String? baseDirectory,
  TranscriptMatchExcerpt? match,
}) => Navigator.push<void>(
  context,
  MaterialPageRoute(
    builder: (_) => TranscriptReader(
      navigation: TranscriptNavigation(gateway, profile, session),
      title: title,
      address: address,
      baseDirectory: baseDirectory,
      match: match,
    ),
  ),
);

class TranscriptReader extends StatefulWidget {
  const TranscriptReader({
    super.key,
    required this.navigation,
    required this.title,
    required this.address,
    this.baseDirectory,
    this.match,
  });
  final TranscriptNavigation navigation;
  final String title;
  final MessageAddress address;
  final String? baseDirectory;
  final TranscriptMatchExcerpt? match;
  @override
  State<TranscriptReader> createState() => _TranscriptReaderState();
}

class _TranscriptReaderState extends State<TranscriptReader> {
  TranscriptWindow? window;
  bool loading = true;
  String? error;
  int windowKey = 0;
  int centerAt = 0;
  bool centerOnAddress = true;
  static const center = ValueKey('transcript center');
  List<TimelineItem> rows = [];
  FileTransferControl? readControl;
  final activityExpansion = ActivityExpansion();
  List<CommandReceipt> receipts = [];
  final appearance = MobileAppearance.shared;
  late final profileReasoning = ProfileReasoning.of(
    widget.navigation.gateway,
    widget.navigation.profile,
  );
  late final localReceipts = CommandReceipts(
    widget.navigation.gateway,
    widget.navigation.profile,
    widget.navigation.session,
  ).read().catchError((Object _) => <CommandReceipt>[]);

  @override
  void initState() {
    super.initState();
    appearance.addListener(refreshDisplay);
    profileReasoning.addListener(refreshDisplay);
    unawaited(profileReasoning.refresh());
    load();
  }

  @override
  void dispose() {
    readControl?.cancel();
    appearance.removeListener(refreshDisplay);
    profileReasoning.removeListener(refreshDisplay);
    super.dispose();
  }

  (List<TimelineItem>, int) project(TranscriptWindow page) {
    final next = groupTimeline(
      displayRows(page.rows),
      showReasoning: appearance.reasoning.shows(profileReasoning),
      expandReasoning:
          profileReasoning.presentation == ReasoningPresentation.expanded,
      receipts: receipts,
      includeBeginning: !page.hasOlder,
      revealedRowId: widget.address.rowId,
    );
    final selected = next.indexWhere(
      (item) => switch (item) {
        TimelineMessage(:final row) => row.rowId == widget.address.rowId,
        TimelineActivity(:final rows) => rows.any(
          (row) => row.rowId == widget.address.rowId,
        ),
      },
    );
    return (next, selected);
  }

  void refreshDisplay() {
    final page = window;
    if (page == null || !mounted) return;
    final (next, selected) = project(page);
    setState(() {
      rows = next;
      centerAt = centerOnAddress && selected >= 0 ? selected : 0;
    });
  }

  Future<void> load({bool? older}) async {
    readControl?.cancel();
    final control = readControl = FileTransferControl();
    final previous = window;
    bool current() => mounted && identical(readControl, control);
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = older == null || previous == null
          ? await widget.navigation.locate(
              widget.address,
              stillOpen: current,
              control: control,
            )
          : await widget.navigation.adjacent(
              previous,
              older: older,
              control: control,
            );
      final notes = await localReceipts;
      if (!current()) return;
      receipts = notes;
      final (nextRows, selected) = project(page);
      if (older == null && selected < 0) throw GatewayError('目标消息已不可见');
      setState(() {
        window = page;
        rows = nextRows;
        centerOnAddress = older == null;
        centerAt = centerOnAddress ? selected : 0;
        windowKey++;
      });
    } catch (e) {
      if (current() && !control.cancelled) setState(() => error = e.toString());
    } finally {
      if (current()) {
        readControl = null;
        setState(() => loading = false);
      }
    }
  }

  Widget row(BuildContext context, TimelineItem item) {
    String? resolve(Uri uri) =>
        workspaceDocumentPath(uri, baseDirectory: widget.baseDirectory);
    Iterable<GalleryImage> gallery() => timelineGallery(
      rows,
      resolve: resolve,
      baseDirectory: widget.baseDirectory,
    );
    final scope = WorkspaceScope(
      widget.navigation.gateway,
      widget.navigation.profile,
      session: window!.session,
      cwd: widget.baseDirectory,
    );
    if (item is TimelineActivity) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ActivityGroup(
          activity: item,
          expansion: activityExpansion,
          revealed: item.rows.any((row) => row.rowId == widget.address.rowId),
          mediaScope: scope,
          gallery: gallery,
          addressFor: (rowId) {
            final page = window!;
            final index = page.rows.indexWhere(
              (row) => historyRowId(row) == rowId,
            );
            if (index < 0) return null;
            final position = page.positionOf(index);
            final offset = page.latestFirst
                ? position
                : (page.total ?? 0) - 1 - position;
            return MessageAddress(
              rowId,
              tailOffset: offset >= 0 ? offset : null,
            );
          },
        ),
      );
    }
    final record = (item as TimelineMessage).row;
    if (record.commandReceipt case final receipt?) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: CommandReceiptTile(receipt: receipt),
      );
    }
    if (record.backgroundNotice case final notice?) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: BackgroundNoticeTile(
          key: ValueKey(record.rowId ?? notice.raw),
          notice: notice,
          gateway: scope.gateway,
          profile: scope.profile,
          session: scope.session,
          gallery: gallery,
          baseDirectory: widget.baseDirectory,
          initiallyExpanded: record.rowId == widget.address.rowId,
          documentPath: resolve,
          onOpenDocument: (path, fragment) => openWorkspaceFile(
            context,
            scope,
            WorkspaceEntry(workspaceName(path), path),
            fragment: fragment,
          ),
        ),
      );
    }
    final colors = Theme.of(context).colorScheme;
    final focused = record.rowId == widget.address.rowId;
    final bubble = Align(
      alignment: record.user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth:
              MediaQuery.sizeOf(context).width * (record.user ? .83 : .93),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: record.user || focused ? colors.secondaryContainer : null,
          borderRadius: BorderRadius.circular(14),
          border: focused
              ? Border.all(color: colors.primary.withValues(alpha: .45))
              : null,
        ),
        child: MessageContent(
          user: record.user,
          body: record.body,
          gateway: widget.navigation.gateway,
          profile: widget.navigation.profile,
          session: window!.session,
          gallery: gallery,
          baseDirectory: widget.baseDirectory,
          documentPath: resolve,
          onOpenDocument: (path, fragment) => openWorkspaceFile(
            context,
            scope,
            WorkspaceEntry(workspaceName(path), path),
            fragment: fragment,
          ),
        ),
      ),
    );
    final match = focused ? widget.match : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: match == null
          ? bubble
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [TranscriptMatchPreview(match), bubble],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final page = window;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.tr('历史消息')),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: ConversationCanvas(
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              if (loading) const LinearProgressIndicator(minHeight: 2),
              if (error != null)
                ListTile(
                  title: Text(context.tr(error!)),
                  trailing: TextButton(
                    child: Text(context.tr('重新定位')),
                    onPressed: () => load(),
                  ),
                ),
              Expanded(
                child: page == null
                    ? const SizedBox.shrink()
                    : TranscriptTextSize(
                        size: appearance.messageSize,
                        child: CustomScrollView(
                          key: ValueKey(windowKey),
                          center: center,
                          anchor: centerAt == 0 ? 0 : .2,
                          slivers: [
                            SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) =>
                                    row(context, rows[centerAt - 1 - index]),
                                childCount: centerAt,
                              ),
                            ),
                            SliverList(
                              key: center,
                              delegate: SliverChildBuilderDelegate(
                                (context, index) =>
                                    row(context, rows[centerAt + index]),
                                childCount: rows.length - centerAt,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              if (page != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: loading || !page.hasOlder
                            ? null
                            : () => load(older: true),
                        icon: const Icon(Icons.arrow_upward, size: 16),
                        label: Text(context.tr('上一段')),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: loading || !page.hasNewer
                            ? null
                            : () => load(older: false),
                        icon: const Icon(Icons.arrow_downward, size: 16),
                        label: Text(context.tr('下一段')),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
