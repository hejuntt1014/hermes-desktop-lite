import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';

enum SessionTitleColor {
  red('红色', 0xffad3544, 0xffdd4b4b),
  orange('橙色', 0xffa24d20, 0xffdd944b),
  gold('黄色', 0xff796800, 0xffdddd4b),
  olive('黄绿色', 0xff59701e, 0xff94dd4b),
  green('绿色', 0xff317341, 0xff4bdd4b),
  jade('翡翠绿', 0xff1b6b52, 0xff4bdd94),
  teal('青色', 0xff196a76, 0xff4bdddd),
  blue('蓝色', 0xff2a5f9a, 0xff4b94dd),
  indigo('靛蓝', 0xff4848a7, 0xff4b4bdd),
  purple('紫色', 0xff70459e, 0xff944bdd),
  magenta('品红', 0xff99437f, 0xffdd4bdd),
  rose('玫瑰色', 0xffa53865, 0xffdd4b94);

  const SessionTitleColor(this.label, this._ink, this._swatch);
  final String label;
  final int _ink, _swatch;
  Color get swatch => Color(_swatch);

  static SessionTitleColor? fromWire(Object? name) =>
      values.where((color) => color.name == name).firstOrNull;

  Color onBackground(Color background) {
    final luminance = background.computeLuminance() + .05;
    double contrast(Color color) {
      final foreground = color.computeLuminance() + .05;
      return foreground > luminance
          ? foreground / luminance
          : luminance / foreground;
    }

    final target = luminance * luminance > .0525 ? Colors.black : Colors.white;
    final base = target == Colors.black ? Color(_ink) : swatch;
    if (contrast(base) >= 4.5) return base;
    // Keep the chosen hue while making the title readable on custom themes.
    var low = 0.0;
    var high = 1.0;
    for (var i = 0; i < 8; i++) {
      final mid = (low + high) / 2;
      if (contrast(Color.lerp(base, target, mid)!) >= 4.5) {
        high = mid;
      } else {
        low = mid;
      }
    }
    return Color.lerp(base, target, high)!;
  }
}

Future<({SessionTitleColor? color})?> chooseSessionTitleColor(
  BuildContext context, {
  required String name,
  required SessionTitleColor? selected,
}) => showModalBottomSheet<({SessionTitleColor? color})>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (sheet) {
    final theme = Theme.of(sheet);
    final colors = theme.colorScheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(sheet.tr('会话标题颜色'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    child: Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: selected?.onBackground(
                          colors.surfaceContainerLow,
                        ),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final option in SessionTitleColor.values)
                      Semantics(
                        label: sheet.tr(option.label),
                        selected: selected == option,
                        button: true,
                        onTap: () => Navigator.pop(sheet, (color: option)),
                        child: ExcludeSemantics(
                          child: InkResponse(
                            radius: 24,
                            onTap: () => Navigator.pop(sheet, (color: option)),
                            child: SizedBox.square(
                              dimension: 48,
                              child: Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: option.swatch,
                                    border: Border.all(
                                      color: selected == option
                                          ? colors.onSurface
                                          : colors.outlineVariant,
                                      width: selected == option ? 2 : 1,
                                    ),
                                  ),
                                  child: SizedBox.square(
                                    dimension: 33,
                                    child: selected == option
                                        ? Icon(
                                            Icons.check_rounded,
                                            color:
                                                option.swatch
                                                        .computeLuminance() >
                                                    .18
                                                ? Colors.black
                                                : Colors.white,
                                            size: 18,
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(
                    Icons.format_color_reset_outlined,
                    size: 19,
                  ),
                  title: Text(sheet.tr('无颜色')),
                  selected: selected == null,
                  trailing: selected == null
                      ? const Icon(Icons.check_rounded, size: 19)
                      : null,
                  onTap: () => Navigator.pop<({SessionTitleColor? color})>(
                    sheet,
                    (color: null),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  },
);
