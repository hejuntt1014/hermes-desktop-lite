import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'chat_tabs.dart';
import 'mobile_locale.dart';
import 'session_activity.dart';
import 'session_colors.dart';
import 'ui_kit.dart';

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

/// Browser-style overview of open conversations over a frosted copy of the
/// chat. Returns the tab the user picked, or null when dismissed or when an
/// action (new, reopen, close all) already ran.
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
  return Navigator.of(context).push<ChatTab>(
    PageRouteBuilder<ChatTab>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => _TabSwitcher(
        active: active,
        actions: actions,
        activities: activities,
        metadataChanges: metadataChanges,
        profileLabel: profileLabel,
        titleColor: titleColor,
      ),
      transitionsBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 1.04, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
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
  closeRight('关闭右侧标签', Icons.east_rounded, TabCloseScope.right);

  const _CardAction(this.label, this.icon, this.scope);
  final String label;
  final IconData icon;
  final TabCloseScope scope;
}

class _TabSwitcherState extends State<_TabSwitcher> {
  late List<ChatTab> tabs = widget.actions.tabs();
  ScrollController? scroll;

  /// Open with the current tab's row in view, the way a browser does.
  ScrollController scrollFor(int columns, double width) {
    if (scroll case final existing?) return existing;
    final index = tabs.indexWhere((tab) => tab.id == widget.active);
    final row = index < 0 ? 0 : index ~/ columns;
    const cardHeight = _cardHeight;
    return scroll = ScrollController(
      initialScrollOffset: row <= 2 ? 0 : (row - 2) * (cardHeight + 10),
    );
  }

  @override
  void dispose() {
    scroll?.dispose();
    super.dispose();
  }

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

  Future<void> cardOptions(ChatTab tab, Rect anchor) async {
    final index = tabs.indexOf(tab);
    final action = await showGlassMenu<_CardAction>(
      context,
      anchor: anchor,
      items: [
        for (final item in _CardAction.values)
          if (switch (item) {
            _CardAction.closeOthers => tabs.length > 1,
            _CardAction.closeRight => index < tabs.length - 1,
            _ => true,
          })
            GlassMenuItem(
              value: item,
              icon: item.icon,
              label: context.tr(item.label),
            ),
      ],
    );
    if (!mounted || action == null || !tabs.contains(tab)) return;
    widget.actions.onCloseGroup(tab, action.scope);
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final mixedProfiles = tabs.map((tab) => tab.profile).toSet().length > 1;
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 680 ? 2 : 1;
    final canReopen = widget.actions.onReopen != null;
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: ColoredBox(
          color: (dark ? Colors.black : const Color(0xffeeeef2)).withValues(
            alpha: dark ? .55 : .72,
          ),
          child: Stack(
            children: [
              ListenableBuilder(
                listenable: Listenable.merge([
                  widget.activities,
                  widget.metadataChanges,
                ]),
                builder: (context, _) => CustomScrollView(
                  controller: scrollFor(columns, width),
                  slivers: [
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: MediaQuery.paddingOf(context).top + 72,
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(14, 4, 14, bottomSafe + 96),
                      sliver: SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          mainAxisExtent: _cardHeight,
                        ),
                        itemCount: tabs.length,
                        itemBuilder: (context, index) {
                          final tab = tabs[index];
                          return Dismissible(
                            key: ValueKey(tab.id),
                            direction: DismissDirection.horizontal,
                            onDismissed: (_) => close(tab),
                            child: Builder(
                              builder: (card) => _TabCard(
                                tab: tab,
                                selected: tab.id == widget.active,
                                activity: widget.activities.value[tab.id],
                                profile: mixedProfiles
                                    ? widget.profileLabel(tab.profile)
                                    : null,
                                titleColor: widget.titleColor?.call(tab),
                                onTap: () => Navigator.pop(context, tab),
                                onClose: () => close(tab),
                                onLongPress: () =>
                                    cardOptions(tab, globalRectOf(card)),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              // Fixed frosted header: cards scroll beneath it instead of under
              // the status bar.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: ColoredBox(
                      color: (dark ? Colors.black : const Color(0xffeeeef2))
                          .withValues(alpha: dark ? .6 : .82),
                      child: SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(22, 12, 14, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Semantics(
                                  header: true,
                                  child: Text(
                                    context.tr('标签页'),
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -.6,
                                        ),
                                  ),
                                ),
                              ),
                              Text(
                                context.strings.format('{count} 个', {
                                  'count': tabs.length,
                                }),
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                tooltip: context.tr('完成'),
                                onPressed: () => Navigator.pop(context),
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Center(
                      child: GlassSurface(
                        radius: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: SizedBox(
                          height: 60,
                          width: 320,
                          child: Row(
                            children: [
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton(
                                    onPressed: tabs.length > 1
                                        ? () {
                                            widget.actions.onCloseGroup(
                                              tabs.first,
                                              TabCloseScope.all,
                                            );
                                            Navigator.pop(context);
                                          }
                                        : null,
                                    style: TextButton.styleFrom(
                                      foregroundColor: colors.onSurface,
                                    ),
                                    child: Text(context.tr('关闭全部')),
                                  ),
                                ),
                              ),
                              IconButton.filled(
                                tooltip: context.tr('新建会话'),
                                onPressed: () {
                                  Navigator.pop(context);
                                  widget.actions.onNew();
                                },
                                style: IconButton.styleFrom(
                                  backgroundColor: colors.onSurface,
                                  foregroundColor: colors.surface,
                                  minimumSize: const Size(48, 48),
                                ),
                                icon: const Icon(Icons.add_rounded, size: 26),
                              ),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: IconButton(
                                    tooltip: context.tr('重新打开关闭的标签'),
                                    onPressed: canReopen
                                        ? () {
                                            widget.actions.onReopen?.call();
                                            Navigator.pop(context);
                                          }
                                        : null,
                                    icon: const Icon(Icons.history_rounded),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _cardHeight = 84.0;

/// Soft avatar tones; a tab keeps its tone because it hashes its title.
const _avatarTones = [
  Color(0xff5b6cf0),
  Color(0xff1f9d8f),
  Color(0xffd9822b),
  Color(0xffc2457a),
  Color(0xff7a5af0),
  Color(0xff2f8fd8),
  Color(0xff5f8f3a),
];

/// One open conversation as a message-list row: avatar, title and time,
/// two lines of preview, and a close button. The current tab is tinted.
class _TabCard extends StatelessWidget {
  const _TabCard({
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
    final dark = theme.brightness == Brightness.dark;
    final row = tab.row;
    final unread = row?['unread'] == true;
    final draft = tab.draft.trim();
    final title =
        tab.title ?? context.tr(tab.session == null ? '新会话' : '未命名会话');
    final preview = switch (row?['preview']) {
      final String text when text.trim().isNotEmpty => text.trim(),
      _ => null,
    };
    final body = draft.isNotEmpty
        ? draft
        : preview ?? context.tr(tab.session == null ? '空白会话，开始输入吧' : '暂无预览');
    final time = row == null ? null : sessionTime(row);
    final stamp = time == null
        ? null
        : MaterialLocalizations.of(context).formatShortMonthDay(time);
    final base = dark ? colors.surfaceContainerHigh : colors.surface;
    final surface = selected
        ? Color.alphaBlend(
            colors.primary.withValues(alpha: dark ? .22 : .09),
            base,
          )
        : base;
    final tone = _avatarTones[title.hashCode.abs() % _avatarTones.length];
    final initial = title.characters.firstOrNull ?? '·';
    return Semantics(
      selected: selected,
      button: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .25 : .045),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: surface,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            onSecondaryTap: onLongPress,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 6, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: tone.withValues(alpha: dark ? .28 : .14),
                          shape: BoxShape.circle,
                        ),
                        child: tab.session == null
                            ? Icon(Icons.edit_rounded, size: 18, color: tone)
                            : Text(
                                initial,
                                style: TextStyle(
                                  color: tone,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
                      if (activity != null || unread)
                        Positioned(
                          right: -3,
                          bottom: -3,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: surface,
                              shape: BoxShape.circle,
                            ),
                            child: ConversationIndicator(
                              activity: activity,
                              unread: unread,
                              size: 13,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -.2,
                                  color:
                                      titleColor?.onBackground(surface) ??
                                      colors.onSurface,
                                ),
                              ),
                            ),
                            if (selected)
                              _Tag(
                                label: context.tr('当前'),
                                color: colors.primary,
                              )
                            else if (stamp != null)
                              Text(
                                stamp,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                if (draft.isNotEmpty)
                                  TextSpan(
                                    text: '${context.tr('草稿')} · ',
                                    style: TextStyle(
                                      color: colors.tertiary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                if (profile != null)
                                  TextSpan(
                                    text: '$profile · ',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                TextSpan(text: body.replaceAll('\n', ' ')),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
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
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
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
        width: 21,
        height: 21,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6.5),
          border: Border.all(color: color, width: 1.6),
        ),
        child: Text(
          count > 99 ? '∞' : '$count',
          style: TextStyle(
            fontSize: count > 9 ? 9.5 : 11.5,
            fontWeight: FontWeight.w800,
            color: color,
            height: 1,
          ),
        ),
      ),
    );
  }
}
