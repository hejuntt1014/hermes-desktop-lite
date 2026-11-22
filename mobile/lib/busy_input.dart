import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'gateway.dart';
import 'mobile_locale.dart';

enum BusyInputMode {
  interrupt('中断', '优先处理新消息', 'session.redirect'),
  queue('排队', '当前回复结束后发送', null),
  steer('引导', '把新消息补充到当前回复', 'session.steer');

  const BusyInputMode(this.label, this.detail, this.correction);

  final String label, detail;
  final String? correction;
}

class BusyInputSettings {
  const BusyInputSettings(this.gateway, this.profile);

  final Gateway gateway;
  final String profile;

  Future<BusyInputMode> read() async {
    final config = await gateway.api('api/config', query: {'profile': profile});
    final display = config['display'];
    final mode = display is Json ? display['busy_input_mode'] : null;
    final wire = mode is String ? mode.trim().toLowerCase() : '';
    return BusyInputMode.values
            .where((item) => item.name == wire)
            .firstOrNull ??
        BusyInputMode.interrupt;
  }

  Future<void> save(BusyInputMode mode) async {
    final reply = await gateway.api(
      'api/config',
      method: 'PUT',
      query: {'profile': profile},
      body: {
        'config': {
          'display': {'busy_input_mode': mode.name},
        },
      },
    );
    if (reply['ok'] != true) throw GatewayError('未收到网关确认');
  }
}

Future<void> showBusyInputSettings(
  BuildContext context, {
  required BusyInputSettings settings,
  required String profileLabel,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) =>
      _BusyInputSheet(settings: settings, profileLabel: profileLabel),
);

class _BusyInputSheet extends StatefulWidget {
  const _BusyInputSheet({required this.settings, required this.profileLabel});

  final BusyInputSettings settings;
  final String profileLabel;

  @override
  State<_BusyInputSheet> createState() => _BusyInputSheetState();
}

class _BusyInputSheetState extends State<_BusyInputSheet> {
  late final StreamSubscription<Json> _connection;
  Future<BusyInputMode>? _mode;
  bool _saving = false;
  String? _error;

  Gateway get _gateway => widget.settings.gateway;

  @override
  void initState() {
    super.initState();
    if (_gateway.usable) _mode = _read();
    _connection = _gateway.events.listen((event) {
      if (!mounted || event['type'] != 'client.connection') return;
      setState(() {
        _error = null;
        _mode = _gateway.usable ? _read() : null;
      });
    });
  }

  @override
  void dispose() {
    unawaited(_connection.cancel());
    super.dispose();
  }

  Future<BusyInputMode> _read() async {
    final link = _gateway.connectionRevision;
    final mode = await widget.settings.read();
    if (link != _gateway.connectionRevision) throw GatewayDisconnected();
    return mode;
  }

  Future<void> _select(BusyInputMode mode) async {
    if (_saving || !_gateway.usable) return;
    final link = _gateway.connectionRevision;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.settings.save(mode);
      if (link != _gateway.connectionRevision) throw GatewayDisconnected();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '无法保存忙时发送设置';
          _mode = _gateway.usable ? _read() : null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: FutureBuilder<BusyInputMode>(
          future: _mode,
          builder: (context, snapshot) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('忙时发送'),
                        style: theme.textTheme.titleLarge,
                      ),
                      Text(
                        widget.profileLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_gateway.usable &&
                    (_saving ||
                        snapshot.connectionState == ConnectionState.waiting))
                  const LinearProgressIndicator(minHeight: 2),
                if (!_gateway.usable)
                  ListTile(title: Text(context.tr('网关连接中断')))
                else if (_error case final message?)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      context.tr(message),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                if (_gateway.usable &&
                    snapshot.connectionState == ConnectionState.done &&
                    snapshot.hasError)
                  ListTile(
                    title: Text(context.tr('无法读取忙时发送设置')),
                    trailing: TextButton(
                      onPressed: () => setState(() => _mode = _read()),
                      child: Text(context.tr('重试')),
                    ),
                  )
                else if (snapshot.data case final mode?
                    when _gateway.usable &&
                        snapshot.connectionState == ConnectionState.done)
                  for (final item in BusyInputMode.values)
                    ListTile(
                      selected: mode == item,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      leading: Icon(switch (item) {
                        BusyInputMode.interrupt => Icons.alt_route_rounded,
                        BusyInputMode.queue => Icons.playlist_add_rounded,
                        BusyInputMode.steer => Icons.tune_rounded,
                      }),
                      title: Text(context.tr(item.label)),
                      subtitle: Text(context.tr(item.detail)),
                      trailing: mode == item
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: _saving || mode == item
                          ? null
                          : () => _select(item),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
