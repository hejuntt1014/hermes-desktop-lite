import 'package:material_ui/material_ui.dart';

import 'command_receipts.dart';
import 'mobile_locale.dart';
import 'slash_picker.dart';

class CommandReceiptTile extends StatelessWidget {
  const CommandReceiptTile({super.key, required this.receipt, this.onClosed});

  final CommandReceipt receipt;
  final VoidCallback? onClosed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          dense: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: const Icon(Icons.terminal_rounded, size: 20),
          title: Text(
            '/${receipt.command}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            receipt.output.isEmpty ? context.tr('命令已完成') : receipt.output,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right_rounded, size: 18),
          onTap: () async {
            await showSlashResult(context, receipt.command, receipt.output);
            onClosed?.call();
          },
        ),
      ),
    );
  }
}
