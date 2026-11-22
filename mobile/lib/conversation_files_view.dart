import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'attachment_view.dart';
import 'conversation_files.dart';
import 'gateway.dart' show FileTransferCancelled, FileTransferControl, Json;
import 'media_gallery.dart';
import 'mobile_clipboard.dart';
import 'transcript_navigation.dart';
import 'transcript_reader.dart';
import 'workspace.dart';
import 'workspace_files.dart';

enum _FileAction {
  reference('引用到草稿', Icons.add_comment_outlined),
  download('下载附件', Icons.download_outlined),
  share('分享文件', Icons.ios_share_outlined),
  copyPath('复制远程路径', Icons.link_rounded),
  reveal('定位原消息', Icons.my_location_outlined);

  const _FileAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

enum _FileFilter {
  all('全部'),
  images('仅图片'),
  other('其他文件');

  const _FileFilter(this.label);
  final String label;

  bool includes(ConversationFile file) => switch (this) {
    all => true,
    images => file.image,
    other => !file.image,
  };
}

class ConversationFiles extends StatefulWidget {
  const ConversationFiles({
    super.key,
    required this.scope,
    required this.title,
    this.useWorkspaceDefault = true,
    this.onRevealMessage,
    this.onReference,
  });
  final WorkspaceScope scope;
  final String title;
  final bool useWorkspaceDefault;
  final ValueChanged<MessageAddress>? onRevealMessage;
  final ValueChanged<WorkspaceEntry>? onReference;

  @override
  State<ConversationFiles> createState() => _ConversationFilesState();
}

class _ConversationFilesState extends State<ConversationFiles>
    with AutomaticKeepAliveClientMixin {
  late final navigation = TranscriptNavigation(
    widget.scope.gateway,
    widget.scope.profile,
    widget.scope.session!,
  );
  final search = TextEditingController();
  late TranscriptScan records;
  FileTransferControl? readingControl;
  final files = <ConversationFile>[];
  final updating = <ConversationFile>{};
  final projectedReads = <ConversationFile, FileTransferControl>{};
  final failedImages = <ConversationFile>{};
  late Future<String?> cwd = resolveRoot();
  bool loading = false, hasEarlier = true, routeVisible = false;
  String? failure;
  String query = '';
  _FileFilter filter = _FileFilter.all;
  String imageName = '图片';
  int round = 0, browseRemaining = 320, checked = 0;
  int? searchTarget;
  Timer? searchDelay;
  TabController? tabs;
  late final AppLifecycleListener lifecycle;

  bool get visible =>
      routeVisible &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) &&
      (tabs == null || tabs!.index == tabs!.length - 1);

  bool get seekingFiles {
    final target = searchTarget;
    return hasEarlier &&
        target != null &&
        matchingFiles.skip(target - 1).isEmpty;
  }

  @override
  bool get wantKeepAlive => true;

  Future<String?> resolveRoot() async {
    if (!widget.useWorkspaceDefault) return widget.scope.cwd;
    try {
      return await widget.scope.root();
    } catch (_) {
      return widget.scope.cwd;
    }
  }

  @override
  void initState() {
    super.initState();
    records = TranscriptScan(navigation);
    lifecycle = AppLifecycleListener(
      onResume: () {
        setState(() {});
        resumeReading();
      },
      onInactive: stopReads,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    imageName = context.tr('图片');
    routeVisible = ModalRoute.isCurrentOf(context) != false;
    final controller = DefaultTabController.maybeOf(context);
    if (!identical(controller, tabs)) {
      tabs?.removeListener(resumeReading);
      tabs = controller;
      tabs?.addListener(resumeReading);
    }
    resumeReading();
  }

  void resumeReading() {
    if (!visible) {
      stopReads();
      return;
    }
    if (loading || failure != null || !hasEarlier) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(readEarlier());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    lifecycle.dispose();
    tabs?.removeListener(resumeReading);
    searchDelay?.cancel();
    stopReads();
    search.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    searchDelay?.cancel();
    stopReads();
    round++;
    records = TranscriptScan(navigation);
    cwd = resolveRoot();
    setState(() {
      files.clear();
      failedImages.clear();
      projectedReads.clear();
      failure = null;
      loading = false;
      hasEarlier = true;
      browseRemaining = 320;
      checked = 0;
      searchTarget = query.isEmpty ? null : 1;
    });
    await readEarlier();
  }

  void stopReads() {
    readingControl?.cancel();
    for (final control in projectedReads.values) {
      control.cancel();
    }
  }

  Future<void> loadProjectedImages(
    ConversationFile group, {
    bool retry = false,
  }) async {
    if (!mounted ||
        !visible ||
        !files.contains(group) ||
        projectedReads.containsKey(group) ||
        projectedReads.length >= 2 ||
        !retry && failedImages.contains(group)) {
      return;
    }
    final control = FileTransferControl();
    setState(() {
      failedImages.remove(group);
      projectedReads[group] = control;
    });
    bool current() =>
        mounted &&
        !control.cancelled &&
        identical(projectedReads[group], control);
    final address = group.address;
    try {
      final row = await group.readSource(
        navigation,
        stillOpen: current,
        scanHistory: retry,
        control: control,
      );
      if (!current()) return;
      final root = await cwd;
      if (!current()) return;
      final entries = await scanConversationFiles(
        [(row: row, tailOffset: address.tailOffset ?? 0)],
        root,
        allowProjected: false,
      );
      if (!current()) return;
      setState(() {
        bool sameMessage(ConversationFile file) =>
            file.address.rowId == address.rowId;
        final index = files.indexWhere(sameMessage);
        if (index < 0) return;
        files.removeWhere(sameMessage);
        files.insertAll(index, entries);
      });
    } catch (_) {
      if (current()) setState(() => failedImages.add(group));
    } finally {
      if (mounted && identical(projectedReads[group], control)) {
        setState(() => projectedReads.remove(group));
      }
    }
  }

  Future<void> readEarlier() async {
    if (loading ||
        failure != null ||
        !hasEarlier ||
        !visible ||
        (browseRemaining == 0 && !seekingFiles)) {
      return;
    }
    final entryRound = round;
    final scan = records;
    final control = readingControl = FileTransferControl();
    setState(() => loading = true);
    try {
      final root = await cwd;
      while (mounted &&
          entryRound == round &&
          visible &&
          hasEarlier &&
          !control.cancelled &&
          (browseRemaining > 0 || seekingFiles)) {
        var finished = false;
        Object? pageError;
        final batch = <HistoryRecord>[];
        final limit = browseRemaining == 0
            ? 160
            : browseRemaining.clamp(0, 160);
        try {
          for (var count = 0; count < limit && !control.cancelled; count++) {
            final record = await scan.next(control: control);
            if (!mounted || entryRound != round) return;
            if (record == null) {
              finished = true;
              break;
            }
            batch.add(record);
          }
        } on FileTransferCancelled {
          // Keep any records consumed before the next request was interrupted.
        } on Exception catch (error) {
          pageError = error;
        }
        if (!mounted || entryRound != round) return;
        final items = batch.isEmpty
            ? const <ConversationFile>[]
            : await scanConversationFiles(batch, root);
        if (!mounted || entryRound != round) return;
        setState(() {
          files.addAll(items);
          checked += batch.length;
          browseRemaining = (browseRemaining - batch.length).clamp(0, 320);
          hasEarlier = !finished;
          failure = pageError?.toString();
        });
        if (pageError != null) return;
      }
    } catch (e) {
      if (mounted && entryRound == round) {
        setState(() => failure = e.toString());
      }
    } finally {
      if (identical(readingControl, control)) readingControl = null;
      if (mounted && entryRound == round) {
        setState(() => loading = false);
        if (control.cancelled &&
            visible &&
            (browseRemaining > 0 || seekingFiles)) {
          resumeReading();
        }
      }
    }
  }

  void retryReading() {
    setState(() => failure = null);
    unawaited(readEarlier());
  }

  void changeFilter(_FileFilter value) {
    if (filter == value) return;
    setState(() {
      filter = value;
      searchTarget = query.isEmpty ? null : 1;
    });
    if (query.isNotEmpty) unawaited(readEarlier());
  }

  void changeQuery(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == query) return;
    searchDelay?.cancel();
    if (browseRemaining == 0) readingControl?.cancel();
    setState(() {
      query = normalized;
      searchTarget = null;
    });
    if (query.isNotEmpty && hasEarlier) {
      searchDelay = Timer(const Duration(milliseconds: 280), startSearch);
    }
  }

  void startSearch() {
    searchDelay?.cancel();
    if (query.isEmpty || !hasEarlier) return;
    setState(() => searchTarget = 1);
    unawaited(readEarlier());
  }

  void loadMore() {
    if (query.isEmpty) {
      browseRemaining = 320;
    } else {
      searchDelay?.cancel();
      setState(() => searchTarget = matchingFiles.length + 1);
    }
    unawaited(readEarlier());
  }

  void stopSearch() {
    setState(() => searchTarget = null);
    if (browseRemaining == 0) readingControl?.cancel();
  }

  String fileName(ConversationFile file) =>
      file.genericName ? imageName : file.name;

  Iterable<ConversationFile> get matchingFiles => files.where(
    (file) =>
        filter.includes(file) &&
        (query.isEmpty ||
            fileName(file).toLowerCase().contains(query) ||
            file.name.toLowerCase().contains(query) ||
            file.destination?.toLowerCase().contains(query) == true),
  );

  Future<void> open(
    ConversationFile file, {
    _FileAction? action,
    Rect? shareOrigin,
  }) async {
    if (updating.contains(file)) return;
    setState(() => updating.add(file));
    try {
      if (file.image && action == null) {
        (int, Future<Json>)? sourceRow;
        GalleryImage galleryImage(ConversationFile item) {
          final name = fileName(item);
          if (item.path case final path?) {
            return GalleryImage.path(path, key: item, alt: name);
          }
          return GalleryImage.deferred(item, () async {
            final rowId = item.address.rowId;
            if (sourceRow?.$1 != rowId) {
              sourceRow = (rowId, item.readSource(navigation));
            }
            final request = sourceRow!;
            try {
              return item.resolveInlineImage(await request.$2);
            } catch (_) {
              if (sourceRow == request) sourceRow = null;
              rethrow;
            }
          }, alt: name);
        }

        final images = matchingFiles
            .where((item) => item.image && !item.projectedImages)
            .map(galleryImage);
        await openImageGallery(
          context,
          scope: widget.scope,
          images: images,
          selected: galleryImage(file),
          onReference: widget.onReference,
        );
        return;
      }
      final path = await file.resolve(navigation);
      if (!mounted) return;
      if (action == _FileAction.share && shareOrigin != null) {
        await shareRemoteFile(
          context,
          widget.scope.gateway,
          path: path,
          profile: widget.scope.profile,
          session: widget.scope.session,
          origin: shareOrigin,
          stillOpen: () => mounted,
        );
      } else if (action == _FileAction.download) {
        final saved = await saveRemoteFile(
          context,
          widget.scope.gateway,
          path: path,
          profile: widget.scope.profile,
          session: widget.scope.session,
          stillOpen: () => mounted,
        );
        if (saved && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(context.tr('文件已保存'))));
        }
      } else {
        await openWorkspaceFile(
          context,
          widget.scope,
          WorkspaceEntry(file.name, path),
          fragment: file.fragment,
          onReference: widget.onReference,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr(e.toString()))));
      }
    } finally {
      if (mounted) setState(() => updating.remove(file));
    }
  }

  Widget fileMenu(ConversationFile file) => Builder(
    builder: (anchor) => PopupMenuButton<_FileAction>(
      tooltip: context.tr('附件操作'),
      icon: const Icon(Icons.more_horiz_rounded, size: 21),
      onSelected: (action) {
        switch (action) {
          case _FileAction.reference:
            if (file.path case final path?) {
              widget.onReference?.call(WorkspaceEntry(file.name, path));
            }
          case _FileAction.download:
            open(file, action: action);
          case _FileAction.share:
            open(file, action: action, shareOrigin: fileShareOrigin(anchor));
          case _FileAction.copyPath:
            if (file.path case final path?) {
              copyMobileText(context, path, '已复制远程路径');
            }
          case _FileAction.reveal:
            showOriginal(file);
        }
      },
      itemBuilder: (menu) => [
        for (final action in _FileAction.values)
          if ((action != _FileAction.copyPath || file.path != null) &&
              (action != _FileAction.reference ||
                  file.path != null && widget.onReference != null))
            PopupMenuItem(
              value: action,
              child: Row(
                children: [
                  Icon(action.icon, size: 19),
                  const SizedBox(width: 12),
                  Flexible(child: Text(menu.tr(action.label))),
                ],
              ),
            ),
      ],
    ),
  );

  void showOriginal(ConversationFile file) {
    if (widget.onRevealMessage case final reveal?) {
      reveal(file.address);
      return;
    }
    readAround(
      context,
      gateway: widget.scope.gateway,
      profile: widget.scope.profile,
      session: navigation.session,
      title: widget.title,
      address: file.address,
      baseDirectory: widget.scope.cwd,
    );
  }

  Widget projectedImageTile(ConversationFile file) {
    final failed = failedImages.contains(file);
    if (!failed && !projectedReads.containsKey(file)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(loadProjectedImages(file));
      });
    }
    return ListTile(
      key: ObjectKey(file),
      dense: true,
      leading: const Icon(Icons.image_outlined, size: 20),
      title: Text(context.tr(failed ? '重新加载图片' : '正在读取图片…')),
      onTap: failed ? () => loadProjectedImages(file, retry: true) : null,
      trailing: failed
          ? const Icon(Icons.refresh_rounded, size: 20)
          : const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = Theme.of(context).colorScheme;
    final matches = matchingFiles.toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(17, 12, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: search,
                  textInputAction: TextInputAction.search,
                  onChanged: changeQuery,
                  onSubmitted: (_) => startSearch(),
                  decoration: InputDecoration(
                    hintText: context.tr('查找会话文件'),
                    prefixIcon: const Icon(Icons.search_rounded, size: 19),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: context.tr('清空搜索'),
                            onPressed: () {
                              search.clear();
                              changeQuery('');
                            },
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                  ),
                ),
              ),
              IconButton(
                tooltip: context.tr('刷新会话文件'),
                onPressed: loading ? null : refresh,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(17, 0, 12, 4),
            child: Wrap(
              spacing: 8,
              children: [
                for (final option in _FileFilter.values)
                  ChoiceChip(
                    label: Text(context.tr(option.label)),
                    selected: filter == option,
                    showCheckmark: false,
                    onSelected: (_) => changeFilter(option),
                  ),
              ],
            ),
          ),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (loading && seekingFiles)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 19, end: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.strings.format('已搜索 {count} 条消息', {
                      'count': checked,
                    }),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
                TextButton(
                  onPressed: stopSearch,
                  child: Text(context.tr('停止搜索')),
                ),
              ],
            ),
          ),
        if (failure != null)
          ListTile(
            title: Text(
              context.tr(failure!),
              style: TextStyle(color: colors.error),
            ),
            trailing: TextButton(
              onPressed: retryReading,
              child: Text(context.tr('重试')),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: refresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(15, 2, 12, 16),
              itemCount: matches.length + 1,
              itemBuilder: (context, index) {
                if (index == matches.length) {
                  return Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      children: [
                        if (!loading && failure == null && matches.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              hasEarlier
                                  ? context.tr('已查看的消息里没有匹配文件')
                                  : context.tr('没有匹配的会话文件'),
                            ),
                          ),
                        if (hasEarlier && !loading && failure == null)
                          TextButton(
                            onPressed: loadMore,
                            child: Text(context.tr('查找更早的文件')),
                          ),
                      ],
                    ),
                  );
                }
                final file = matches[index];
                if (file.projectedImages) return projectedImageTile(file);
                final waiting = updating.contains(file);
                return ListTile(
                  dense: true,
                  minTileHeight: 52,
                  contentPadding: const EdgeInsets.only(left: 10, right: 3),
                  leading: Icon(
                    file.image
                        ? Icons.image_outlined
                        : Icons.description_outlined,
                    color: colors.onSurfaceVariant,
                    size: 20,
                  ),
                  title: Text(
                    fileName(file),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    file.destination ?? context.tr('对话图片'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: waiting ? null : () => open(file),
                  trailing: waiting
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : fileMenu(file),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
