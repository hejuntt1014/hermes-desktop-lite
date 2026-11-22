part of 'chat.dart';

/// Empty-conversation landing: a quiet greeting plus the last few
/// conversations as cards, anchored just above the composer.
class _NewChatStart extends StatelessWidget {
  const _NewChatStart({required this.recent, required this.onOpen});
  final List<Json> recent;
  final ValueChanged<Json> onOpen;

  /// A warmer greeting than the clock: the day of the week, like a person
  /// would say it.
  static String greeting(DateTime now) => const [
    '星期一愉快',
    '星期二愉快',
    '星期三愉快',
    '星期四愉快',
    '星期五愉快',
    '星期六愉快',
    '星期日愉快',
  ][now.weekday - 1];

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.expand();
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, space) {
        if (space.maxHeight < 120) return const SizedBox.expand();
        final rows = recent.take(space.maxHeight < 420 ? 1 : 2).toList();
        return Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              reverse: true,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: BrandMark(size: 44)),
                  const SizedBox(height: 18),
                  Text(
                    context.tr(greeting(DateTime.now())),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.tr('今天想让 Hermes 做什么？'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (rows.isNotEmpty) ...[
                    const SizedBox(height: 32),
                    Padding(
                      padding: const EdgeInsets.only(left: 6, bottom: 8),
                      child: Text(
                        context.tr('最近会话'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (final row in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _RecentCard(row: row, onTap: () => onOpen(row)),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.row, required this.onTap});
  final Json row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final title = (row['title'] ?? row['preview'] ?? context.tr('未命名会话'))
        .toString();
    final preview = row['title'] == null ? null : row['preview']?.toString();
    final time = sessionTime(row);
    return GlassSurface(
      radius: 22,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.onSurface.withValues(alpha: .05),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (preview != null && preview.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            preview.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (time != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      MaterialLocalizations.of(context)
                          .formatShortMonthDay(time),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
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
