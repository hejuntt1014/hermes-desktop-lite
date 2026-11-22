import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import 'chat_tabs.dart' show sessionTitle;
import 'mobile_locale.dart';
import 'mobile_themes.dart';
import 'session_colors.dart';
import 'session_activity.dart' show ConversationActivity;

SystemUiOverlayStyle liteSystemChrome(ColorScheme scheme) {
  final icons = scheme.brightness == Brightness.dark
      ? Brightness.light
      : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: scheme.brightness,
    statusBarIconBrightness: icons,
    systemNavigationBarColor: scheme.surface,
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
  );
}

enum LitePalette {
  standard('default', '默认', Color(0xffb72d75)),
  rose('pink', '粉色', Color(0xff9b3864)),
  paper('paper', '纸黄', Color(0xff80561e)),
  blueHour('terminal', '蓝调时刻', Color(0xff2f6ba0));

  const LitePalette(this.id, this.label, this.seed);
  final String id, label;
  final Color seed;
}

ColorScheme liteColors(Brightness brightness, LitePalette palette) {
  final dark = brightness == Brightness.dark;
  final seed = ColorScheme.fromSeed(
    seedColor: palette.seed,
    brightness: brightness,
  );
  return switch (palette) {
    LitePalette.standard => seed.copyWith(
      primary: dark ? const Color(0xffffaed2) : const Color(0xffa91f61),
      onPrimary: dark ? const Color(0xff431226) : Colors.white,
      surface: dark ? const Color(0xff201e23) : Colors.white,
      surfaceContainerLow: dark
          ? const Color(0xff27242a)
          : const Color(0xfff6f4f6),
      surfaceContainer: dark
          ? const Color(0xff2d2930)
          : const Color(0xfff0edf1),
      surfaceContainerHigh: dark
          ? const Color(0xff343037)
          : const Color(0xffebe7ec),
      onSurface: dark ? const Color(0xfff8f4f7) : const Color(0xff231f27),
      onSurfaceVariant: dark
          ? const Color(0xffc0b7c4)
          : const Color(0xff69616e),
      outlineVariant: dark ? const Color(0xff423b46) : const Color(0xffe9e4ea),
      secondaryContainer: dark
          ? const Color(0xff432838)
          : const Color(0xfffbeaf2),
      onSecondaryContainer: dark
          ? const Color(0xfff9e3ee)
          : const Color(0xff562239),
    ),
    LitePalette.rose when !dark => seed.copyWith(
      surface: const Color(0xfffff8fb),
      surfaceContainerLow: const Color(0xfffdf0f6),
      surfaceContainerHigh: const Color(0xfff5dee8),
      onSurface: const Color(0xff513441),
      onSurfaceVariant: const Color(0xff795464),
      outlineVariant: const Color(0xffe7bfce),
      secondaryContainer: const Color(0xfff5dee8),
      onSecondaryContainer: const Color(0xff513441),
    ),
    LitePalette.paper when !dark => seed.copyWith(
      surface: const Color(0xfffffbef),
      surfaceContainerLow: const Color(0xfffaf1da),
      surfaceContainerHigh: const Color(0xfff0e2bd),
      onSurface: const Color(0xff463724),
      onSurfaceVariant: const Color(0xff715b40),
      outlineVariant: const Color(0xffdfcda7),
      secondaryContainer: const Color(0xfff3e7c7),
      onSecondaryContainer: const Color(0xff463724),
    ),
    LitePalette.blueHour when dark => seed.copyWith(
      surface: const Color(0xff282c34),
      surfaceContainerLow: const Color(0xff303641),
      surfaceContainerHigh: const Color(0xff394354),
      onSurface: const Color(0xffe8eaf0),
      onSurfaceVariant: const Color(0xffb6c1d0),
      outlineVariant: const Color(0xff464d5a),
      secondaryContainer: const Color(0xff3b485a),
      onSecondaryContainer: const Color(0xffeff4fc),
    ),
    _ => seed,
  };
}

ThemeData liteTheme(
  Brightness brightness, [
  LitePalette palette = LitePalette.standard,
  MobileTheme? custom,
]) {
  final scheme = custom?.scheme() ?? liteColors(brightness, palette);
  final canvas =
      custom?.color(ThemeColor.canvas) ??
      (palette == LitePalette.standard
          ? brightness == Brightness.dark
                ? const Color(0xff1c1a1e)
                : const Color(0xfffdfbfd)
          : scheme.surface);
  final fieldRadius = BorderRadius.circular(16);
  final interfaceFont = ThemeFont.interface.resolve(
    custom?.font(ThemeFont.interface),
  );
  return ThemeData(
    colorScheme: scheme,
    fontFamily: interfaceFont,
    scaffoldBackgroundColor: canvas,
    extensions: [if (custom != null) CustomThemeTokens(custom)],
    appBarTheme: AppBarTheme(
      backgroundColor: custom?.color(ThemeColor.chrome) ?? canvas,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: liteSystemChrome(scheme),
      titleTextStyle: TextStyle(
        fontFamily: interfaceFont,
        color: scheme.onSurface,
        fontSize: 19,
        fontWeight: FontWeight.w700,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 46),
        shape: const StadiumBorder(),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: .30),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.secondaryContainer
              : scheme.surfaceContainerLow,
        ),
        side: const WidgetStatePropertyAll(BorderSide.none),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(borderRadius: fieldRadius),
      enabledBorder: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: scheme.primary.withValues(alpha: .65)),
      ),
    ),
  );
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 34});
  final double size;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * .29),
    child: Image.asset(
      'assets/hermes.webp',
      width: size,
      height: size,
      fit: BoxFit.cover,
      alignment: const Alignment(0, -.48),
      excludeFromSemantics: true,
    ),
  );
}

DateTime? sessionTime(Map<String, dynamic> row) {
  for (final key in ['last_active', 'started_at']) {
    final value = row[key];
    if (value is num && value.isFinite && value > 0) {
      return DateTime.fromMillisecondsSinceEpoch(
        (value < 1e11 ? value * 1000 : value).round(),
      );
    }
    if (value is String) {
      if (DateTime.tryParse(value) case final time?) return time.toLocal();
    }
  }
  return null;
}

DateTime _sessionDay(DateTime time) {
  final shifted = time.subtract(const Duration(hours: 4));
  return DateTime.utc(shifted.year, shifted.month, shifted.day);
}

({String? label, DateTime? month}) sessionGroup(
  DateTime time, {
  required DateTime now,
}) {
  final today = _sessionDay(now);
  final date = _sessionDay(time);
  final days = today.difference(date).inDays;
  final label = switch (days) {
    <= 0 => '今天',
    1 => '昨天',
    _ when days < today.weekday => '本周早些时候',
    _ when days < today.weekday + 7 => '上周',
    _ when today.year == date.year && today.month == date.month => '本月早些时候',
    _ => null,
  };
  return (
    label: label,
    month: label == null ? DateTime.utc(date.year, date.month) : null,
  );
}

class ConversationIndicator extends StatelessWidget {
  const ConversationIndicator({
    super.key,
    this.activity,
    this.unread = false,
    this.size = 16,
  });

  final ConversationActivity? activity;
  final bool unread;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (activity == null && !unread) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Icon(
      switch (activity) {
        ConversationActivity.waiting => Icons.chat_bubble_outline_rounded,
        ConversationActivity.running => Icons.timelapse_rounded,
        ConversationActivity.background => Icons.bolt_outlined,
        null => Icons.circle,
      },
      size: activity == null ? size / 2 : size,
      color: activity == ConversationActivity.waiting
          ? colors.tertiary
          : colors.primary,
      semanticLabel: context.tr(activity?.label ?? '未读'),
    );
  }
}

class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.row,
    required this.onTap,
    this.selected = false,
    this.activity,
    this.onLongPress,
    this.depth = 0,
    this.lastBranch = true,
    this.trailing,
    this.titleColor,
  });
  final Map<String, dynamic> row;
  final VoidCallback onTap;
  final bool selected, lastBranch;
  final ConversationActivity? activity;
  final int depth;
  final Widget? trailing;
  final VoidCallback? onLongPress;
  final SessionTitleColor? titleColor;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final background = selected
        ? CustomThemeTokens.read(context, ThemeColor.selection) ??
              c.secondaryContainer
        : CustomThemeTokens.read(context, ThemeColor.sidebar) ?? c.surface;
    final title = sessionTitle(row) ?? context.tr('未命名会话');
    final time = sessionTime(row);
    final stamp = time == null
        ? ''
        : sessionGroup(time, now: DateTime.now()).label == '今天'
        ? MaterialLocalizations.of(context).formatTimeOfDay(
            TimeOfDay.fromDateTime(time),
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          )
        : MaterialLocalizations.of(context).formatShortMonthDay(time);
    final radius = BorderRadius.circular(12);
    return Semantics(
      container: true,
      selected: selected,
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: depth.clamp(0, 3) * 9.0),
        child: Material(
          color: selected ? background : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            onLongPress: onLongPress,
            onSecondaryTap: onLongPress,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 10, end: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    if (depth > 0)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 7),
                        child: Text(
                          lastBranch ? '╰' : '├',
                          semanticsLabel: context.tr('分支'),
                          style: TextStyle(
                            color: c.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    if (row['pinned'] == true)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Icons.push_pin_outlined,
                          size: 14,
                          color: c.primary,
                          semanticLabel: context.tr('已置顶'),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          color:
                              titleColor?.onBackground(background) ??
                              (selected ? c.onSecondaryContainer : c.onSurface),
                          fontWeight: selected || row['unread'] == true
                              ? FontWeight.w700
                              : FontWeight.w500,
                          height: 1.4,
                        ),
                      ),
                    ),
                    if (activity != null || row['unread'] == true)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: ConversationIndicator(
                          activity: activity,
                          unread: row['unread'] == true,
                        ),
                      ),
                    if (stamp.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Text(
                          stamp,
                          style: TextStyle(
                            fontSize: 11,
                            color: c.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ?trailing,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
