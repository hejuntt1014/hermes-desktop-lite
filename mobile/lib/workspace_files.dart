import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'attachment_view.dart';
import 'document_outline.dart';
import 'gateway.dart' show GatewayError;
import 'message_content.dart';
import 'mobile_clipboard.dart';
import 'mobile_settings.dart';
import 'split_pane.dart';
import 'workspace.dart';
import 'workspace_directory.dart';
import 'workspace_document_text.dart';
import 'workbook_view.dart';

class WorkspaceFiles extends StatefulWidget {
  const WorkspaceFiles({
    super.key,
    required this.scope,
    this.position,
    this.onPosition,
    this.onDirectory,
    this.onReference,
  });
  final WorkspaceScope scope;
  final WorkspaceBrowserPosition? position;
  final ValueChanged<WorkspaceBrowserPosition>? onPosition;
  final ValueChanged<String>? onDirectory;
  final ValueChanged<WorkspaceEntry>? onReference;

  @override
  State<WorkspaceFiles> createState() => _WorkspaceFilesState();
}

class _WorkspaceFilesState extends State<WorkspaceFiles>
    with AutomaticKeepAliveClientMixin {
  final search = TextEditingController();
  final directoryScroll = ScrollController();
  List<String> trail = [];
  List<WorkspaceEntry> entries = [];
  ({WorkspaceEntry entry, String? fragment})? selection;
  String? error;
  String? directoryRoot;
  double? restoreOffset;
  double scrollOffset = 0;
  bool loading = true;
  int version = 0;
  bool get choosing => widget.onDirectory != null;
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    search.dispose();
    directoryScroll.dispose();
    super.dispose();
  }

  Future<void> load([List<String>? nextTrail]) async {
    final round = ++version;
    final target = nextTrail ?? trail;
    final saved = nextTrail == null && trail.isEmpty && !choosing
        ? widget.position
        : null;
    setState(() {
      error = null;
      loading = true;
      if (nextTrail != null) {
        search.clear();
        entries = [];
        trail = nextTrail;
        selection = null;
        restoreOffset = null;
        scrollOffset = 0;
      }
    });
    try {
      final root = directoryRoot ?? await widget.scope.root();
      if (!mounted || round != version) return;
      var restore =
          saved?.root == root && saved?.session == widget.scope.session
          ? saved
          : null;
      var paths = target.isEmpty ? restore?.trail ?? [root] : target;
      List<WorkspaceEntry> next;
      try {
        next = await widget.scope.list(paths.last);
      } on GatewayError catch (failure) {
        if (restore == null || paths.last == root || failure.status != 404) {
          rethrow;
        }
        if (!mounted || round != version) return;
        restore = null;
        paths = [root];
        next = await widget.scope.list(root);
      }
      if (!mounted || round != version) return;
      setState(() {
        directoryRoot = root;
        trail = paths;
        entries = next;
        if (restore case final savedPosition?) {
          search.text = savedPosition.query;
          restoreOffset = savedPosition.offset;
          if (savedPosition.file case final path?) {
            final file = next
                .where((entry) => !entry.directory && entry.path == path)
                .firstOrNull;
            if (file != null || parentWorkspacePath(path) != paths.last) {
              selection = (
                entry: file ?? WorkspaceEntry(workspaceName(path), path),
                fragment: savedPosition.fragment,
              );
            }
          }
        }
      });
    } catch (e) {
      if (mounted && round == version) setState(() => error = e.toString());
    } finally {
      if (mounted && round == version) {
        setState(() => loading = false);
        savePosition();
      }
    }
  }

  void savePosition() {
    final root = directoryRoot;
    final changed = widget.onPosition;
    if (changed == null ||
        root == null ||
        trail.isEmpty ||
        loading ||
        error != null) {
      return;
    }
    changed(
      WorkspaceBrowserPosition(
        session: widget.scope.session,
        root: root,
        trail: List.of(trail),
        query: search.text,
        offset: restoreOffset ?? scrollOffset,
        file: selection?.entry.path,
        fragment: selection?.fragment,
      ),
    );
  }

  void restoreDirectoryScroll() {
    if (restoreOffset == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final offset = restoreOffset;
      if (!mounted || offset == null || directoryScroll.positions.length != 1) {
        return;
      }
      final position = directoryScroll.position;
      if (!position.hasContentDimensions) return;
      restoreOffset = null;
      scrollOffset = offset
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      directoryScroll.jumpTo(scrollOffset);
      savePosition();
    });
  }

  Future<void> enterPath() async {
    var typed = trail.lastOrNull ?? '';
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.tr('转到路径')),
        content: TextFormField(
          autofocus: true,
          initialValue: typed,
          decoration: InputDecoration(labelText: context.tr('网关上的目录')),
          onChanged: (value) => typed = value,
          onFieldSubmitted: (value) => Navigator.pop(dialog, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(context.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, typed.trim()),
            child: Text(context.tr('打开')),
          ),
        ],
      ),
    );
    if (mounted && value?.isNotEmpty == true) await load([value!]);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    restoreDirectoryScroll();
    const role = SplitPaneRole.files;
    return LayoutBuilder(
      builder: (context, bounds) {
        final inline = !choosing && role.fits(bounds.maxWidth);
        final list = buildList(context, inline: inline);
        if (!inline) return list;
        final file = selection;
        final preferences = MobileAppearance.shared;
        final preview = file == null
            ? Center(
                child: Text(
                  context.tr('选择文件预览'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            : _WorkspaceFile(
                key: ValueKey((file.entry.path, file.fragment)),
                scope: widget.scope,
                entry: file.entry,
                fragment: file.fragment,
                onReference: widget.onReference,
                onClosePreview: () {
                  setState(() => selection = null);
                  savePosition();
                },
                onOpenPreview: (entry, fragment) {
                  if (entry.directory) {
                    load([...trail, entry.path]);
                  } else {
                    selectFile(entry, fragment);
                  }
                },
              );
        return ListenableBuilder(
          listenable: preferences,
          builder: (_, _) => ResizableSplitPane(
            role: role,
            preferredWidth: preferences.paneWidth(role),
            onWidthChanged: (width) => preferences.setPaneWidth(role, width),
            list: list,
            content: preview,
          ),
        );
      },
    );
  }

  void selectFile(WorkspaceEntry file, String? fragment) {
    setState(() => selection = (entry: file, fragment: fragment));
    savePosition();
  }

  void openEntry(WorkspaceEntry entry, {required bool inline}) {
    if (entry.directory) {
      load([...trail, entry.path]);
      return;
    }
    selectFile(entry, null);
    if (!inline) {
      openWorkspaceFile(
        context,
        widget.scope,
        entry,
        onReference: widget.onReference,
      );
    }
  }

  Widget buildList(BuildContext context, {required bool inline}) {
    final colors = Theme.of(context).colorScheme;
    final query = search.text.trim().toLowerCase();
    final shown = entries
        .where(
          (e) =>
              (!choosing || e.directory) &&
              e.name.toLowerCase().contains(query),
        )
        .toList();
    final parent = choosing && trail.length == 1
        ? parentWorkspacePath(trail.first)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          child: Row(
            children: [
              IconButton(
                tooltip: context.tr('上一级目录'),
                onPressed: trail.length > 1
                    ? () => load(trail.sublist(0, trail.length - 1))
                    : parent != null
                    ? () => load([parent])
                    : null,
                icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    children: [
                      for (var index = 0; index < trail.length; index++) ...[
                        if (index != 0)
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 14,
                            color: colors.onSurfaceVariant,
                          ),
                        if (index == trail.length - 1)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              workspaceName(trail[index]),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        else
                          TextButton(
                            onPressed: () => load(trail.sublist(0, index + 1)),
                            child: Text(workspaceName(trail[index])),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              if (choosing)
                IconButton(
                  tooltip: context.tr('转到路径'),
                  onPressed: enterPath,
                  icon: const Icon(Icons.route_outlined, size: 20),
                ),
              if (widget.onReference case final reference?)
                IconButton(
                  tooltip: context.tr('引用此目录'),
                  icon: const Icon(Icons.add_comment_outlined, size: 20),
                  onPressed: trail.isEmpty || loading || error != null
                      ? null
                      : () => reference(
                          WorkspaceEntry(
                            workspaceName(trail.last),
                            trail.last,
                            directory: true,
                          ),
                        ),
                ),
              IconButton(
                tooltip: context.tr('刷新目录'),
                icon: const Icon(Icons.refresh_rounded, size: 20),
                onPressed: loading ? null : () => load(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 9),
          child: TextField(
            controller: search,
            onChanged: (_) {
              setState(() {});
              savePosition();
            },
            decoration: InputDecoration(
              hintText: choosing ? context.tr('筛选子目录') : context.tr('搜索当前目录'),
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: context.tr('清空搜索'),
                      onPressed: () {
                        setState(search.clear);
                        savePosition();
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
            ),
          ),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          ListTile(
            title: Text(
              context.tr(error!),
              style: TextStyle(color: colors.error),
            ),
            trailing: TextButton(
              onPressed: () => load(),
              child: Text(context.tr('重试')),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: load,
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (event) {
                if (event.depth == 0) {
                  scrollOffset = event.metrics.pixels;
                  savePosition();
                }
                return false;
              },
              child: ListView.builder(
                controller: directoryScroll,
                key: PageStorageKey((
                  widget.scope.profile,
                  widget.scope.session,
                  trail.lastOrNull,
                )),
                padding: const EdgeInsets.fromLTRB(15, 0, 15, 16),
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: shown.isEmpty ? 1 : shown.length,
                itemBuilder: (context, index) {
                  if (shown.isEmpty) {
                    if (loading || error != null)
                      return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          choosing
                              ? query.isEmpty
                                    ? context.tr('没有子目录')
                                    : context.tr('没有匹配的目录')
                              : query.isEmpty
                              ? context.tr('目录为空')
                              : context.tr('没有匹配的文件'),
                        ),
                      ),
                    );
                  }
                  final entry = shown[index];
                  return ListTile(
                    selected: selection?.entry.path == entry.path,
                    selectedTileColor: colors.secondaryContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 11),
                    minTileHeight: 48,
                    leading: Icon(
                      entry.directory
                          ? Icons.folder_outlined
                          : workspaceImage(entry.path)
                          ? Icons.image_outlined
                          : Icons.description_outlined,
                      size: 21,
                      color: entry.directory
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                    title: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: inline && !entry.directory
                        ? null
                        : Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: colors.onSurfaceVariant,
                          ),
                    onTap: () => openEntry(entry, inline: inline),
                  );
                },
              ),
            ),
          ),
        ),
        if (choosing)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
            child: FilledButton(
              onPressed: loading || error != null || trail.isEmpty
                  ? null
                  : () => widget.onDirectory!(trail.last),
              child: Text(context.tr('使用此目录')),
            ),
          ),
      ],
    );
  }
}

Future<void> openWorkspaceFile(
  BuildContext context,
  WorkspaceScope scope,
  WorkspaceEntry entry, {
  String? fragment,
  ValueChanged<WorkspaceEntry>? onReference,
}) async {
  final selected = await Navigator.push<WorkspaceEntry>(
    context,
    MaterialPageRoute(
      builder: (page) {
        final reference = onReference == null
            ? null
            : (WorkspaceEntry selection) => Navigator.pop(page, selection);
        return entry.directory
            ? Scaffold(
                appBar: AppBar(title: Text(entry.name)),
                body: SafeArea(
                  top: false,
                  child: WorkspaceFiles(
                    scope: WorkspaceScope(
                      scope.gateway,
                      scope.profile,
                      session: scope.session,
                      cwd: entry.path,
                    ),
                    onReference: reference,
                  ),
                ),
              )
            : _WorkspaceFile(
                scope: scope,
                entry: entry,
                fragment: fragment,
                onReference: reference,
              );
      },
    ),
  );
  if (context.mounted && selected != null) onReference?.call(selected);
}

class _WorkspaceFile extends StatefulWidget {
  const _WorkspaceFile({
    super.key,
    required this.scope,
    required this.entry,
    this.fragment,
    this.onClosePreview,
    this.onOpenPreview,
    this.onReference,
  });
  final WorkspaceScope scope;
  final WorkspaceEntry entry;
  final String? fragment;
  final VoidCallback? onClosePreview;
  final void Function(WorkspaceEntry, String?)? onOpenPreview;
  final ValueChanged<WorkspaceEntry>? onReference;

  @override
  State<_WorkspaceFile> createState() => _WorkspaceFileState();
}

class _WorkspaceFileState extends State<_WorkspaceFile> {
  final outline = DocumentOutline();
  late final image = workspaceImage(widget.entry.path);
  late final workbook = widget.entry.path.toLowerCase().endsWith('.xlsx');
  late Future<WorkspaceText>? text = image || workbook
      ? null
      : widget.scope.readText(widget.entry.path);
  bool source = false, sharing = false, findingText = false;

  @override
  void dispose() {
    outline.dispose();
    super.dispose();
  }

  Future<void> openOutline() async {
    final headings = outline.headings;
    if (headings.isEmpty) return;
    final target = await showModalBottomSheet<DocumentHeading>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => FractionallySizedBox(
        heightFactor: .59,
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 2, 22, 11),
                child: Semantics(
                  header: true,
                  child: Text(
                    sheet.tr('文档目录'),
                    style: Theme.of(sheet).textTheme.titleLarge,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: headings.length,
                  itemBuilder: (context, index) {
                    final heading = headings[index];
                    return ListTile(
                      minTileHeight: 46,
                      contentPadding: EdgeInsetsDirectional.only(
                        start: 22.0 + (heading.level - 1) * 11,
                        end: 22,
                      ),
                      title: Text(
                        heading.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: heading.level <= 2
                            ? const TextStyle(fontWeight: FontWeight.w600)
                            : null,
                      ),
                      onTap: () => Navigator.pop(sheet, heading),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && target != null) await outline.reveal(target);
  }

  Future<void> save({bool share = false}) async {
    if (sharing) return;
    final scope = widget.scope;
    final size = MediaQuery.sizeOf(context);
    setState(() => sharing = true);
    try {
      if (share) {
        await shareRemoteFile(
          context,
          scope.gateway,
          path: widget.entry.path,
          profile: scope.profile,
          session: scope.session,
          origin: Rect.fromLTWH(size.width / 2, size.height / 2, 1, 1),
          stillOpen: () => mounted,
        );
      } else {
        final saved = await saveRemoteFile(
          context,
          scope.gateway,
          path: widget.entry.path,
          profile: scope.profile,
          session: scope.session,
          stillOpen: () => mounted,
        );
        if (saved && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(context.tr('文件已保存'))));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr(e.toString()))));
      }
    } finally {
      if (mounted) setState(() => sharing = false);
    }
  }

  String? get documentDirectory {
    final current = widget.entry.path;
    final slash = current.lastIndexOf('/');
    final backslash = current.lastIndexOf('\\');
    final end = slash > backslash ? slash : backslash;
    return end < 0 ? widget.scope.cwd : current.substring(0, end + 1);
  }

  String? resolve(Uri uri) =>
      workspaceDocumentPath(uri, baseDirectory: documentDirectory);

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final scope = widget.scope;
    final inline = widget.onClosePreview != null;
    final toolbar = AppBar(
      primary: !inline,
      automaticallyImplyLeading: !inline,
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (widget.onReference case final reference?)
          IconButton(
            tooltip: context.tr('引用到草稿'),
            onPressed: sharing ? null : () => reference(entry),
            icon: const Icon(Icons.add_comment_outlined, size: 20),
          ),
        IconButton(
          tooltip: context.tr('复制远程路径'),
          onPressed: () => copyMobileText(context, entry.path, '已复制远程路径'),
          icon: const Icon(Icons.link_rounded, size: 20),
        ),
        if (sharing)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(15),
              child: SizedBox.square(
                dimension: 19,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          IconButton(
            tooltip: context.tr('下载文件'),
            onPressed: save,
            icon: const Icon(Icons.download_outlined),
          ),
        if (!sharing)
          IconButton(
            tooltip: context.tr('分享文件'),
            onPressed: () => save(share: true),
            icon: const Icon(Icons.ios_share_outlined),
          ),
        if (widget.onClosePreview case final close?)
          IconButton(
            tooltip: context.tr('关闭预览'),
            onPressed: close,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
      ],
    );
    final body = SafeArea(
      top: false,
      child: workbook
          ? WorkbookPreview(scope: scope, path: entry.path)
          : image
          ? SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ChatImage(
                  path: entry.path,
                  gateway: scope.gateway,
                  profile: scope.profile,
                  session: scope.session,
                ),
              ),
            )
          : FutureBuilder(
              future: text,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            context.tr(snapshot.error.toString()),
                            textAlign: TextAlign.center,
                          ),
                          TextButton(
                            onPressed: () => setState(() {
                              text = scope.readText(entry.path);
                            }),
                            child: Text(context.tr('重新读取')),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final file = snapshot.data;
                if (file == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (file.binary) {
                  return Center(
                    child: OutlinedButton.icon(
                      onPressed: sharing ? null : save,
                      icon: const Icon(Icons.download_outlined),
                      label: Text(context.tr('下载文件查看')),
                    ),
                  );
                }
                return buildText(file);
              },
            ),
    );
    if (!inline) return Scaffold(appBar: toolbar, body: body);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: toolbar.preferredSize.height, child: toolbar),
        Expanded(child: body),
      ],
    );
  }

  Widget buildText(WorkspaceText file) {
    final colors = Theme.of(context).colorScheme;
    final scope = widget.scope;
    return Column(
      children: [
        if (!findingText)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 3, 14, 6),
            child: Row(
              children: [
                if (file.markdown)
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: false,
                        label: Text(context.tr('预览')),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text(context.tr('源文件')),
                      ),
                    ],
                    selected: {source},
                    onSelectionChanged: (value) =>
                        setState(() => source = value.first),
                  ),
                const Spacer(),
                if (file.markdown && !source)
                  ListenableBuilder(
                    listenable: outline,
                    builder: (context, _) => outline.hasHeadings
                        ? IconButton(
                            tooltip: context.tr('文档目录'),
                            onPressed: openOutline,
                            icon: const Icon(
                              Icons.format_list_bulleted_rounded,
                              size: 20,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                IconButton(
                  tooltip: context.tr(
                    file.markdown && !source ? '在源文件中查找' : '在文件中查找',
                  ),
                  onPressed: () => setState(() => findingText = true),
                  icon: const Icon(Icons.search_rounded, size: 20),
                ),
                IconButton(
                  tooltip: context.tr(file.truncated ? '复制预览内容' : '复制文件内容'),
                  onPressed: () => copyMobileText(
                    context,
                    file.text,
                    file.truncated ? '已复制预览内容' : '已复制文件内容',
                  ),
                  icon: const Icon(Icons.copy_outlined, size: 19),
                ),
              ],
            ),
          ),
        if (file.truncated)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
            child: Text(
              context.tr('仅预览文件开头，可下载查看全文'),
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ),
        Expanded(
          child: file.markdown && !source && !findingText
              ? SelectionArea(
                  child: MessageContent(
                    body: file.text,
                    gateway: scope.gateway,
                    profile: scope.profile,
                    session: scope.session,
                    documentPath: resolve,
                    baseDirectory: documentDirectory,
                    scrollDocument: true,
                    initialFragment: widget.fragment,
                    documentOutline: outline,
                    onOpenDocument: (path, fragment) {
                      final target = WorkspaceEntry(
                        workspaceName(path),
                        path,
                        directory: path.endsWith('/') || path.endsWith('\\'),
                      );
                      if (widget.onOpenPreview case final inline?) {
                        inline(target, fragment);
                      } else {
                        openWorkspaceFile(
                          context,
                          scope,
                          target,
                          fragment: fragment,
                          onReference: widget.onReference,
                        );
                      }
                    },
                  ),
                )
              : WorkspaceDocumentText(
                  text: file.text,
                  storageKey: PageStorageKey((outline, 'source')),
                  finding: findingText,
                  onCloseFind: () => setState(() => findingText = false),
                ),
        ),
      ],
    );
  }
}
