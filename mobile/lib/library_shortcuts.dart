import 'package:material_ui/material_ui.dart';

import 'ui_kit.dart';

/// One destination in [LibraryShortcuts].
class LibraryShortcut {
  const LibraryShortcut({
    required this.icon,
    required this.label,
    this.count = 0,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback? onTap;
}

/// The sidebar's quick destinations as one glass capsule split into equal
/// segments, icon and label on one line, in the same neutral glass as the
/// search and settings pill at the bottom.
class LibraryShortcuts extends StatelessWidget {
  const LibraryShortcuts({super.key, required this.items});

  final List<LibraryShortcut> items;

  @override
  Widget build(BuildContext context) {
    final line = Theme.of(context).colorScheme.onSurface.withValues(alpha: .08);
    return GlassSurface(
      radius: 22,
      shadow: false,
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              for (final (index, item) in items.indexed) ...[
                if (index > 0)
                  SizedBox(
                    height: 18,
                    child: VerticalDivider(width: 1, thickness: 1, color: line),
                  ),
                Expanded(child: _Segment(item)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment(this.item);

  final LibraryShortcut item;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = item.onTap != null;
    final foreground = enabled
        ? colors.onSurface
        : colors.onSurface.withValues(alpha: .3);
    final count = item.count > 99 ? '99+' : '${item.count}';
    return Semantics(
      button: true,
      enabled: enabled,
      label: item.count > 0 ? '${item.label} $count' : item.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: item.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(item.icon, size: 17, color: foreground),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
              if (item.count > 0) ...[
                const SizedBox(width: 5),
                Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  height: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.onSurface,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    count,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      color: colors.surface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
