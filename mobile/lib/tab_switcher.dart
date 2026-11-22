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
    final cardHeight = (width - 28 - (columns - 1) * 14) / columns / 1.02;
    return scroll = ScrollController(
      initialScrollOffset: row <= 1 ? 0 : (row - 1) * (cardHeight + 14),
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
    final columns = width >= 900
        ? 4
        : width >= 600
        ? 3
        : 2;
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
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                          childAspectRatio: 1.02,
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
    final footer = [?profile, ?stamp].join(' · ');
    final surface = dark ? colors.surfaceContainerHigh : colors.surface;
    const radius = 22.0;
    return Semantics(
      selected: selected,
      button: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius + 3),
          border: Border.all(
            color: selected ? colors.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? .3 : .06),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            color: surface,
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              onSecondaryTap: onLongPress,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Preview pane: the conversation's latest words, fading
                  // out, as a stand-in for a page thumbnail.
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ColoredBox(
                            color: dark
                                ? Colors.white.withValues(alpha: .03)
                                : colors.surfaceContainerLow,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
                              child: ShaderMask(
                                shaderCallback: (rect) => const LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.black, Colors.transparent],
                                  stops: [.55, 1],
                                ).createShader(rect),
                                blendMode: BlendMode.dstIn,
                                child: Text(
                                  body,
                                  overflow: TextOverflow.clip,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                    height: 1.5,
                                    fontStyle: draft.isNotEmpty
                                        ? FontStyle.italic
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Material(
                            color: surface.withValues(alpha: .9),
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: onClose,
                              child: Tooltip(
                                message: context.tr('关闭标签'),
                                child: SizedBox.square(
                                  dimension: 28,
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 16,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (draft.isNotEmpty)
                          Positioned(
                            left: 10,
                            bottom: 8,
                            child: _Tag(
                              label: context.tr('草稿'),
                              color: colors.tertiary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (activity != null || unread) ...[
                              ConversationIndicator(
                                activity: activity,
                                unread: unread,
                                size: 13,
                              ),
                              const SizedBox(width: 5),
                            ],
                            Expanded(
                              child: Text(
                                tab.title ??
                                    context.tr(
                                      tab.session == null ? '新会话' : '未命名会话',
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -.2,
                                  color: titleColor?.onBackground(surface),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (footer.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              footer,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
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
