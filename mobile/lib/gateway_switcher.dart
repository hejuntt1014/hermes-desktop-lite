import 'package:material_ui/material_ui.dart';

import 'gateway.dart';
import 'gateway_book.dart';
import 'mobile_locale.dart';

enum SavedGatewayAction { check, signOut, forget }

typedef GatewaySelection = ({Gateway? gateway, SavedGatewayAction? leave});
typedef GatewayForm = Future<Gateway?> Function(
  BuildContext, {
  SavedGateway? saved,
});

Future<GatewaySelection?> showGatewaySwitcher(
  BuildContext context, {
  required Gateway active,
  required GatewayBook book,
  required Future<Gateway> Function(SavedGateway) connect,
  required Future<String?> Function(SavedGateway) check,
  required GatewayForm add,
  required VoidCallback cancelPending,
}) => showModalBottomSheet<GatewaySelection>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _GatewaySwitcher(
    active: active,
    book: book,
    connect: connect,
    check: check,
    add: add,
    cancelPending: cancelPending,
  ),
);

class _GatewaySwitcher extends StatefulWidget {
  const _GatewaySwitcher({
    required this.active,
    required this.book,
    required this.connect,
    required this.check,
    required this.add,
    required this.cancelPending,
  });

  final Gateway active;
  final GatewayBook book;
  final Future<Gateway> Function(SavedGateway) connect;
  final Future<String?> Function(SavedGateway) check;
  final GatewayForm add;
  final VoidCallback cancelPending;

  @override
  State<_GatewaySwitcher> createState() => _GatewaySwitcherState();
}

class _GatewaySwitcherState extends State<_GatewaySwitcher> {
  String? trying;
  ({String address, String? version, String? error})? feedback;

  @override
  void dispose() {
    widget.cancelPending();
    super.dispose();
  }

  Future<void> choose(SavedGateway entry) async {
    if (trying != null) return;
    setState(() {
      trying = entry.address;
      feedback = null;
    });
    try {
      final gateway = entry.usesToken && !entry.hasCredentials
          ? await widget.add(context, saved: entry)
          : await widget.connect(entry);
      if (gateway == null) {
        if (mounted) setState(() => trying = null);
        return;
      }
      if (mounted && ModalRoute.isCurrentOf(context) == true) {
        Navigator.pop<GatewaySelection>(context, (
          gateway: gateway,
          leave: null,
        ));
      } else {
        gateway.close();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          trying = null;
          feedback = (
            address: entry.address,
            version: null,
            error: error.toString(),
          );
        });
      }
    }
  }

  Future<void> add() async {
    final gateway = await widget.add(context);
    if (gateway == null) return;
    if (mounted && ModalRoute.isCurrentOf(context) == true) {
      Navigator.pop<GatewaySelection>(context, (gateway: gateway, leave: null));
    } else {
      gateway.close();
    }
  }

  Future<void> act(SavedGateway entry, SavedGatewayAction action) async {
    if (trying != null) return;
    if (action != SavedGatewayAction.check &&
        entry.address == widget.active.base.toString()) {
      Navigator.pop<GatewaySelection>(context, (gateway: null, leave: action));
      return;
    }
    setState(() {
      trying = entry.address;
      feedback = null;
    });
    try {
      switch (action) {
        case SavedGatewayAction.check:
          final version = await widget.check(entry);
          if (mounted) {
            setState(
              () => feedback = (
                address: entry.address,
                version: version,
                error: null,
              ),
            );
          }
        case SavedGatewayAction.signOut:
          await widget.book.signOut(entry.address);
        case SavedGatewayAction.forget:
          await widget.book.forget(entry.address);
      }
    } catch (error) {
      final message = switch (action) {
        SavedGatewayAction.check => error.toString(),
        SavedGatewayAction.signOut => '无法退出本机登录',
        SavedGatewayAction.forget => '无法移除已保存的网关',
      };
      if (mounted) {
        setState(
          () => feedback = (
            address: entry.address,
            version: null,
            error: message,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => trying = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = widget.active.base.toString();
    final signIn = widget.active.link == GatewayLink.signIn;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .62,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                context.tr('管理网关'),
                style: theme.textTheme.titleLarge,
              ),
            ),
            for (final entry in widget.book.entries)
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                leading: const Icon(Icons.dns_outlined, size: 21),
                title: Text(
                  entry.address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: entry.address == active || !entry.hasCredentials
                    ? Text(
                        context.tr(
                          entry.address == active && !signIn
                              ? '当前网关'
                              : '需要重新登录',
                        ),
                      )
                    : null,
                trailing: trying == entry.address
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : PopupMenuButton<SavedGatewayAction>(
                        enabled: trying == null,
                        tooltip: context.tr('网关操作'),
                        onSelected: (action) => act(entry, action),
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: SavedGatewayAction.check,
                            child: Text(context.tr('测试连接')),
                          ),
                          if (entry.hasCredentials)
                            PopupMenuItem(
                              value: SavedGatewayAction.signOut,
                              child: Text(context.tr('退出本机登录')),
                            ),
                          PopupMenuItem(
                            value: SavedGatewayAction.forget,
                            child: Text(context.tr('移除已保存的网关')),
                          ),
                        ],
                      ),
                onTap: trying != null || entry.address == active && !signIn
                    ? null
                    : () => choose(entry),
              ),
            if (feedback case final result?)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Text(
                  [
                    result.address,
                    context.tr(result.error ?? '连接与认证通过'),
                    ?result.version,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: result.error == null
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: Text(context.tr('添加网关')),
              onTap: trying == null ? add : null,
            ),
          ],
        ),
      ),
    );
  }
}
