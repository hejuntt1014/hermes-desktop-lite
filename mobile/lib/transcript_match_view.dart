import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'transcript_navigation.dart';

class TranscriptMatchText extends StatelessWidget {
  const TranscriptMatchText(this.match, {super.key, this.maxLines});

  final TranscriptMatchExcerpt match;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: match.text.substring(0, match.start)),
          TextSpan(
            text: match.text.substring(match.start, match.end),
            style: TextStyle(
              backgroundColor: colors.tertiaryContainer,
              color: colors.onTertiaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(text: match.text.substring(match.end)),
        ],
      ),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

class TranscriptMatchPreview extends StatelessWidget {
  const TranscriptMatchPreview(this.match, {super.key});

  final TranscriptMatchExcerpt match;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: context.tr('匹配片段'),
      child: Container(
        margin: const EdgeInsets.only(top: 5, bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.search_rounded, size: 17, color: colors.tertiary),
            const SizedBox(width: 8),
            Expanded(
              child: DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(height: 1.45),
                child: TranscriptMatchText(match, maxLines: 5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
