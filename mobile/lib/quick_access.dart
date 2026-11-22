import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'mobile_shortcuts.dart';
import 'chat_tabs.dart';
import 'gateway.dart';
import 'message_bookmarks.dart';
import 'session_library.dart' show hiddenSessionSources;

enum QuickAction {
  newChat('新建会话', 'new chat', Icons.add_rounded),
  reopenTab('重新打开已关闭的标签', 'reopen closed tab', Icons.history_rounded),
  sidebar('打开会话列表', 'sidebar sessions', Icons.menu_open_rounded),
  showSidebar('显示会话侧栏', 'sidebar sessions show', Icons.menu_open_rounded),
  hideSidebar('隐藏会话侧栏', 'sidebar sessions hide', Icons.menu_open_rounded),
  find('在会话内查找', 'find search in chat', Icons.manage_search_rounded),
  manageConversation(
    '管理会话',
    'conversation actions manage pin archive',
    Icons.tune_rounded,
  ),
  renameConversation('重命名会话', 'rename conversation title', Icons.edit_outlined),
  exportConversation(
    '导出会话',
    'export conversation markdown json',
    Icons.download_outlined,
  ),
  busyInput(
    '忙时发送',
    'busy input interrupt queue steer',
    Icons.pending_actions_outlined,
  ),
  conversationFiles(
    '会话文件',
    'conversation attachments images',
    Icons.attach_file_rounded,
  ),
  files('工作区文件', 'workspace files explorer', Icons.folder_open_outlined),
  review('审查 Git 变更', 'git review diff', Icons.difference_outlined),
  activity('会话活动', 'agents tasks processes', Icons.bolt_outlined),
  status('会话状态', 'context usage approvals mode', Icons.data_usage_rounded),
  gatewayStatus(
    '网关状态',
    'gateway status connection diagnostics logs',
    Icons.monitor_heart_outlined,
  ),
  cron('定时任务', 'cron schedule', Icons.schedule_outlined),
  commands('命令与技能', 'slash commands skills', Icons.terminal_rounded),
  settings('设置', 'settings gateway appearance', Icons.settings_outlined);

  const QuickAction(this.label, this.keywords, this.icon);
  final String label, keywords;
  final IconData icon;
}

sealed class QuickTarget {
  const QuickTarget();
}

class QuickCommand extends QuickTarget {
  const QuickCommand(this.action);
  final QuickAction action;
}

class QuickSession extends QuickTarget {
  const QuickSession(this.row);
  final Json row;
}

class QuickTab extends QuickTarget {
  const QuickTab(this.id);
  final String id;
}

class QuickBookmark extends QuickTarget {
  const QuickBookmark(this.bookmark);
  final MessageBookmark bookmark;
}

String? _sessionId(Json row) {
  final value = row['id'] ?? row['session_id'];
  return value is String ? value : null;
}

String _title(Json row, {String fallback = '未命名会话'}) =>
    sessionTitle(row) ?? fallback;

class QuickAccessPage extends StatefulWidget {
  const QuickAccessPage({
    super.key,
    required this.gateway,
    required this.profile,
    required this.actions,
    required this.recent,
    this.openTabs = const [],
    this.activeTabId,
    this.initialQuery = '',
    this.focusSearch = false,
  });

  final Gateway gateway;
  final String profile, initialQuery;
  final List<QuickAction> actions;
  final List<Json> recent;
  final List<ChatTab> openTabs;
  final String? activeTabId;
  final bool focusSearch;

  @override
  State<QuickAccessPage> createState() => _QuickAccessPageState();
}

class _QuickAccessPageState extends State<QuickAccessPage> {
  late final field = TextEditingController(text: widget.initialQuery);
  final scroll = ScrollController(keepScrollOffset: false);
  final highlightedTile = GlobalKey();
  Object? highlighted;
  Timer? debounce;
  FileTransferControl? searchRead;
  int revision = 0;
  bool loading = false, searchFailed = false, bookmarksFailed = false;
  List<Json> recents = [];
  List<Json> remote = [];
  List<MessageBookmark> marks = [];

  @override
  void initState() {
    super.initState();
    recents = widget.recent.where(owns).toList();
    fetchBookmarks();
    changeQuery(immediate: true);
  }

  @override
  void dispose() {
    debounce?.cancel();
    searchRead?.cancel();
    field.dispose();
    scroll.dispose();
    super.dispose();
  }

  bool owns(Json row) =>
      (row['profile'] == null || row['profile'] == widget.profile) &&
      _sessionId(row)?.isNotEmpty == true;

  Future<void> fetchBookmarks() async {
    try {
      final found = await MessageBookmarks.forGateway(widget.gateway).read();
      if (!mounted) return;
      setState(
        () => marks = found
            .where((mark) => mark.profile == widget.profile)
            .toList(),
      );
    } catch (_) {
      if (mounted) setState(() => bookmarksFailed = true);
    }
  }

  void changeQuery({bool immediate = false}) {
    debounce?.cancel();
    searchRead?.cancel();
    searchRead = null;
    if (scroll.hasClients) scroll.jumpTo(0);
    final updated = ++revision;
    final query = field.text.trim();
    setState(() {
      remote = [];
      loading = true;
      searchFailed = false;
      highlighted = null;
    });
    if (immediate) {
      unawaited(fetch(updated, query));
    } else {
      debounce = Timer(
        const Duration(milliseconds: 240),
        () => fetch(updated, query),
      );
    }
  }

  Future<void> fetch(int updated, String query) async {
    if (!mounted || revision != updated) return;
    final control = searchRead = FileTransferControl();
    bool current() =>
        mounted &&
        revision == updated &&
        identical(searchRead, control) &&
        !control.cancelled;
    final recentMode = query.isEmpty;
    try {
      final response = await widget.gateway.readConversationPage(
        recentMode ? 'api/sessions' : 'api/sessions/search',
        query: {
          'profile': widget.profile,
          'limit': recentMode ? '12' : '48',
          'min_messages': '1',
          'exclude_sources': hiddenSessionSources,
          if (recentMode) 'order': 'recent' else 'q': query,
        },
        timeout: const Duration(seconds: 10),
        control: control,
      );
      if (!current()) return;
      final source = response[recentMode ? 'sessions' : 'results'];
      if (source is! List) throw GatewayError('网关未返回会话列表');
      final rows = source.whereType<Json>().where(owns).toList();
      setState(() {
        if (recentMode) {
          recents = rows.where((row) => row['archived'] != true).toList();
        } else {
          remote = rows;
        }
      });
    } catch (_) {
      if (current()) setState(() => searchFailed = true);
    } finally {
      if (current()) {
        searchRead = null;
        setState(() => loading = false);
      }
    }
  }

  void choose(QuickTarget target) => Navigator.of(context).pop(target);

  Object targetKey(QuickTarget target) => switch (target) {
    QuickSession(:final row) => ('session', _sessionId(row)),
    QuickTab(:final id) => ('tab', id),
    QuickBookmark(:final bookmark) => (
      'bookmark',
      bookmark.session,
      bookmark.address.rowId,
    ),
    QuickCommand(:final action) => action,
  };

  void move(List<QuickTarget> targets, int step) {
    if (targets.isEmpty) return;
    final index = targets.indexWhere(
      (target) => targetKey(target) == highlighted,
    );
    final next = index < 0
        ? (step > 0 ? 0 : targets.length - 1)
        : (index + step) % targets.length;
    setState(() => highlighted = targetKey(targets[next]));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      if (highlightedTile.currentContext case final target?) {
        Scrollable.ensureVisible(target);
      } else if (next == 0 || next == targets.length - 1) {
        scroll.jumpTo(next == 0 ? 0 : scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final needle = field.text.trim().toLowerCase();
    final tokens = needle.split(RegExp(r'\s+'));
    bool matches(String value) => tokens.every(value.toLowerCase().contains);
    final commands = widget.actions
        .where(
          (a) => matches('${a.label} ${context.tr(a.label)} ${a.keywords}'),
        )
        .toList();
    final bookmarks = marks
        .where((b) => matches('${b.title} ${b.excerpt} 收藏 书签 bookmarks'))
        .take(20)
        .toList();
    final open = widget.openTabs
        .where((tab) => tab.profile == widget.profile)
        .toList();
    final snippets = {
      for (final row in remote)
        _sessionId(row)!: (row['snippet'] ?? '').toString(),
    };
    final draftLabel = context.tr('草稿');
    final newChatLabel = context.tr('新会话');
    final matchingTabs = <({ChatTab tab, String title, String subtitle})>[];
    for (final tab in open) {
      final session = tab.session;
      final title =
          tab.title ?? (session == null ? newChatLabel : context.tr('未命名会话'));
      final subtitle = session == null
          ? draftSubtitle(tab, draftLabel)
          : snippets[session] ?? '';
      final searchable = session == null
          ? '$newChatLabel $draftLabel draft $subtitle'
          : '$title $session';
      if (matches(searchable) || snippets.containsKey(session)) {
        matchingTabs.add((tab: tab, title: title, subtitle: subtitle));
      }
    }
    final seen = open.map((tab) => tab.session).nonNulls.toSet();
    final sessions = [
      if (needle.isEmpty)
        ...recents
      else ...[
        ...remote,
        ...recents.where((r) => matches('${_title(r)} ${_sessionId(r)}')),
      ],
    ].where((r) => seen.add(_sessionId(r)!)).take(48).toList();
    final targets = [
      for (final entry in matchingTabs) QuickTab(entry.tab.id),
      if (needle.isNotEmpty) ...commands.map(QuickCommand.new),
      ...sessions.map(QuickSession.new),
      ...bookmarks.map(QuickBookmark.new),
      if (needle.isEmpty) ...commands.map(QuickCommand.new),
    ];
    final selected = targets
        .where((target) => targetKey(target) == highlighted)
        .firstOrNull;
    return CallbackShortcuts(
      bindings: MobileShortcut.bind({
        MobileShortcut.dismiss: () => Navigator.of(context).maybePop(),
        MobileShortcut.quickAccess: () => Navigator.of(context).maybePop(),
        if (!field.value.isComposingRangeValid ||
            field.value.composing.isCollapsed) ...{
          MobileShortcut.nextChoice: () => move(targets, 1),
          MobileShortcut.previousChoice: () => move(targets, -1),
          if (selected != null || !loading && targets.isNotEmpty)
            MobileShortcut.openChoice: () => choose(selected ?? targets.first),
        },
      }),
      child: Focus(
        autofocus: !widget.focusSearch && widget.initialQuery.isEmpty,
        skipTraversal: true,
        child: Scaffold(
          appBar: AppBar(title: Text(context.tr('快捷入口'))),
          body: SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                      child: TextField(
                        controller: field,
                        autofocus: widget.focusSearch || needle.isNotEmpty,
                        onChanged: (_) => changeQuery(),
                        onSubmitted: (_) {
                          if (debounce?.isActive == true) {
                            changeQuery(immediate: true);
                          } else if (selected != null) {
                            choose(selected);
                          } else if (!loading && targets.length == 1) {
                            choose(targets.single);
                          }
                        },
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: context.tr('搜索会话、书签或操作'),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 20,
                          ),
                          suffixIcon: needle.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: context.tr('清空搜索'),
                                  onPressed: () {
                                    field.clear();
                                    changeQuery(immediate: true);
                                  },
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                ),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 2,
                      child: loading
                          ? const LinearProgressIndicator(minHeight: 2)
                          : null,
                    ),
                    Expanded(
                      child: ListView(
                        controller: scroll,
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        children: [
                          if (matchingTabs.isNotEmpty) ...[
                            heading('已打开的标签'),
                            for (final entry in matchingTabs)
                              tile(
                                entry.title,
                                Icons.tab_rounded,
                                QuickTab(entry.tab.id),
                                subtitle: entry.subtitle,
                                highlightMatches: entry.tab.session != null,
                                activeTab: entry.tab.id == widget.activeTabId,
                              ),
                          ],
                          if (needle.isNotEmpty && commands.isNotEmpty)
                            ...commandRows(commands),
                          if (sessions.isNotEmpty) ...[
                            heading(needle.isEmpty ? '最近会话' : '历史会话'),
                            for (final row in sessions)
                              tile(
                                _title(row, fallback: context.tr('未命名会话')),
                                row['archived'] == true
                                    ? Icons.archive_outlined
                                    : Icons.chat_bubble_outline_rounded,
                                QuickSession(row),
                                highlightMatches: true,
                                subtitle: [
                                  if (row['archived'] == true)
                                    context.tr('已归档'),
                                  if (row['snippet'] case final String snippet
                                      when snippet.isNotEmpty)
                                    snippet,
                                ].join(' · '),
                              ),
                          ],
                          if (bookmarks.isNotEmpty) ...[
                            heading('消息书签'),
                            for (final mark in bookmarks)
                              tile(
                                mark.excerpt.isEmpty
                                    ? mark.title
                                    : mark.excerpt,
                                Icons.bookmark_border_rounded,
                                QuickBookmark(mark),
                                subtitle: mark.excerpt.isEmpty
                                    ? ''
                                    : mark.title,
                              ),
                          ],
                          if (bookmarksFailed)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 15,
                                vertical: 8,
                              ),
                              child: Text(context.tr('无法读取已保存的书签')),
                            ),
                          if (needle.isEmpty && commands.isNotEmpty)
                            ...commandRows(commands),
                          if (searchFailed)
                            ListTile(
                              title: Text(context.tr('暂时无法搜索网关会话')),
                              trailing: TextButton(
                                onPressed: () => changeQuery(immediate: true),
                                child: Text(context.tr('重试')),
                              ),
                            )
                          else if (!loading && targets.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(22),
                              child: Text(
                                context.tr('没有匹配的结果'),
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> commandRows(List<QuickAction> actions) => [
    heading('常用操作'),
    for (final action in actions)
      tile(context.tr(action.label), action.icon, QuickCommand(action)),
  ];

  String draftSubtitle(ChatTab tab, String label) {
    final text = tab.draft.trim();
    if (text.isNotEmpty) return text.characters.take(120).toString();
    return tab.attachments.firstOrNull?.name ?? label;
  }

  TextSpan searchSubtitle(String subtitle, Color matchColor) {
    final parts = <TextSpan>[];
    var start = 0;
    const opening = '>>>';
    const closing = '<<<';
    while (true) {
      final mark = subtitle.indexOf(opening, start);
      if (mark < 0) break;
      final end = subtitle.indexOf(closing, mark + opening.length);
      if (end < 0) break;
      parts.add(TextSpan(text: subtitle.substring(start, mark)));
      parts.add(
        TextSpan(
          text: subtitle.substring(mark + opening.length, end),
          style: TextStyle(color: matchColor, fontWeight: FontWeight.w600),
        ),
      );
      start = end + closing.length;
    }
    parts.add(TextSpan(text: subtitle.substring(start)));
    return TextSpan(children: parts);
  }

  Widget heading(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 16, 14, 3),
    child: Text(
      context.tr(title),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget tile(
    String title,
    IconData icon,
    QuickTarget target, {
    String subtitle = '',
    bool highlightMatches = false,
    bool activeTab = false,
  }) {
    final selected = highlighted == targetKey(target);
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      key: selected ? highlightedTile : ValueKey(targetKey(target)),
      selected: selected,
      selectedTileColor: colors.secondaryContainer,
      minTileHeight: 48,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(icon, size: 20, color: colors.onSurfaceVariant),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : highlightMatches
          ? Text.rich(
              searchSubtitle(subtitle, colors.primary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: activeTab
          ? Icon(
              Icons.check_rounded,
              size: 18,
              color: colors.primary,
              semanticLabel: context.tr('当前标签'),
            )
          : const Icon(Icons.chevron_right_rounded, size: 18),
      onTap: () => choose(target),
    );
  }
}
