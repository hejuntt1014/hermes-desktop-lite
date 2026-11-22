import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';

import 'background_notice.dart';
import 'gateway.dart';
import 'media_gallery.dart';
import 'message_content.dart';
import 'mobile_locale.dart';

class BackgroundNoticeTile extends StatelessWidget {
  const BackgroundNoticeTile({
    super.key,
    required this.notice,
    required this.gateway,
    required this.profile,
    required this.session,
    this.gallery,
    this.baseDirectory,
    this.documentPath,
    this.onOpenDocument,
    this.initiallyExpanded = false,
  });

  final BackgroundNotice notice;
  final Gateway gateway;
  final String profile;
  final String? session, baseDirectory;
  final Iterable<GalleryImage> Function()? gallery;
  final String? Function(Uri)? documentPath;
  final void Function(String, String?)? onOpenDocument;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = notice.process
        ? context.tr('后台进程已结束')
        : notice.taskCount > 1
        ? context.strings.format('后台委派已完成 · {count} 项结果', {
            'count': notice.taskCount,
          })
        : context.tr('后台委派已完成');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          dense: true,
          minTileHeight: 44,
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(
            notice.process
                ? Icons.terminal_rounded
                : Icons.account_tree_outlined,
            color: colors.onSurfaceVariant,
            size: 18,
          ),
          title: Text(label, style: theme.textTheme.labelLarge),
          children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: IconButton(
                tooltip: context.tr('复制通知原文'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: notice.raw));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.tr('已复制原文'))),
                    );
                  }
                },
                icon: const Icon(Icons.copy_outlined, size: 18),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 265),
              child: SingleChildScrollView(
                primary: false,
                padding: const EdgeInsets.fromLTRB(13, 0, 13, 10),
                child: MessageContent(
                  body: notice.report.isEmpty ? notice.raw : notice.report,
                  gateway: gateway,
                  profile: profile,
                  session: session,
                  gallery: gallery,
                  baseDirectory: baseDirectory,
                  documentPath: documentPath,
                  onOpenDocument: onOpenDocument,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
