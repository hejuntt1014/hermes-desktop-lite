import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'mobile_clipboard.dart';
import 'mobile_shortcuts.dart';
import 'conversation_files_view.dart';
import 'gateway.dart' show FileTransferControl;
import 'transcript_navigation.dart';
import 'workspace.dart';
import 'mobile_themes.dart';
import 'mobile_settings.dart';
import 'split_pane.dart';
import 'workspace_files.dart';

enum WorkspaceSection { files, review, conversationFiles }

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    required this.scope,
    this.section = WorkspaceSection.files,
    this.filesOnly = false,
    this.browserPosition,
    this.onBrowserPosition,
    this.reviewPosition,
    this.onReviewPosition,
    this.title = '会话',
    this.onDirectory,
    this.allowDefault = false,
    this.onRevealMessage,
    this.onReference,
  });
  final WorkspaceScope scope;
  final WorkspaceSection section;
  final bool filesOnly;
  final WorkspaceBrowserPosition? browserPosition;
  final ValueChanged<WorkspaceBrowserPosition>? onBrowserPosition;
  final WorkspaceReviewPosition? reviewPosition;
  final ValueChanged<WorkspaceReviewPosition>? onReviewPosition;
  final String title;
  final Future<String?> Function(String? directory)? onDirectory;
  final bool allowDefault;
  final ValueChanged<MessageAddress>? onRevealMessage;
  final ValueChanged<WorkspaceEntry>? onReference;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  late WorkspaceScope scope = widget.scope;
  bool changing = false;

  Future<void> pickDirectory() async {
    final choice = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (page) => Scaffold(
          appBar: AppBar(title: Text(context.tr('选择工作目录'))),
          body: SafeArea(
            top: false,
            child: WorkspaceFiles(
              scope: scope,
              onDirectory: (path) => Navigator.pop(page, path),
            ),
          ),
        ),
      ),
    );
    if (mounted && choice != null) await changeDirectory(choice);
  }

  Future<void> changeDirectory(String? target) async {
    final change = widget.onDirectory;
    if (changing || change == null) return;
    setState(() => changing = true);
    try {
      final cwd = await change(target);
      if (mounted) {
        setState(
          () => scope = WorkspaceScope(
            scope.gateway,
            scope.profile,
            session: scope.session,
            cwd: cwd,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr(error.toString()))));
      }
    } finally {
      if (mounted) setState(() => changing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = scope.session == null
        ? null
        : ConversationFiles(
            scope: scope,
            title: widget.title,
            useWorkspaceDefault: !widget.filesOnly,
            onRevealMessage: widget.onRevealMessage,
            onReference: widget.onReference,
          );
    if (widget.filesOnly && files != null) {
      return CallbackShortcuts(
        bindings: MobileShortcut.bind({
          MobileShortcut.dismiss: () => Navigator.of(context).maybePop(),
          MobileShortcut.workspace: () => Navigator.of(context).maybePop(),
        }),
        child: Focus(
          autofocus: true,
          skipTraversal: true,
          child: Scaffold(
            appBar: AppBar(title: Text(context.tr('会话文件'))),
            body: SafeArea(top: false, child: files),
          ),
        ),
      );
    }
    return workspaceTabs(files);
  }

  Widget workspaceTabs(ConversationFiles? files) => DefaultTabController(
    length: scope.session == null ? 2 : 3,
    initialIndex:
        scope.session == null &&
            widget.section == WorkspaceSection.conversationFiles
        ? WorkspaceSection.files.index
        : widget.section.index,
    child: Builder(
      builder: (context) {
        void close() => Navigator.of(context).maybePop();
        return CallbackShortcuts(
          bindings: MobileShortcut.bind({
            MobileShortcut.dismiss: close,
            MobileShortcut.workspace: close,
            MobileShortcut.review: () {
              final tabs = DefaultTabController.of(context);
              if (tabs.index == WorkspaceSection.review.index) {
                close();
              } else {
                tabs.animateTo(WorkspaceSection.review.index);
              }
            },
          }),
          child: Focus(
            autofocus: true,
            skipTraversal: true,
            child: Scaffold(
              appBar: AppBar(
                title: Text(context.tr('工作区')),
                actions: [
                  if (widget.onDirectory != null)
                    if (changing)
                      const Padding(
                        padding: EdgeInsets.all(15),
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else ...[
                      if (widget.allowDefault && scope.cwd != null)
                        IconButton(
                          tooltip: context.tr('使用档案默认目录'),
                          onPressed: () => changeDirectory(null),
                          icon: const Icon(Icons.restore_rounded, size: 20),
                        ),
                      IconButton(
                        tooltip: context.tr('更改工作目录'),
                        onPressed: pickDirectory,
                        icon: const Icon(
                          Icons.drive_file_move_outline,
                          size: 22,
                        ),
                      ),
                    ],
                ],
                bottom: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  indicatorSize: TabBarIndicatorSize.label,
                  tabs: [
                    Tab(text: context.tr('文件')),
                    Tab(text: context.tr('改动审查')),
                    if (scope.session != null) Tab(text: context.tr('会话文件')),
                  ],
                ),
              ),
              body: SafeArea(
                top: false,
                child: TabBarView(
                  key: ValueKey(scope.cwd),
                  children: [
                    WorkspaceFiles(
                      scope: scope,
                      position: widget.browserPosition,
                      onPosition: widget.onBrowserPosition,
                      onReference: widget.onReference,
                    ),
                    _WorkspaceReview(
                      scope: scope,
                      position: widget.reviewPosition,
                      onPosition: widget.onReviewPosition,
                    ),
                    if (files != null) files,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _WorkspaceReview extends StatefulWidget {
  const _WorkspaceReview({required this.scope, this.position, this.onPosition});
  final WorkspaceScope scope;
  final WorkspaceReviewPosition? position;
  final ValueChanged<WorkspaceReviewPosition>? onPosition;

  @override
  State<_WorkspaceReview> createState() => _WorkspaceReviewState();
}

class _WorkspaceReviewState extends State<_WorkspaceReview>
    with AutomaticKeepAliveClientMixin {
  ReviewMode mode = ReviewMode.working;
  final filter = TextEditingController();
  bool filtering = false;
  ReviewListing? result;
  String? selectedPath;
  String? directory, repository;
  String? error;
  bool loading = true;
  int request = 0;
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    filter.dispose();
    super.dispose();
  }

  Future<void> load({ReviewMode? nextMode}) async {
    final previousDirectory = directory;
    final previousRepository = repository;
    final round = ++request;
    setState(() {
      loading = true;
      error = null;
      if (nextMode != null && nextMode != mode) {
        result = null;
        mode = nextMode;
      }
    });
    try {
      final cwd = await widget.scope.root();
      if (!mounted || round != request) return;
      final position = widget.position;
      var restore =
          previousDirectory == null &&
              nextMode == null &&
              position?.directory == cwd &&
              position?.session == widget.scope.session
          ? position
          : null;
      final resetDirectory =
          previousDirectory != null && previousDirectory != cwd;
      final targetMode =
          nextMode ??
          restore?.mode ??
          (resetDirectory ? ReviewMode.working : mode);
      var next = await ReviewListing.load(
        widget.scope,
        targetMode,
        directory: cwd,
      );
      if (!mounted || round != request) return;
      final resetRepository =
          restore != null && restore.repository != next.root ||
          previousDirectory != null && previousRepository != next.root;
      if (resetRepository) {
        restore = null;
        if (nextMode == null && targetMode != ReviewMode.working) {
          next = await ReviewListing.load(
            widget.scope,
            ReviewMode.working,
            directory: cwd,
          );
        }
      }
      if (mounted && round == request) {
        setState(() {
          directory = cwd;
          repository = next.root;
          result = next;
          mode = next.mode;
          if (restore case final saved?) {
            filter.text = saved.query;
            filtering = saved.query.isNotEmpty;
            selectedPath = saved.file;
          } else if (resetDirectory || resetRepository) {
            filter.clear();
            filtering = false;
            selectedPath = null;
          }
          if (!next.files.any((file) => file.path == selectedPath)) {
            selectedPath = null;
          }
        });
      }
    } catch (e) {
      if (mounted && round == request) setState(() => error = e.toString());
    } finally {
      if (mounted && round == request) {
        setState(() => loading = false);
        savePosition();
      }
    }
  }

  void savePosition() {
    final cwd = directory;
    final root = repository;
    if (cwd == null || root == null || loading || error != null) return;
    widget.onPosition?.call(
      WorkspaceReviewPosition(
        session: widget.scope.session,
        directory: cwd,
        repository: root,
        mode: mode,
        query: filter.text,
        file: selectedPath,
      ),
    );
  }

  void toggleFilter() {
    setState(() {
      filtering = !filtering;
      if (!filtering) filter.clear();
    });
    savePosition();
  }

  List<ChangedFile> visibleFiles(ReviewListing review) {
    final query = filter.text.trim().toLowerCase();
    return query.isEmpty
        ? review.files
        : review.files
              .where((file) => file.path.toLowerCase().contains(query))
              .toList();
  }

  void selectDiff(String? path) {
    setState(() => selectedPath = path);
    savePosition();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = Theme.of(context).colorScheme;
    final review = result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(17, 12, 12, 8),
          child: Row(
            children: [
              Semantics(
                container: true,
                child: PopupMenuButton<ReviewMode>(
                  tooltip: context.tr('选择改动范围'),
                  initialValue: mode,
                  onSelected: (value) {
                    if (value != mode) load(nextMode: value);
                  },
                  itemBuilder: (_) => [
                    for (final option in ReviewMode.values)
                      CheckedPopupMenuItem(
                        checked: option == mode,
                        value: option,
                        child: Text(context.tr(option.label)),
                      ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 9, 10),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Text(
                          context.tr(mode.label),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.expand_more_rounded, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
              const Spacer(),
              if (review?.files.isNotEmpty == true || filtering)
                IconButton(
                  tooltip: context.tr(filtering ? '关闭筛选' : '筛选改动文件'),
                  onPressed: toggleFilter,
                  icon: Icon(
                    filtering ? Icons.close_rounded : Icons.search_rounded,
                    size: 20,
                  ),
                ),
              IconButton(
                tooltip: context.tr('刷新改动'),
                onPressed: loading ? null : load,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
        ),
        if (review?.root case final root?)
          Padding(
            padding: const EdgeInsets.fromLTRB(21, 1, 21, 10),
            child: Text(
              root,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ),
        if (filtering)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 9),
            child: TextField(
              controller: filter,
              onChanged: (_) {
                setState(() {});
                savePosition();
              },
              decoration: InputDecoration(
                hintText: context.tr('筛选改动文件'),
                prefixIcon: const Icon(Icons.search_rounded, size: 19),
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
              onPressed: load,
              child: Text(context.tr('重试')),
            ),
          ),
        if (review != null)
          Expanded(
            child: LayoutBuilder(
              builder: (context, bounds) {
                const role = SplitPaneRole.files;
                final inline =
                    review.files.isNotEmpty && role.fits(bounds.maxWidth);
                final list = buildFiles(review, inline: inline);
                if (!inline) return list;
                final selected = review.files
                    .where((file) => file.path == selectedPath)
                    .firstOrNull;
                final preferences = MobileAppearance.shared;
                return ListenableBuilder(
                  listenable: preferences,
                  builder: (_, _) => ResizableSplitPane(
                    role: role,
                    preferredWidth: preferences.paneWidth(role),
                    onWidthChanged: (width) =>
                        preferences.setPaneWidth(role, width),
                    list: list,
                    content: selected == null
                        ? Center(child: Text(context.tr('选择文件查看差异')))
                        : _DiffPreview(
                            key: ValueKey((review, selected.path)),
                            scope: widget.scope,
                            review: review,
                            file: selected,
                            onClosePreview: () => selectDiff(null),
                          ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget buildFiles(ReviewListing review, {required bool inline}) {
    final colors = Theme.of(context).colorScheme;
    final files = visibleFiles(review);
    return RefreshIndicator(
      onRefresh: load,
      child: ListView.builder(
        key: PageStorageKey((review.root, review.mode)),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        itemCount: files.isEmpty ? 1 : files.length,
        itemBuilder: (context, index) {
          if (files.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(26),
              child: Center(
                child: Text(
                  context.tr(
                    review.root == null
                        ? '此工作区不是 Git 仓库'
                        : review.files.isEmpty
                        ? '此范围没有改动'
                        : '没有匹配的改动文件',
                  ),
                ),
              ),
            );
          }
          final file = files[index];
          return ListTile(
            key: ValueKey(file.path),
            selected: selectedPath == file.path,
            selectedTileColor: colors.secondaryContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 9),
            leading: Icon(
              Icons.difference_outlined,
              color: colors.onSurfaceVariant,
              size: 20,
            ),
            title: Text(
              workspaceName(file.path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                file.path,
                if (file.staged) context.tr('已暂存'),
                if (_changeLabel(file.status) case final label?)
                  context.tr(label),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _Counts(file: file),
            onTap: loading
                ? null
                : () => openDiff(review, files, index, inline: inline),
          );
        },
      ),
    );
  }

  void openDiff(
    ReviewListing review,
    List<ChangedFile> files,
    int fileIndex, {
    required bool inline,
  }) {
    selectDiff(files[fileIndex].path);
    if (inline) return;
    final scope = widget.scope;
    var index = fileIndex;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => StatefulBuilder(
          builder: (context, update) {
            void move(int step) {
              final next = index + step;
              if (next < 0 || next >= files.length) return;
              update(() => index = next);
              if (mounted && identical(result, review))
                selectDiff(files[index].path);
            }

            final file = files[index];
            return _DiffPreview(
              key: ValueKey(file.path),
              scope: scope,
              review: review,
              file: file,
              onPrevious: index > 0 ? () => move(-1) : null,
              onNext: index + 1 < files.length ? () => move(1) : null,
            );
          },
        ),
      ),
    );
  }
}

String? _changeLabel(String value) => switch (value) {
  'added' || 'A' => '新增',
  'deleted' || 'D' => '删除',
  'modified' || 'M' => '已修改',
  'renamed' || 'R' => '重命名',
  'untracked' || '?' || '??' => '未跟踪',
  _ => null,
};

Color _addInk(BuildContext context) =>
    CustomThemeTokens.read(context, ThemeColor.positive) ??
    (Theme.of(context).brightness == Brightness.dark
        ? const Color(0xff9bd7ad)
        : const Color(0xff276d42));

class _Counts extends StatelessWidget {
  const _Counts({required this.file});
  final ChangedFile file;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '+${file.added}',
        style: TextStyle(color: _addInk(context), fontSize: 12),
      ),
      const SizedBox(width: 6),
      Text(
        '−${file.removed}',
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontSize: 12,
        ),
      ),
    ],
  );
}

class _DiffPreview extends StatefulWidget {
  const _DiffPreview({
    super.key,
    required this.scope,
    required this.review,
    required this.file,
    this.onClosePreview,
    this.onPrevious,
    this.onNext,
  });
  final WorkspaceScope scope;
  final ReviewListing review;
  final ChangedFile file;
  final VoidCallback? onClosePreview;
  final VoidCallback? onPrevious, onNext;

  @override
  State<_DiffPreview> createState() => _DiffPreviewState();
}

class _DiffPreviewState extends State<_DiffPreview> {
  late Future<ReviewDiff> pending = load();
  final horizontal = ScrollController();
  final vertical = ScrollController();
  FileTransferControl? transfer;

  Future<ReviewDiff> load() {
    transfer?.cancel();
    final control = transfer = FileTransferControl();
    return widget.review.diff(widget.scope, widget.file, control: control);
  }

  @override
  void dispose() {
    transfer?.cancel();
    horizontal.dispose();
    vertical.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: pending,
    builder: (context, snapshot) {
      final diff = snapshot.data;
      final close = widget.onClosePreview;
      final toolbar = AppBar(
        primary: close == null,
        automaticallyImplyLeading: close == null,
        title: Text(
          workspaceName(widget.file.path),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (widget.onPrevious != null || widget.onNext != null) ...[
            IconButton(
              tooltip: context.tr('上一个文件'),
              onPressed: widget.onPrevious,
              icon: const Icon(Icons.chevron_left_rounded, size: 21),
            ),
            IconButton(
              tooltip: context.tr('下一个文件'),
              onPressed: widget.onNext,
              icon: const Icon(Icons.chevron_right_rounded, size: 21),
            ),
          ],
          if (diff != null && diff.raw.isNotEmpty)
            IconButton(
              tooltip: context.tr('复制差异'),
              onPressed: () => copyMobileText(context, diff.raw, '已复制差异'),
              icon: const Icon(Icons.copy_outlined, size: 19),
            ),
          if (close != null)
            IconButton(
              tooltip: context.tr('关闭预览'),
              onPressed: close,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
        ],
      );
      final body = SafeArea(
        top: false,
        child: switch (snapshot) {
          AsyncSnapshot(hasError: true) => Center(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(context.tr(snapshot.error.toString())),
                  TextButton(
                    onPressed: () => setState(() {
                      pending = load();
                    }),
                    child: Text(context.tr('重试')),
                  ),
                ],
              ),
            ),
          ),
          _ when diff == null => const Center(
            child: CircularProgressIndicator(),
          ),
          _ when diff.lines.isEmpty => Center(
            child: Text(context.tr('没有可显示的差异')),
          ),
          _ => buildDiff(diff),
        },
      );
      if (close == null) return Scaffold(appBar: toolbar, body: body);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: toolbar.preferredSize.height, child: toolbar),
          Expanded(child: body),
        ],
      );
    },
  );

  Widget buildDiff(ReviewDiff diff) {
    final colors = Theme.of(context).colorScheme;
    final scale = MediaQuery.textScalerOf(context);
    final numberWidth = math.max(36.0, scale.scale(10) * 3.6);
    final rowHeight = math.max(26.0, scale.scale(12) * 1.45 + 6);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(17, 1, 17, 9),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.file.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _Counts(file: widget.file),
            ],
          ),
        ),
        if (diff.truncated)
          Padding(
            padding: EdgeInsets.all(8),
            child: Text(context.tr('已显示前 20,000 行，可复制完整差异')),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, bounds) => Scrollbar(
              controller: vertical,
              notificationPredicate: (notice) =>
                  notice.metrics.axis == Axis.vertical,
              child: Scrollbar(
                controller: horizontal,
                child: SingleChildScrollView(
                  controller: horizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width:
                        (numberWidth * 2 +
                                14 +
                                diff.widest * scale.scale(12) * .67)
                            .clamp(bounds.maxWidth, 25000),
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: vertical,
                        itemExtent: rowHeight,
                        itemCount: diff.lines.length,
                        itemBuilder: (_, index) => _DiffRow(
                          line: diff.lines[index],
                          numberWidth: numberWidth,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.line, required this.numberWidth});
  final DiffLine line;
  final double numberWidth;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (foreground, background) = switch (line.kind) {
      DiffKind.added => (
        _addInk(context),
        _addInk(context).withValues(alpha: .09),
      ),
      DiffKind.removed => (colors.error, colors.error.withValues(alpha: .08)),
      DiffKind.header => (colors.primary, colors.surfaceContainerLow),
      DiffKind.plain => (colors.onSurface, Colors.transparent),
    };
    return ColoredBox(
      color: background,
      child: Row(
        children: [
          for (final number in [line.oldLine, line.newLine])
            SizedBox(
              width: numberWidth,
              child: Text(
                number?.toString() ?? '',
                textAlign: TextAlign.right,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 10),
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              line.text.replaceAll('\t', '    '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CustomThemeTokens.codeStyle(context).copyWith(
                fontSize: 12,
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
