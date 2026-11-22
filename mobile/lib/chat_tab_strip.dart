import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'mobile_locale.dart';
import 'chat_tabs.dart';
import 'mobile_themes.dart';
import 'session_colors.dart';
import 'session_activity.dart';

Future<ChatTab?> chooseOpenTab(
  BuildContext context, {
  required List<ChatTab> tabs,
  required String active,
  required ValueListenable<Map<String, ConversationActivity>> activities,
  required Listenable metadataChanges,
  required String Function(String) profileLabel,
}) {
  final mixedProfiles = tabs.map((tab) => tab.profile).toSet().length > 1;
  return showModalBottomSheet<ChatTab>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheet).height * .68,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
              child: Semantics(
                header: true,
                child: Text(
                  sheet.tr('已打开的标签'),
                  style: Theme.of(sheet).textTheme.titleLarge,
                ),
              ),
            ),
            Flexible(
              child: ListenableBuilder(
                listenable: Listenable.merge([activities, metadataChanges]),
                builder: (_, _) => ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: tabs.length,
                  itemBuilder: (context, index) {
                    final tab = tabs[index];
                    final activity = activities.value[tab.id];
                    final unread = tab.row?['unread'] == true;
                    final selected = tab.id == active;
                    final draft = tab.draft.trim();
                    final subtitle = [
                      if (mixedProfiles) profileLabel(tab.profile),
                      if (tab.session == null && draft.isNotEmpty) draft,
                    ].join(' · ');
                    return ListTile(
                      leading: activity != null || unread
                          ? ConversationIndicator(
                              activity: activity,
                              unread: unread,
                            )
                          : Icon(
                              tab.session == null
                                  ? Icons.edit_outlined
                                  : Icons.chat_bubble_outline_rounded,
                              size: 18,
                            ),
                      minLeadingWidth: 18,
                      title: Text(
                        tab.title ??
                            context.tr(tab.session == null ? '新会话' : '未命名会话'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: subtitle.isEmpty
                          ? null
                          : Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      selected: selected,
                      selectedTileColor: Theme.of(context)
                          .colorScheme
                          .secondaryContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      trailing: selected
                          ? const Icon(Icons.check_rounded, size: 18)
                          : null,
                      onTap: () => Navigator.pop(sheet, tab),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class ChatTabStrip extends StatefulWidget {
  const ChatTabStrip({
    super.key,
    required this.tabs,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
    required this.onMove,
    required this.onCloseGroup,
    this.onReopen,
    this.onReload,
    this.onSessionOptions,
    this.activityFor,
    this.titleColor,
    this.profileLabel,
  });
  final List<ChatTab> tabs;
  final String active;
  final ValueChanged<ChatTab> onSelect;
  final ValueChanged<ChatTab> onClose;
  final VoidCallback onNew;
  final VoidCallback? onReopen;
  final void Function(ChatTab source, ChatTab target) onMove;
  final void Function(ChatTab tab, TabCloseScope scope) onCloseGroup;
  final ValueChanged<ChatTab>? onReload, onSessionOptions;
  final ConversationActivity? Function(ChatTab tab)? activityFor;
  final SessionTitleColor? Function(ChatTab tab)? titleColor;
  final String Function(String name)? profileLabel;

  @override
  State<ChatTabStrip> createState() => _ChatTabStripState();
}

class _ChatTabStripState extends State<ChatTabStrip> {
  final visible = GlobalKey();
  ScrollController scroll = ScrollController();
  bool reordering = false;
  bool dragging = false;

  @override
  void initState() {
    super.initState();
    reveal();
  }

  @override
  void didUpdateWidget(ChatTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!reordering &&
        (oldWidget.active != widget.active ||
            oldWidget.tabs.length != widget.tabs.length)) {
      reveal();
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = visible.currentContext;
      if (target != null) Scrollable.ensureVisible(target, alignment: .6);
    });
  }

  void setReordering(bool value) {
    final previous = scroll;
    setState(() {
      reordering = value;
      scroll = ScrollController(
        initialScrollOffset: previous.hasClients ? previous.offset : 0,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  Future<void> showOptions(ChatTab tab) async {
    final index = widget.tabs.indexOf(tab);
    if (index < 0) return;
    final count = widget.tabs.length;
    final canReload = tab.session != null && widget.onReload != null;
    final canManage = tab.session != null && widget.onSessionOptions != null;
    final action = await showModalBottomSheet<_TabAction>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: Text(
                  tab.title ?? sheet.tr(tab.session == null ? '新会话' : '未命名会话'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(sheet).textTheme.titleMedium,
                ),
              ),
              for (final item in _TabAction.values)
                if (switch (item) {
                  _TabAction.session => canManage,
                  _TabAction.reload => canReload,
                  _TabAction.reorder || _TabAction.closeOthers => count > 1,
                  _TabAction.closeRight => index < count - 1,
                  _ => true,
                })
                  ListTile(
                    leading: Icon(item.icon, size: 21),
                    title: Text(sheet.tr(item.label)),
                    minTileHeight: 48,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onTap: () => Navigator.pop(sheet, item),
                  ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null || !widget.tabs.contains(tab)) return;
    if (action.scope case final scope?) {
      widget.onCloseGroup(tab, scope);
      return;
    }
    switch (action) {
      case _TabAction.session:
        widget.onSessionOptions?.call(tab);
      case _TabAction.reload:
        widget.onReload?.call(tab);
      case _TabAction.reorder:
        setReordering(true);
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final profiles = widget.tabs.map((tab) => tab.profile).toSet();

    Widget chipAt(int index) {
      final tab = widget.tabs[index];
      return Padding(
        key: ValueKey(tab.id),
        padding: const EdgeInsets.only(right: 6),
        child: KeyedSubtree(
          key: tab.id == widget.active ? visible : null,
          child: tabChip(tab, index, colors, showProfile: profiles.length > 1),
        ),
      );
    }

    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Expanded(
            child: reordering
                ? ReorderableListView.builder(
                    scrollController: scroll,
                    scrollDirection: Axis.horizontal,
                    buildDefaultDragHandles: false,
                    itemCount: widget.tabs.length,
                    itemBuilder: (_, index) => chipAt(index),
                    onReorderStart: (_) => setState(() => dragging = true),
                    onReorderEnd: (_) => setState(() => dragging = false),
                    onReorderItem: (from, to) {
                      if (from == to) return;
                      widget.onMove(widget.tabs[from], widget.tabs[to]);
                    },
                    proxyDecorator: (child, _, _) => child,
                  )
                : SingleChildScrollView(
                    controller: scroll,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var index = 0; index < widget.tabs.length; index++)
                          chipAt(index),
                      ],
                    ),
                  ),
          ),
          if (!reordering && widget.onReopen != null)
            IconButton(
              tooltip: context.tr('重新打开已关闭的标签'),
              onPressed: widget.onReopen,
              icon: const Icon(Icons.history_rounded, size: 19),
            ),
          IconButton(
            tooltip: context.tr(reordering ? '完成排序' : '新建标签'),
            onPressed: reordering
                ? (dragging ? null : () => setReordering(false))
                : widget.onNew,
            icon: Icon(
              reordering ? Icons.check_rounded : Icons.add_rounded,
              size: 20,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget tabChip(
    ChatTab tab,
    int index,
    ColorScheme colors, {
    required bool showProfile,
  }) {
    final selected = tab.id == widget.active;
    final activity = widget.activityFor?.call(tab);
    final unread = tab.row?['unread'] == true;
    final background = selected
        ? CustomThemeTokens.read(context, ThemeColor.selection) ??
              colors.secondaryContainer
        : colors.surface;
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(12),
      child: Row(
        children: [
          Semantics(
            container: true,
            button: true,
            selected: selected,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: reordering ? null : () => widget.onSelect(tab),
              onLongPress: reordering ? null : () => showOptions(tab),
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: 48,
                    maxWidth: 126,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (activity != null || unread) ...[
                        ConversationIndicator(
                          activity: activity,
                          unread: unread,
                          size: 14,
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tab.title ??
                                  context.tr(
                                    tab.session == null ? '新会话' : '未命名会话',
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color:
                                    widget.titleColor
                                        ?.call(tab)
                                        ?.onBackground(background) ??
                                    (selected
                                        ? colors.onSecondaryContainer
                                        : colors.onSurfaceVariant),
                              ),
                            ),
                            if (showProfile)
                              Text(
                                widget.profileLabel?.call(tab.profile) ??
                                    context.strings.profileName(tab.profile),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.onSurfaceVariant,
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
          if (reordering)
            ReorderableDragStartListener(
              index: index,
              child: Tooltip(
                message: context.tr('拖动排序'),
                child: SizedBox.square(
                  dimension: 48,
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    color: colors.onSurfaceVariant,
                    size: 19,
                  ),
                ),
              ),
            )
          else
            IconButton(
              tooltip: context.tr('关闭标签'),
              onPressed: () => widget.onClose(tab),
              icon: const Icon(Icons.close_rounded, size: 15),
              style: IconButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                foregroundColor: colors.onSurfaceVariant,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
    );
  }
}

enum _TabAction {
  session('会话选项', Icons.more_horiz_rounded),
  reload('重新加载会话', Icons.refresh_rounded),
  reorder('调整标签顺序', Icons.swap_horiz_rounded),
  close('关闭标签', Icons.close_rounded, TabCloseScope.current),
  closeOthers('关闭其他标签', Icons.filter_none_rounded, TabCloseScope.others),
  closeRight('关闭右侧标签', Icons.arrow_right_alt_rounded, TabCloseScope.right),
  closeAll('关闭全部标签', Icons.clear_all_rounded, TabCloseScope.all);

  const _TabAction(this.label, this.icon, [this.scope]);

  final String label;
  final IconData icon;
  final TabCloseScope? scope;
}
