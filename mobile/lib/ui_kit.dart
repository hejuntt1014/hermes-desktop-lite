import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;

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

/// Full-bleed frosted layer: blurs whatever is behind it and washes it with
/// [tint], for drawers and overlays that cover the screen.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({
    super.key,
    required this.child,
    this.tint,
    this.blur = 30,
    this.opacity,
  });

  final Widget child;
  final Color? tint;
  final double blur;

  /// Wash strength; defaults to a heavy frost tuned per brightness.
  final double? opacity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: ColoredBox(
          color: (tint ?? theme.colorScheme.surface).withValues(
            alpha: opacity ?? (dark ? .72 : .8),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A page raised as a floating sheet over the current screen instead of
/// replacing it; swipe down or the close button dismisses it.
Route<T> floatingPageRoute<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) => ModalBottomSheetRoute<T>(
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
  modalBarrierColor: Colors.black.withValues(alpha: .22),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
  ),
  clipBehavior: Clip.antiAlias,
  builder: (sheet) =>
      FractionallySizedBox(heightFactor: .97, child: builder(sheet)),
);

/// Header for a [floatingPageRoute] page: round close button, centred title.
class FloatingPageBar extends StatelessWidget implements PreferredSizeWidget {
  const FloatingPageBar({super.key, required this.title});

  final String title;

  @override
  Size get preferredSize => const Size.fromHeight(72);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
    child: Row(
      children: [
        GlassIconButton(
          icon: Icons.close_rounded,
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 44),
      ],
    ),
  );
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
  Color? get barrierColor => Colors.black.withValues(alpha: .05);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 460);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 220);

  double get _rowHeight => prominent ? 50 : 42;
  double get _padding => prominent ? 8 : 6;

  /// Rows have fixed heights, so the final size is known before layout and
  /// the shell can morph straight to it.
  double get _contentHeight {
    var height = _padding * 2;
    for (final (index, item) in items.indexed) {
      if (item.separated && index > 0) height += 9;
      height += _rowHeight;
    }
    return height;
  }

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
    final height = math.min(_contentHeight, maxHeight);
    final target = Rect.fromLTWH(
      left,
      above ? anchor.top - 8 - height : anchor.bottom + 8,
      width,
      height,
    );
    final radius = prominent ? 30.0 : 22.0;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final content = Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(vertical: _padding),
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
    );
    // The menu starts as a blob the size of the button that opened it and
    // springs out to its full shape, so it reads as a droplet splitting off
    // the button; closing pulls it back in.
    return AnimatedBuilder(
      animation: animation,
      child: content,
      builder: (context, child) {
        final t = animation.value;
        final opening = animation.status != AnimationStatus.reverse;
        final shape = opening
            ? _dropletSpring.transform(t)
            : Curves.easeOutCubic.transform(t);
        final rect = Rect.lerp(anchor, target, shape)!;
        final reveal = ((t - (opening ? .3 : .45)) / .4).clamp(0.0, 1.0);
        return Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: GlassSurface(
                radius: lerpDouble(
                  anchor.shortestSide / 2,
                  radius,
                  shape.clamp(0.0, 1.0),
                )!,
                opacity: dark ? .78 : .86,
                child: OverflowBox(
                  alignment: Alignment(alignRight ? 1 : -1, above ? 1 : -1),
                  minWidth: width,
                  maxWidth: width,
                  minHeight: height,
                  maxHeight: height,
                  child: Opacity(opacity: reveal, child: child),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Lightly under-damped spring: about 8% overshoot, settled within the
/// transition, which gives the opening its liquid wobble.
class _DropletSpring extends Curve {
  const _DropletSpring();

  static final _simulation = SpringSimulation(
    const SpringDescription(mass: 1, stiffness: 260, damping: 20),
    0,
    1,
    0,
  );

  @override
  double transformInternal(double t) => _simulation.x(t * .46);
}

const _dropletSpring = _DropletSpring();

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


/// One entry in a [showGlassActionSheet].
class GlassSheetAction<T> {
  const GlassSheetAction({
    required this.value,
    required this.icon,
    required this.label,
    this.enabled = true,
    this.destructive = false,
  });

  final T value;
  final IconData icon;
  final String label;
  final bool enabled, destructive;
}

/// Fill for a rounded group or tile sitting on glass.
Color glassGroupColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Colors.white.withValues(alpha: .06)
    : Colors.black.withValues(alpha: .04);

/// The floating glass card the sidebar and conversation sheets share: grab
/// handle, a title with optional subtitle and header buttons, then [child].
class GlassSheetFrame extends StatelessWidget {
  const GlassSheetFrame({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.actions = const [],
    this.expand = false,
  });

  final String? title, subtitle;
  final List<Widget> actions;
  final Widget child;

  /// Lets [child] fill the frame's height (scrolling lists) instead of
  /// sizing the frame to its content.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final heading = title;
    final detail = subtitle;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: GlassSurface(
          radius: 30,
          opacity: dark ? .84 : .92,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Column(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: colors.onSurfaceVariant.withValues(alpha: .25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              if (heading != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    10,
                    actions.isEmpty ? 6 : 0,
                    actions.isEmpty ? 10 : 0,
                    10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                heading,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -.2,
                                ),
                              ),
                              if (detail != null && detail.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 1),
                                  child: Text(
                                    detail,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      ...actions,
                    ],
                  ),
                ),
              if (expand) Expanded(child: child) else Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows a glass sheet. List sheets pass [heightFactor] so the frame keeps
/// one height while its content loads.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext sheet) builder,
  double? heightFactor,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black.withValues(alpha: .18),
    builder: (sheet) => heightFactor == null
        ? builder(sheet)
        : SizedBox(
            height: MediaQuery.sizeOf(sheet).height * heightFactor,
            child: builder(sheet),
          ),
  );
}

/// Floating glass action sheet: a title, up to four quick actions as icon
/// tiles, then rows in rounded groups.
Future<T?> showGlassActionSheet<T>(
  BuildContext context, {
  String? title,
  String? subtitle,
  List<GlassSheetAction<T>> quick = const [],
  required List<List<GlassSheetAction<T>>> groups,
}) => showGlassSheet<T>(
  context,
  builder: (sheet) => GlassSheetFrame(
    title: title,
    subtitle: subtitle,
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (quick.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  for (final (index, action) in quick.indexed) ...[
                    if (index > 0) const SizedBox(width: 8),
                    Expanded(
                      child: GlassTile(
                        icon: action.icon,
                        label: action.label,
                        onTap: action.enabled
                            ? () => Navigator.pop(sheet, action.value)
                            : null,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          for (final (index, rows) in groups
              .where((rows) => rows.isNotEmpty)
              .indexed)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
              child: GlassGroup(
                children: [
                  for (final action in rows)
                    _SheetRow(
                      action: action,
                      onTap: () => Navigator.pop(sheet, action.value),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  ),
);

/// Icon-over-label tile, used for quick actions and the sidebar shortcuts.
/// A [count] badge sits on the icon when something is waiting.
class GlassTile extends StatelessWidget {
  const GlassTile({
    super.key,
    required this.icon,
    required this.label,
    this.count = 0,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = onTap != null
        ? colors.onSurface
        : colors.onSurface.withValues(alpha: .35);
    return Material(
      color: glassGroupColor(context),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Badge(
                isLabelVisible: count > 0,
                label: Text(count > 99 ? '99+' : '$count'),
                backgroundColor: colors.primary,
                textColor: colors.onPrimary,
                offset: const Offset(10, -6),
                child: Icon(icon, size: 22, color: foreground),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rounded group of rows on glass, with hairlines inset past the icons.
class GlassGroup extends StatelessWidget {
  const GlassGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final line = Theme.of(context).colorScheme.onSurface.withValues(alpha: .07);
    return Material(
      color: glassGroupColor(context),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, child) in children.indexed) ...[
            if (index > 0)
              Divider(height: .5, thickness: .5, indent: 50, color: line),
            child,
          ],
        ],
      ),
    );
  }
}

/// A row for glass list sheets: leading icon, title, optional subtitle and
/// trailing widget.
class GlassListRow extends StatelessWidget {
  const GlassListRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final detail = subtitle;
    final end = trailing;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 58),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            16,
            8,
            end == null ? 16 : 4,
            8,
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor ?? colors.onSurfaceVariant),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: colors.onSurface,
                      ),
                    ),
                    if (detail != null && detail.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              ?end,
            ],
          ),
        ),
      ),
    );
  }
}

/// Centred note for an empty, loading-failed or loading list sheet.
Widget glassSheetMessage(BuildContext context, String text, {Widget? action}) =>
    Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          ?action,
        ],
      ),
    );

class _SheetRow<T> extends StatelessWidget {
  const _SheetRow({required this.action, required this.onTap});

  final GlassSheetAction<T> action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tone = action.destructive ? colors.error : colors.onSurface;
    final foreground = action.enabled ? tone : tone.withValues(alpha: .35);
    return InkWell(
      onTap: action.enabled ? onTap : null,
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(action.icon, size: 20, color: foreground),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, color: foreground),
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
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: colors.outlineVariant, width: .8),
            ),
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
