import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';

enum SplitPaneRole {
  sessions(272, 304, 420, 440, '调整会话侧栏宽度'),
  files(232, 280, 420, 400, '调整文件列表宽度');

  const SplitPaneRole(
    this.minimum,
    this.standard,
    this.maximum,
    this.contentMinimum,
    this.resizeLabel,
  );

  static const gutter = 16.0;
  final double minimum, standard, maximum, contentMinimum;
  final String resizeLabel;

  bool fits(double width) => width >= minimum + gutter + contentMinimum;

  double constrain(double width, double preferred) {
    final available = width - gutter - contentMinimum;
    return preferred
        .clamp(minimum, available.clamp(minimum, maximum))
        .toDouble();
  }
}

class ResizableSplitPane extends StatefulWidget {
  const ResizableSplitPane({
    super.key,
    required this.role,
    required this.preferredWidth,
    required this.onWidthChanged,
    required this.content,
    this.list,
  });

  final SplitPaneRole role;
  final double preferredWidth;
  final Future<void> Function(double?) onWidthChanged;
  final Widget? list;
  final Widget content;

  @override
  State<ResizableSplitPane> createState() => _ResizableSplitPaneState();
}

class _ResizableSplitPaneState extends State<ResizableSplitPane> {
  double? dragWidth;
  bool dragging = false;
  int widthRevision = 0;

  Future<void> updateWidth(double? width) async {
    final revision = ++widthRevision;
    setState(() {
      dragWidth = width ?? widget.role.standard;
      dragging = false;
    });
    try {
      await widget.onWidthChanged(width);
    } catch (_) {
      if (mounted && widthRevision == revision) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('无法保存分栏宽度'))));
      }
    } finally {
      if (mounted && widthRevision == revision) {
        setState(() => dragWidth = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final role = widget.role;
      final leading = widget.list;
      final visible = leading != null && role.fits(bounds.maxWidth);
      final colors = Theme.of(context).colorScheme;
      final rtl = Directionality.of(context) == TextDirection.rtl;
      final width = role.constrain(
        bounds.maxWidth,
        dragWidth ?? widget.preferredWidth,
      );
      double constrain(double candidate) =>
          role.constrain(bounds.maxWidth, candidate);
      final larger = constrain(width + 24);
      final smaller = constrain(width - 24);
      final label = context.tr(role.resizeLabel);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (visible) ...[
            SizedBox(
              key: const ValueKey('split-list'),
              width: width,
              child: leading,
            ),
            Semantics(
              slider: true,
              label: label,
              value: width.round().toString(),
              increasedValue: larger > width ? larger.round().toString() : null,
              decreasedValue: smaller < width
                  ? smaller.round().toString()
                  : null,
              onIncrease: larger > width ? () => updateWidth(larger) : null,
              onDecrease: smaller < width ? () => updateWidth(smaller) : null,
              onTap: () => updateWidth(null),
              onTapHint: context.tr('恢复默认宽度'),
              excludeSemantics: true,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () => updateWidth(null),
                  onHorizontalDragStart: (_) => setState(() {
                    widthRevision++;
                    dragWidth = width;
                    dragging = true;
                  }),
                  onHorizontalDragUpdate: (event) => setState(() {
                    final delta = rtl ? -event.delta.dx : event.delta.dx;
                    dragWidth = constrain((dragWidth ?? width) + delta);
                  }),
                  onHorizontalDragEnd: (_) => updateWidth(dragWidth ?? width),
                  onHorizontalDragCancel: () => setState(() {
                    dragWidth = null;
                    dragging = false;
                  }),
                  child: SizedBox(
                    width: SplitPaneRole.gutter,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(width: 1, color: colors.outlineVariant),
                        Container(
                          width: 3,
                          height: 36,
                          decoration: BoxDecoration(
                            color: dragging
                                ? colors.primary
                                : colors.onSurfaceVariant.withValues(
                                    alpha: .52,
                                  ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          Expanded(key: const ValueKey('split-content'), child: widget.content),
        ],
      );
    },
  );
}
