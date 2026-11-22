import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'attachment_view.dart' show attachedPath;
import 'background_notice.dart';
import 'gateway.dart';
import 'history.dart';
import 'message_bookmarks.dart';
import 'message_content.dart' show messageGallery;
import 'mobile_locale.dart';
import 'mobile_shortcuts.dart';
import 'transcript_navigation.dart';
import 'transcript_occurrences.dart';
import 'transcript_reader.dart';
import 'transcript_match_view.dart';
import 'transcript_search.dart';
import 'workspace.dart' show workspaceName;

enum _ExplorerTab { search, timeline, bookmarks }

String turnMessagePreview(String body) {
  final lines = body.split('\n');
  final caption = bookmarkExcerpt(
    lines
        .where((line) {
          final text = line.trim();
          return !text.startsWith('@image:') &&
              !text.startsWith('MEDIA:') &&
              !text.startsWith('data:image/') &&
              !text.startsWith('![') &&
              !const {'[screenshot]', '[image]', '[图片]'}.contains(text) &&
              attachedPath(text) == null;
        })
        .join(' '),
  );
  if (caption.isNotEmpty) return caption;
  final image = messageGallery(body, user: true).firstOrNull;
  if (image?.alt case final String alt when alt.trim().isNotEmpty) {
    return bookmarkExcerpt(alt);
  }
  if (image?.key case final String path when !path.startsWith('data:')) {
    return bookmarkExcerpt(workspaceName(path));
  }
  return lines
          .map((line) => attachedPath(line.trim()))
          .nonNulls
          .map((path) => bookmarkExcerpt(workspaceName(path)))
          .firstOrNull ??
      '';
}

class TranscriptExplorer extends StatefulWidget {
  const TranscriptExplorer({
    super.key,
    required this.gateway,
    this.profile,
    this.session,
    this.title,
    this.focusSearch = false,
    this.initialTurns = false,
    this.returnSelection = false,
    this.searchState,
  });

  final Gateway gateway;
  final String? profile, session, title;
  final bool focusSearch, initialTurns, returnSelection;
  final TranscriptSearch? searchState;

  @override
  State<TranscriptExplorer> createState() => _TranscriptExplorerState();
}

class _TranscriptExplorerState extends State<TranscriptExplorer> {
  late final field = TextEditingController(text: searchState?.query);
  final shortcutFocus = FocusNode(debugLabel: 'Transcript shortcuts');
  final searchFocus = FocusNode();
  late final searchScroll = ScrollController(
    keepScrollOffset: false,
    initialScrollOffset: searchState?.scrollOffset ?? 0,
  );
  final selectedTile = GlobalKey();
  final historyResults = GlobalKey();
  int? get selectedMatch => searchState?.selectedMatch;
  set selectedMatch(int? index) => searchState?.selectedMatch = index;
  late final TranscriptNavigation? navigation = widget.session == null
      ? null
      : TranscriptNavigation(widget.gateway, widget.profile!, widget.session!);
  late final TranscriptSearch? searchState =
      widget.searchState ??
      (navigation == null ? null : TranscriptSearch(navigation!));
  late final _ExplorerTab initial = widget.session == null
      ? _ExplorerTab.bookmarks
      : widget.initialTurns
      ? _ExplorerTab.timeline
      : _ExplorerTab.search;
  late _ExplorerTab tab = initial;
  bool timelineLoading = false, bookmarksLoading = false;
  String? timelineError, bookmarksError;
  bool get searching => searchState?.searching == true;
  String? get searchError => searchState?.error;
  List<TranscriptMatch> get matches => searchState?.matches ?? const [];
  final prompts = <({MessageAddress address, String preview})>[];
  List<MessageBookmark> bookmarks = [];
  int? nextPrompt;
  bool timelineStarted = false;
  bool? olderTimelineAvailable;
  StreamIterator<({Json row, int tailOffset})>? legacyTimeline;

  @override
  void initState() {
    super.initState();
    searchScroll.addListener(rememberSearchOffset);
    searchState?.addListener(updateSearch);
    if (initial == _ExplorerTab.search) searchState?.show(this);
    if (initial == _ExplorerTab.bookmarks) loadBookmarks();
    if (initial == _ExplorerTab.timeline) loadTimeline();
  }

  @override
  void dispose() {
    searchState?.removeListener(updateSearch);
    searchState?.hide(this);
    if (widget.searchState == null) searchState?.dispose();
    unawaited(legacyTimeline?.cancel());
    field.dispose();
    searchFocus.dispose();
    shortcutFocus.dispose();
    searchScroll.dispose();
    super.dispose();
  }

  void updateSearch() {
    if (mounted) setState(() {});
  }

  void search(String text) {
    if (searchScroll.hasClients) searchScroll.jumpTo(0);
    searchState?.setQuery(text);
  }

  void rememberSearchOffset() {
    if (searchScroll.hasClients) {
      searchState?.scrollOffset = searchScroll.offset;
    }
  }

  Future<void> loadTimeline() async {
    if (timelineLoading) return;
    setState(() {
      timelineLoading = true;
      timelineError = null;
    });
    try {
      if (olderTimelineAvailable == null) {
        try {
          final page = await navigation!.timeline(nextPrompt);
          if (!mounted) return;
          setState(() {
            prompts.addAll(
              page.items.map((item) {
                final row = historyRowId(item)!;
                return (
                  address: MessageAddress(row, promptId: row),
                  preview: item['preview']?.toString() ?? '用户消息',
                );
              }),
            );
            nextPrompt = page.next;
            timelineStarted = true;
          });
          return;
        } on GatewayError catch (e) {
          if (nextPrompt != null || !{404, 405, 501}.contains(e.status)) {
            rethrow;
          }
          olderTimelineAvailable = true;
          legacyTimeline = StreamIterator(navigation!.scan());
        }
      }
      final iterator = legacyTimeline!;
      final recent = <({MessageAddress address, String preview})>[];
      var read = 0;
      // One tap loads a bounded slice even if tool output dominates the history.
      while (mounted && read < 480 && recent.length < 60) {
        if (!await iterator.moveNext()) {
          olderTimelineAvailable = false;
          break;
        }
        read++;
        final item = iterator.current;
        final row = historyRowId(item.row);
        if (item.row['role'] != 'user' ||
            row == null ||
            transcriptText(item.row).isEmpty ||
            BackgroundNotice.isHistoryNotice(item.row)) {
          continue;
        }
        recent.add((
          address: MessageAddress(
            row,
            promptId: row,
            tailOffset: item.tailOffset,
          ),
          preview: turnMessagePreview(transcriptText(item.row)),
        ));
      }
      if (!mounted) return;
      setState(() {
        prompts.addAll(recent);
        timelineStarted = true;
      });
    } catch (e) {
      if (mounted) setState(() => timelineError = e.toString());
    } finally {
      if (mounted) setState(() => timelineLoading = false);
    }
  }

  Future<void> loadBookmarks() async {
    setState(() {
      bookmarksLoading = true;
      bookmarksError = null;
    });
    try {
      final saved = await MessageBookmarks.forGateway(widget.gateway).read();
      if (!mounted) return;
      setState(
        () => bookmarks = saved
            .where(
              (item) =>
                  widget.session == null ||
                  (item.session == widget.session &&
                      item.profile == widget.profile),
            )
            .toList(),
      );
    } catch (e) {
      if (mounted) setState(() => bookmarksError = e.toString());
    } finally {
      if (mounted) setState(() => bookmarksLoading = false);
    }
  }

  void switchTo(_ExplorerTab target) {
    if (target == tab) return;
    if (tab == _ExplorerTab.search) {
      rememberSearchOffset();
      searchState?.hide(this);
    }
    shortcutFocus.requestFocus();
    setState(() => tab = target);
    if (target == _ExplorerTab.search) searchState?.show(this);
    if (target == _ExplorerTab.timeline && !timelineStarted) loadTimeline();
    if (target == _ExplorerTab.bookmarks) loadBookmarks();
  }

  void moveMatch(int step) {
    if (matches.isEmpty) return;
    if (step > 0 &&
        selectedMatch == matches.length - 1 &&
        searchState?.hasMore == true) {
      searchState?.loadMore();
      return;
    }
    final next = switch (selectedMatch) {
      final index? => (index + step) % matches.length,
      _ => step > 0 ? 0 : matches.length - 1,
    };
    setState(() => selectedMatch = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !searchScroll.hasClients || selectedMatch != next) return;
      if (selectedTile.currentContext case final target?) {
        Scrollable.ensureVisible(target);
      } else if (next == 0 || next == matches.length - 1) {
        searchScroll.jumpTo(
          next == 0
              ? searchScroll.position.minScrollExtent
              : searchScroll.position.maxScrollExtent,
        );
      }
    });
  }

  void openMatch() {
    if (matches.isEmpty) return;
    final index = selectedMatch ?? 0;
    setState(() => selectedMatch = index);
    final hit = matches[index];
    unawaited(readMessage(hit.address, match: hit.preview));
  }

  Future<void> openOccurrences(TranscriptMatch hit) async {
    final state = searchState;
    if (state == null || state.query.isEmpty) return;
    final query = state.query;
    rememberSearchOffset();
    searchFocus.unfocus();
    state.hide(this);
    final excerpt = await chooseTranscriptOccurrence(
      context,
      navigation: state.navigation,
      address: hit.address,
      query: query,
    );
    if (!mounted) return;
    if (excerpt != null && query == state.query) {
      final index = matches.indexWhere(
        (row) => row.address.rowId == hit.address.rowId,
      );
      if (index >= 0) selectedMatch = index;
      await readMessage(hit.address, match: excerpt);
      if (widget.returnSelection) return;
    }
    if (mounted && tab == _ExplorerTab.search) state.show(this);
  }

  Future<void> readMessage(
    MessageAddress address, {
    MessageBookmark? bookmark,
    TranscriptMatchExcerpt? match,
  }) async {
    final target = TranscriptTarget(
      bookmark?.profile ?? widget.profile!,
      bookmark?.session ?? widget.session!,
      bookmark?.title ?? widget.title ?? context.tr('会话'),
      address,
      match: match,
    );
    if (widget.returnSelection) {
      rememberSearchOffset();
      searchState?.hide(this);
      Navigator.of(context).pop(target);
      return;
    }
    shortcutFocus.requestFocus();
    await readAround(
      context,
      gateway: widget.gateway,
      profile: target.profile,
      session: target.session,
      title: target.title,
      address: target.address,
      match: target.match,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final searchKeys =
        tab == _ExplorerTab.search &&
        (!field.value.isComposingRangeValid ||
            field.value.composing.isCollapsed);
    return CallbackShortcuts(
      bindings: MobileShortcut.bind({
        MobileShortcut.dismiss: () => Navigator.of(context).maybePop(),
        if (navigation != null)
          MobileShortcut.find: () {
            switchTo(_ExplorerTab.search);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted &&
                  tab == _ExplorerTab.search &&
                  ModalRoute.of(context)?.isCurrent != false) {
                searchFocus.requestFocus();
              }
            });
          },
        if (navigation != null)
          MobileShortcut.turns: () => switchTo(_ExplorerTab.timeline),
        if (searchKeys) ...{
          MobileShortcut.nextMatch: () => moveMatch(1),
          MobileShortcut.previousMatch: () => moveMatch(-1),
          MobileShortcut.nextChoice: () => moveMatch(1),
          MobileShortcut.previousChoice: () => moveMatch(-1),
          if (matches.isNotEmpty) MobileShortcut.openChoice: openMatch,
        },
      }),
      child: Focus(
        focusNode: shortcutFocus,
        autofocus: !(widget.focusSearch && initial == _ExplorerTab.search),
        skipTraversal: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              widget.session == null ? context.tr('消息书签') : context.tr('查找与定位'),
            ),
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                if (widget.session != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                    child: SegmentedButton<_ExplorerTab>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: _ExplorerTab.search,
                          icon: Icon(Icons.search, size: 17),
                          label: Text(context.tr('搜索')),
                        ),
                        ButtonSegment(
                          value: _ExplorerTab.timeline,
                          icon: Icon(Icons.format_list_bulleted, size: 17),
                          label: Text(context.tr('轮次')),
                        ),
                        ButtonSegment(
                          value: _ExplorerTab.bookmarks,
                          icon: Icon(Icons.bookmark_border, size: 17),
                          label: Text(context.tr('书签')),
                        ),
                      ],
                      selected: {tab},
                      onSelectionChanged: (value) => switchTo(value.first),
                    ),
                  ),
                if (tab == _ExplorerTab.search)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: TextField(
                      controller: field,
                      focusNode: searchFocus,
                      autofocus: widget.focusSearch,
                      textInputAction: TextInputAction.search,
                      onChanged: search,
                      onSubmitted: (_) => openMatch(),
                      decoration: InputDecoration(
                        hintText: context.tr('搜索历史消息'),
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: field.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: context.tr('清空搜索'),
                                onPressed: () {
                                  field.clear();
                                  search('');
                                },
                                icon: const Icon(Icons.close),
                              ),
                      ),
                    ),
                  ),
                if ((tab == _ExplorerTab.search && searching) ||
                    (tab == _ExplorerTab.timeline && timelineLoading) ||
                    (tab == _ExplorerTab.bookmarks && bookmarksLoading))
                  const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: switch (tab) {
                    _ExplorerTab.search => searchResults(colors),
                    _ExplorerTab.timeline => timelineResults(),
                    _ExplorerTab.bookmarks => bookmarkResults(),
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget searchResults(ColorScheme colors) {
    if (field.text.trim().isEmpty) {
      return Center(child: Text(context.tr('输入关键词搜索本会话')));
    }
    if (matches.isEmpty && searchError == null) {
      final paused = searchState?.paused == true;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              searching
                  ? (searchState?.scanned ?? 0) >= 1000
                        ? context.strings.format('正在查找，已检查 {count} 条记录…', {
                            'count': searchState!.scanned,
                          })
                        : context.tr('正在查找历史消息…')
                  : context.tr(paused ? '查找已暂停' : '没有找到匹配的消息'),
              textAlign: TextAlign.center,
            ),
            searchControl(),
          ],
        ),
      );
    }
    final recent = searchState!.olderMatches > 0
        ? searchState!.recentMatches
        : 0;
    return Column(
      children: [
        searchStatus(colors, recent),
        Expanded(
          child: CustomScrollView(
            controller: searchScroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            center: historyResults,
            slivers: [
              if (recent > 0)
                SliverList.builder(
                  itemCount: recent,
                  itemBuilder: (_, index) =>
                      searchTile(recent - index - 1, colors),
                ),
              SliverList.builder(
                key: historyResults,
                itemCount: matches.length - recent,
                itemBuilder: (_, index) => searchTile(index + recent, colors),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 10)),
            ],
          ),
        ),
      ],
    );
  }

  Widget searchStatus(ColorScheme colors, int recent) {
    if (searchError case final error?) {
      return ListTile(
        dense: true,
        title: Text(context.tr(error), style: TextStyle(color: colors.error)),
        trailing: TextButton(
          onPressed: () => searchState?.retry(),
          child: Text(context.tr('重试')),
        ),
      );
    }
    final status = context.strings.format(
      searching
          ? '{count} 条匹配消息 · 搜索中'
          : searchState?.paused == true
          ? '{count} 条匹配消息 · 已暂停'
          : '{count} 条匹配消息',
      {'count': matches.length},
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 17, end: 4),
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          ),
          if (recent > 0)
            IconButton(
              tooltip: context.tr('回到最新'),
              onPressed: () {
                if (!searchScroll.hasClients) return;
                searchScroll.animateTo(
                  searchScroll.position.minScrollExtent,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                );
              },
              icon: const Icon(Icons.vertical_align_top_rounded, size: 19),
            ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: searchControl(),
          ),
        ],
      ),
    );
  }

  Widget searchControl() {
    final state = searchState;
    if (state == null) return const SizedBox.shrink();
    final action = searchError != null
        ? null
        : state.searching
        ? state.pause
        : state.paused
        ? state.resume
        : state.canLoadMore
        ? state.loadMore
        : null;
    if (action == null) return const SizedBox.shrink();
    return TextButton(
      onPressed: action,
      child: Text(context.tr(state.searching ? '暂停查找' : '继续查找')),
    );
  }

  Widget searchTile(int index, ColorScheme colors) {
    final hit = matches[index];
    final selected = selectedMatch == index;
    return ListTile(
      key: selected ? selectedTile : ValueKey(hit.address.rowId),
      selected: selected,
      selectedTileColor: colors.secondaryContainer,
      leading: Icon(
        hit.user ? Icons.person_outline : Icons.auto_awesome_outlined,
        size: 19,
      ),
      title: TranscriptMatchText(hit.preview, maxLines: 3),
      subtitle: Text(hit.user ? context.tr('用户消息') : context.tr('助手回复')),
      trailing: hit.multiple
          ? IconButton(
              tooltip: context.tr('查看匹配位置'),
              icon: const Icon(Icons.format_list_bulleted_rounded, size: 19),
              onPressed: () => openOccurrences(hit),
            )
          : null,
      onTap: () {
        selectedMatch = index;
        readMessage(hit.address, match: hit.preview);
      },
    );
  }

  Widget timelineResults() {
    final loadMore = olderTimelineAvailable ?? nextPrompt != null;
    return ListView.builder(
      itemCount: prompts.length + 1,
      itemBuilder: (context, index) {
        if (index == prompts.length) {
          if (timelineError != null) {
            return ListTile(
              title: Text(context.tr(timelineError!)),
              trailing: TextButton(
                onPressed: loadTimeline,
                child: Text(context.tr('重试')),
              ),
            );
          }
          if (loadMore) {
            return TextButton(
              onPressed: timelineLoading ? null : loadTimeline,
              child: Text(context.tr('查看更多轮次')),
            );
          }
          return prompts.isEmpty && !timelineLoading
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(context.tr('暂无用户消息')),
                  ),
                )
              : const SizedBox.shrink();
        }
        final prompt = prompts[index];
        return ListTile(
          leading: const Icon(Icons.chat_bubble_outline, size: 19),
          title: Text(
            prompt.preview.isEmpty ? context.tr('用户消息') : prompt.preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right, size: 17),
          onTap: () => readMessage(prompt.address),
        );
      },
    );
  }

  Widget bookmarkResults() {
    if (bookmarksError != null) {
      return ListTile(
        title: Text(context.tr(bookmarksError!)),
        trailing: TextButton(
          onPressed: loadBookmarks,
          child: Text(context.tr('重试')),
        ),
      );
    }
    if (bookmarks.isEmpty) {
      return Center(
        child: Text(
          bookmarksLoading ? context.tr('正在读取书签…') : context.tr('暂无消息书签'),
        ),
      );
    }
    return ListView.builder(
      itemCount: bookmarks.length,
      itemBuilder: (context, index) {
        final mark = bookmarks[index];
        return ListTile(
          leading: const Icon(Icons.bookmark_outline, size: 20),
          title: Text(
            mark.excerpt,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${mark.title} · ${mark.profile}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            tooltip: context.tr('移除书签'),
            icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
            onPressed: bookmarksLoading
                ? null
                : () async {
                    try {
                      await MessageBookmarks.forGateway(widget.gateway)
                          .setSaved(mark, saved: false);
                      if (mounted) await loadBookmarks();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(context.tr(e.toString()))),
                        );
                      }
                    }
                  },
          ),
          onTap: () => readMessage(mark.address, bookmark: mark),
        );
      },
    );
  }
}
