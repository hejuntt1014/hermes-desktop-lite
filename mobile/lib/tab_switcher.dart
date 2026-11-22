import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'chat_tabs.dart';
import 'mobile_locale.dart';
import 'session_activity.dart';
import 'session_colors.dart';

/// Callbacks the switcher runs against the live tab list owned by the shell.
class TabSwitcherActions {
  const TabSwitcherActions({
    required this.tabs,
    required this.onClose,
    required this.onCloseGroup,
    required this.onNew,
    this.onReopen,
  });

  /// Re-read after every mutation so the grid reflects closes immediately.
  final List<ChatTab> Function() tabs;
  final ValueChanged<ChatTab> onClose;
  final void Function(ChatTab tab, TabCloseScope scope) onCloseGroup;
  final VoidCallback onNew;
  final VoidCallback? onReopen;
}

/// Edge / Chrome style overview of open conversations. Returns the tab the
/// user picked, or null when the sheet was dismissed or an action already ran.
Future<ChatTab?> showTabSwitcher(
  BuildContext context, {
  required String active,
  required TabSwitcherActions actions,
  required ValueListenable<Map<String, ConversationActivity>> activities,
  required Listenable metadataChanges,
  required String Function(String) profileLabel,
  SessionTitleColor? Function(ChatTab tab)? titleColor,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<ChatTab>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => _TabSwitcher(
      active: active,
      actions: actions,
      activities: activities,
      metadataChanges: metadataChanges,
      profileLabel: profileLabel,
      titleColor: titleColor,
    ),
  );
}

class _TabSwitcher extends StatefulWidget {
  const _TabSwitcher({
    required this.active,
    required this.actions,
    required this.activities,
    required this.metadataChanges,
    required this.profileLabel,
    this.titleColor,
  });

  final String active;
  final TabSwitcherActions actions;
  final ValueListenable<Map<String, ConversationActivity>> activities;
  final Listenable metadataChanges;
  final String Function(String) profileLabel;
  final SessionTitleColor? Function(ChatTab tab)? titleColor;

  @override
  State<_TabSwitcher> createState() => _TabSwitcherState();
}

enum _CardAction {
  close('关闭标签', Icons.close_rounded, TabCloseScope.current),
  closeOthers('关闭其他标签', Icons.filter_none_rounded, TabCloseScope.others),
  closeRight('关闭右侧标签', Icons.arrow_right_alt_rounded, TabCloseScope.right);

  const _CardAction(this.label, this.icon, this.scope);
  final String label;
  final IconData icon;
  final TabCloseScope scope;
}

class _TabSwitcherState extends State<_TabSwitcher> {
  late List<ChatTab> tabs = widget.actions.tabs();

  void refresh() {
    final next = widget.actions.tabs();
    if (next.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() => tabs = next);
  }

  void close(ChatTab tab) {
    widget.actions.onClose(tab);
    refresh();
  }

  Future<void> cardOptions(ChatTab tab) async {
    final index = tabs.indexOf(tab);
    final action = await showModalBottomSheet<_CardAction>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in _CardAction.values)
                if (switch (item) {
                  _CardAction.closeOthers => tabs.length > 1,
                  _CardAction.closeRight => index < tabs.length - 1,
                  _ => true,
                })
                  ListTile(
                    leading: Icon(item.icon, size: 21),
                    title: Text(sheet.tr(item.label)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    onTap: () => Navigator.pop(sheet, item),
                  ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null || !tabs.contains(tab)) return;
    widget.actions.onCloseGroup(tab, action.scope);
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final mixedProfiles = tabs.map((tab) => tab.profile).toSet().length > 1;
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 900
        ? 4
        : width >= 600
        ? 3
        : 2;
    final canReopen = widget.actions.onReopen != null;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .86,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 14, 6),
            child: Row(
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    context.tr('已打开的标签'),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.3,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    '${tabs.length}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                if (tabs.length > 1)
                  TextButton(
                    onPressed: () {
                      widget.actions.onCloseGroup(
                        tabs.first,
                        TabCloseScope.all,
                      );
                      Navigator.pop(context);
                    },
                    child: Text(context.tr('关闭全部')),
                  ),
              ],
            ),
          ),
          Flexible(
            child: ListenableBuilder(
              listenable: Listenable.merge([
                widget.activities,
                widget.metadataChanges,
              ]),
              builder: (context, _) => GridView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.02,
                ),
                itemCount: tabs.length,
                itemBuilder: (context, index) {
                  final tab = tabs[index];
                  return _TabCard(
                    key: ValueKey(tab.id),
                    tab: tab,
                    selected: tab.id == widget.active,
                    activity: widget.activities.value[tab.id],
                    profile: mixedProfiles
                        ? widget.profileLabel(tab.profile)
                        : null,
                    titleColor: widget.titleColor?.call(tab),
                    onTap: () => Navigator.pop(context, tab),
                    onClose: () => close(tab),
                    onLongPress: () => cardOptions(tab),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
              child: Row(
                children: [
                  if (canReopen)
                    IconButton(
                      tooltip: context.tr('重新打开关闭的标签'),
                      onPressed: () {
                        widget.actions.onReopen?.call();
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.history_rounded),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      widget.actions.onNew();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.onSurface,
                      foregroundColor: colors.surface,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                    ),
                    icon: const Icon(Icons.add_rounded, size: 20),
                    label: Text(context.tr('新建会话')),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabCard extends StatelessWidget {
  const _TabCard({
    super.key,
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.onClose,
    required this.onLongPress,
    this.activity,
    this.profile,
    this.titleColor,
  });

  final ChatTab tab;
  final bool selected;
  final ConversationActivity? activity;
  final String? profile;
  final SessionTitleColor? titleColor;
  final VoidCallback onTap, onClose, onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final row = tab.row;
    final unread = row?['unread'] == true;
    final draft = tab.draft.trim();
    final preview = switch (row?['preview']) {
      final String text when text.trim().isNotEmpty => text.trim(),
      _ => null,
    };
    final body = draft.isNotEmpty
        ? '${context.tr('草稿')}：$draft'
        : preview ?? context.tr(tab.session == null ? '空白会话，开始输入吧' : '暂无预览');
    final time = row == null ? null : sessionTime(row);
    final stamp = time == null
        ? null
        : MaterialLocalizations.of(context).formatShortMonthDay(time);
    final footer = [?profile, ?stamp].join(' · ');
    final background = selected ? colors.surface : colors.surfaceContainerLow;
    final radius = BorderRadius.circular(20);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: background,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: selected ? colors.primary : colors.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 4, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (activity != null || unread)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ConversationIndicator(
                            activity: activity,
                            unread: unread,
                            size: 14,
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(
                            tab.session == null
                                ? Icons.edit_outlined
                                : Icons.chat_bubble_outline_rounded,
                            size: 14,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      Expanded(
                        child: Text(
                          selected ? context.tr('当前') : '',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: selected
                                ? colors.primary
                                : colors.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: context.tr('关闭标签'),
                        onPressed: onClose,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.close_rounded,
                          size: 17,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(
                      tab.title ??
                          context.tr(tab.session == null ? '新会话' : '未命名会话'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                        color: titleColor?.onBackground(background),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Text(
                        body,
                        overflow: TextOverflow.fade,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
                  if (footer.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 10),
                      child: Text(
                        footer,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant.withValues(alpha: .8),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Toolbar button that shows how many tabs are open, like a mobile browser.
class TabCountButton extends StatelessWidget {
  const TabCountButton({super.key, required this.count, this.onPressed});

  final int count;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = onPressed == null
        ? colors.onSurface.withValues(alpha: .38)
        : colors.onSurface;
    return IconButton(
      tooltip: context.tr('已打开的标签'),
      onPressed: onPressed,
      icon: Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color, width: 1.8),
        ),
        child: Text(
          count > 99 ? ':D' : '$count',
          style: TextStyle(
            fontSize: count > 9 ? 10 : 12,
            fontWeight: FontWeight.w800,
            color: color,
            height: 1,
          ),
        ),
      ),
    );
  }
}
