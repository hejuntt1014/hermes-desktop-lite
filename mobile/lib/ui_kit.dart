import 'dart:ui' show ImageFilter;

import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:material_ui/material_ui.dart';

/// Frosted, translucent surface: content behind it is blurred and tinted, the
/// edge is a hairline highlight instead of an outline, and a soft shadow lifts
/// it off the page. Every floating control in the chat uses this.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding = EdgeInsets.zero,
    this.shadow = true,
    this.opacity,
    this.tint,
    this.borderColor,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool shadow;

  /// Fill strength; defaults to a value tuned per brightness.
  final double? opacity;

  /// Fill colour before transparency; defaults to the surface colour.
  final Color? tint;

  /// Replaces the hairline highlight, e.g. to show a drop target.
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .35 : .07),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .2 : .03),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: shape,
              color:
                  (tint ??
                          (dark ? colors.surfaceContainerHigh : colors.surface))
                      .withValues(alpha: opacity ?? (dark ? .62 : .74)),
              border: Border.all(
                width: borderColor == null ? .7 : 1.4,
                color:
                    borderColor ??
                    (dark
                        ? Colors.white.withValues(alpha: .09)
                        : Colors.black.withValues(alpha: .05)),
              ),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// Round glass button for the floating chat chrome.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 44,
    this.dot = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  /// Small accent dot in the corner, e.g. for unread conversations.
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GlassSurface(
      radius: size / 2,
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            IconButton(
              tooltip: tooltip,
              onPressed: onPressed,
              iconSize: 21,
              style: IconButton.styleFrom(
                minimumSize: Size.square(size),
                foregroundColor: colors.onSurface,
              ),
              icon: Icon(icon),
            ),
            if (dot)
              Positioned(
                top: size * .2,
                right: size * .2,
                child: IgnorePointer(
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.surface, width: 1.5),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One row in a [showGlassMenu] popover.
class GlassMenuItem<T> {
  const GlassMenuItem({
    required this.value,
    required this.icon,
    required this.label,
    this.enabled = true,
    this.separated = false,
  });

  final T value;
  final IconData icon;
  final String label;
  final bool enabled;

  /// Draw a hairline above this item to start a new group.
  final bool separated;
}

/// Frosted popover anchored to [anchor] (global coordinates). It opens above
/// the anchor when there is more room there, and grows out of the anchor's
/// corner. [prominent] uses large round icon wells, for short action lists.
Future<T?> showGlassMenu<T>(
  BuildContext context, {
  required Rect anchor,
  required List<GlassMenuItem<T>> items,
  bool prominent = false,
  double width = 236,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return Navigator.of(context).push<T>(
    _GlassMenuRoute<T>(
      anchor: anchor,
      items: items,
      prominent: prominent,
      width: width,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

/// Global rectangle of the widget that owns [context], for menu anchoring.
Rect globalRectOf(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

class _GlassMenuRoute<T> extends PopupRoute<T> {
  _GlassMenuRoute({
    required this.anchor,
    required this.items,
    required this.prominent,
    required this.width,
    required this.barrierLabel,
  });

  final Rect anchor;
  final List<GlassMenuItem<T>> items;
  final bool prominent;
  final double width;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: .06);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 140);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final safe = media.padding;
    final above = anchor.top - safe.top > screen.height - anchor.bottom;
    final alignRight = anchor.center.dx > screen.width / 2;
    final left = alignRight
        ? (anchor.right - width).clamp(10.0, screen.width - width - 10)
        : anchor.left.clamp(10.0, screen.width - width - 10);
    final maxHeight = above
        ? anchor.top - safe.top - 16
        : screen.height - anchor.bottom - safe.bottom - 16;
    final origin = Alignment(alignRight ? 1 : -1, above ? 1 : -1);
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final menu = Material(
      type: MaterialType.transparency,
      child: FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: .86, end: 1.0).animate(curved),
          alignment: origin,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: width),
            child: GlassSurface(
              radius: prominent ? 30 : 22,
              opacity: Theme.of(context).brightness == Brightness.dark
                  ? .78
                  : .86,
              padding: EdgeInsets.symmetric(vertical: prominent ? 8 : 6),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, item) in items.indexed) ...[
                      if (item.separated && index > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: Divider(
                            height: 1,
                            thickness: .6,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                      _GlassMenuRow(
                        item: item,
                        prominent: prominent,
                        onTap: () => Navigator.pop(context, item.value),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Stack(
      children: [
        Positioned(
          left: left,
          top: above ? null : anchor.bottom + 8,
          bottom: above ? screen.height - anchor.top + 8 : null,
          width: width,
          child: menu,
        ),
      ],
    );
  }
}

class _GlassMenuRow<T> extends StatelessWidget {
  const _GlassMenuRow({
    required this.item,
    required this.prominent,
    required this.onTap,
  });

  final GlassMenuItem<T> item;
  final bool prominent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = item.enabled
        ? colors.onSurface
        : colors.onSurface.withValues(alpha: .35);
    final icon = Icon(item.icon, size: prominent ? 21 : 20, color: foreground);
    return InkWell(
      onTap: item.enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: prominent ? 12 : 16,
          vertical: prominent ? 3 : 0,
        ),
        child: SizedBox(
          height: prominent ? 44 : 42,
          child: Row(
            children: [
              if (prominent)
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.onSurface.withValues(alpha: .06),
                    shape: BoxShape.circle,
                  ),
                  child: icon,
                )
              else
                icon,
              SizedBox(width: prominent ? 14 : 13),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: prominent ? 16 : 15,
                    fontWeight: prominent ? FontWeight.w500 : FontWeight.w400,
                    color: foreground,
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

/// Reports its child's size after layout whenever it changes.
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({super.key, required this.onChange, super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeBox(onChange);

  @override
  void updateRenderObject(BuildContext context, _MeasureSizeBox renderObject) {
    renderObject.onChange = onChange;
  }
}

class _MeasureSizeBox extends RenderProxyBox {
  _MeasureSizeBox(this.onChange);

  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    final reported = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(reported));
  }
}

/// Compact pill used for sidebar filters and shortcuts.
class PillChip extends StatelessWidget {
  const PillChip({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = selected
        ? colors.surface
        : onTap == null
        ? colors.onSurface.withValues(alpha: .38)
        : colors.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? colors.onSurface : colors.surfaceContainerLow,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: foreground),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Inset grouped section: a small caption above one rounded card whose rows
/// are separated by hairlines.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .2,
                ),
              ),
            ),
          ),
          Material(
            color: colors.surface,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: ListTileTheme.merge(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              minTileHeight: 56,
              shape: const RoundedRectangleBorder(),
              child: Column(
                children: [
                  for (final (index, child) in children.indexed) ...[
                    if (index > 0)
                      Divider(
                        height: 1,
                        indent: 54,
                        color: colors.outlineVariant,
                      ),
                    child,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
