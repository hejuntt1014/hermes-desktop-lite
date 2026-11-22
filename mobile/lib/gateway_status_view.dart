import 'dart:async';
import 'dart:io' show SocketException;

import 'package:material_ui/material_ui.dart';

import 'gateway.dart';
import 'mobile_locale.dart';
import 'mobile_shortcuts.dart';
import 'mobile_themes.dart';

String gatewayLinkLabel(GatewayLink link) => switch (link) {
  GatewayLink.idle => '未连接',
  GatewayLink.online => '已连接',
  GatewayLink.reconnecting => '正在重新连接网关',
  GatewayLink.offline => '已断开',
  GatewayLink.signIn => '需要重新登录',
};

const _platformNames = {
  'telegram': 'Telegram',
  'discord': 'Discord',
  'whatsapp': 'WhatsApp',
  'whatsapp_cloud': 'WhatsApp Cloud',
  'slack': 'Slack',
  'signal': 'Signal',
  'mattermost': 'Mattermost',
  'matrix': 'Matrix',
  'email': '电子邮件',
  'sms': '短信',
  'dingtalk': '钉钉',
  'api_server': 'API 服务',
  'webhook': 'Webhook',
  'msgraph_webhook': 'Microsoft Graph Webhook',
  'feishu': '飞书',
  'wecom': '企业微信',
  'wecom_callback': '企业微信回调',
  'weixin': '微信',
  'bluebubbles': 'BlueBubbles',
  'qqbot': 'QQ 机器人',
};

String _platformLabel(MobileStrings strings, String key) {
  final separator = key.indexOf(':');
  final id = separator < 0 ? key : key.substring(separator + 1);
  final name = _platformNames[id.toLowerCase()];
  if (name == null) return key;
  final label = strings.text(name);
  return separator < 0
      ? label
      : '${strings.profileName(key.substring(0, separator))} · $label';
}

class _GatewayHealth {
  _GatewayHealth(Json reply)
    : running = reply['gateway_running'] is bool
          ? reply['gateway_running'] as bool
          : null,
      version = reply['version'] is String ? reply['version'] as String : null,
      platforms = _platforms(reply['gateway_platforms']);

  final bool? running;
  final String? version;
  final List<(String, String)> platforms;

  static List<(String, String)> _platforms(Object? payload) {
    if (payload is! Json) return const [];
    final items = <(String, String)>[];
    for (final entry in payload.entries) {
      final platform = entry.value;
      final state = platform is Json
          ? platform['state'] ?? platform['status']
          : platform;
      if (state is String) items.add((entry.key, state.toLowerCase()));
    }
    return items
      ..sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
  }
}

typedef _GatewayRead<T> = ({T? value, String? issue});

Future<_GatewayRead<T>> _read<T>(Future<T> Function() operation) async {
  try {
    return (value: await operation(), issue: null);
  } on GatewayError catch (error) {
    final issue = switch (error.status) {
      401 || 403 => '当前登录无法读取此信息',
      404 || 405 || 501 => '此网关暂不提供此信息',
      _ => error.code == -32601 ? '此网关暂不提供此信息' : '暂时无法读取此信息',
    };
    return (value: null, issue: issue);
  } on SocketException {
    return (value: null, issue: '无法访问网关');
  } on TimeoutException {
    return (value: null, issue: '网关请求超时');
  } catch (_) {
    return (value: null, issue: '暂时无法读取此信息');
  }
}

class GatewayStatusPage extends StatefulWidget {
  const GatewayStatusPage({
    super.key,
    required this.gateway,
    required this.profile,
    this.onSelectGateway,
  });

  final Gateway gateway;
  final String profile;
  final VoidCallback? onSelectGateway;

  @override
  State<GatewayStatusPage> createState() => _GatewayStatusPageState();
}

class _GatewayStatusPageState extends State<GatewayStatusPage> {
  late final StreamSubscription<Json> _connection;
  _GatewayRead<_GatewayHealth> _health = (value: null, issue: null);
  _GatewayRead<bool> _inference = (value: null, issue: null);
  _GatewayRead<List<String>> _logs = (value: null, issue: null);
  bool _checking = false;
  bool _repairing = false;
  bool _more = false;
  DateTime? _checkedAt;
  int _readRevision = 0;

  Gateway get gateway => widget.gateway;
  static const _timeout = Duration(seconds: 10);
  static final _ansi = RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]');

  @override
  void initState() {
    super.initState();
    _connection = gateway.events.listen((event) {
      if (!mounted || event['type'] != 'client.connection') return;
      if (gateway.link == GatewayLink.online && !_repairing) {
        unawaited(_refresh());
      } else {
        setState(() {});
      }
    });
    unawaited(_refresh());
  }

  @override
  void dispose() {
    unawaited(_connection.cancel());
    super.dispose();
  }

  Future<List<String>> _readLogs(bool more) async {
    final reply = await gateway.api(
      'api/logs',
      query: {'file': 'gateway', 'lines': more ? '120' : '8'},
      timeout: _timeout,
    );
    final rows = reply['lines'];
    if (rows is! List) throw GatewayError('暂时无法读取此信息');
    return rows
        .whereType<String>()
        .take(more ? 120 : 8)
        .map(
          (line) =>
              String.fromCharCodes(line.replaceAll(_ansi, '').runes.take(1500)),
        )
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<bool> _checkInference() async {
    final reply = await gateway.call('setup.runtime_check', {
      if (widget.profile.isNotEmpty) 'profile': widget.profile,
    }, timeout: _timeout);
    final ready = reply['ok'];
    if (ready is! bool) throw GatewayError('暂时无法读取此信息');
    return ready;
  }

  Future<void> _refresh({bool moreLogs = false}) async {
    final revision = ++_readRevision;
    final more = moreLogs || _more;
    setState(() => _checking = true);
    final canCheckInference = gateway.link == GatewayLink.online;
    final (health, inference, logs) = await (
      moreLogs
          ? Future.value(_health)
          : _read(
              () async => _GatewayHealth(
                await gateway.api('api/status', timeout: _timeout),
              ),
            ),
      moreLogs
          ? Future.value(_inference)
          : canCheckInference
          ? _read(_checkInference)
          : Future.value((value: null as bool?, issue: null as String?)),
      _read(() => _readLogs(more)),
    ).wait;
    if (!mounted || revision != _readRevision) return;
    setState(() {
      _health = health;
      _inference = inference;
      if (!moreLogs) _checkedAt = DateTime.now();
      _logs = (
        value: logs.value ?? (moreLogs ? _logs.value : null),
        issue: logs.issue,
      );
      if (moreLogs && logs.value != null) _more = true;
      _checking = false;
    });
  }

  Future<void> _reconnect() async {
    if (_repairing) return;
    setState(() => _repairing = true);
    try {
      await gateway.retry(restart: true);
      if (mounted && gateway.link == GatewayLink.online) await _refresh();
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
  }

  Widget _value(String label, String value, {Color? color}) => Semantics(
    container: true,
    label: '$label\n$value',
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(color: color),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _section(Widget child) => Card(
    semanticContainer: false,
    margin: EdgeInsets.zero,
    elevation: 0,
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final link = gateway.link;
    final status = _health.value;
    final platforms = status?.platforms ?? const <(String, String)>[];
    final header = theme.textTheme.titleSmall;
    final checked = _checkedAt;
    void back() => Navigator.of(context).maybePop();
    return CallbackShortcuts(
      bindings: MobileShortcut.bind({MobileShortcut.dismiss: back}),
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(context.tr('网关状态')),
            actions: [
              IconButton(
                tooltip: context.tr('刷新网关状态'),
                onPressed: _checking || _repairing ? null : _refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Stack(
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 650),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
                      children: [
                        _section(
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.circle,
                                    size: 9,
                                    color: link == GatewayLink.online
                                        ? colors.primary
                                        : colors.outline,
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Text(
                                      context.tr(gatewayLinkLabel(link)),
                                      style: header,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              SelectableText(
                                gateway.base.toString(),
                                style: theme.textTheme.bodySmall,
                              ),
                              const SizedBox(height: 12),
                              if (status?.version ?? gateway.version
                                  case final String version)
                                _value(context.tr('后端版本'), version),
                              _value(
                                context.tr('网关进程'),
                                context.tr(switch (status?.running) {
                                  true => '网关运行中',
                                  false => '网关未运行',
                                  null =>
                                    _health.issue ??
                                        (_checking ? '等待状态' : '此网关暂不提供此信息'),
                                }),
                              ),
                              if (widget.profile.isNotEmpty)
                                _value(
                                  context.tr('当前档案'),
                                  context.strings.profileName(widget.profile),
                                ),
                              _value(
                                context.tr('推理状态'),
                                context.tr(switch ((link, _inference.value)) {
                                  (GatewayLink.online, true) => '推理已就绪',
                                  (GatewayLink.online, false) => '推理未就绪',
                                  (GatewayLink.online, null) =>
                                    _inference.issue ?? '等待状态',
                                  _ => '等待连接',
                                }),
                              ),
                              if (checked != null)
                                _value(
                                  context.tr('上次检查'),
                                  MaterialLocalizations.of(context)
                                      .formatTimeOfDay(
                                        TimeOfDay.fromDateTime(checked),
                                      ),
                                  color: colors.onSurfaceVariant,
                                ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 10,
                                runSpacing: 6,
                                children: [
                                  FilledButton.tonalIcon(
                                    icon: const Icon(
                                      Icons.link_rounded,
                                      size: 18,
                                    ),
                                    label: Text(
                                      context.tr(
                                        link == GatewayLink.signIn
                                            ? '登录'
                                            : '重新连接',
                                      ),
                                    ),
                                    onPressed: _repairing
                                        ? null
                                        : link == GatewayLink.signIn
                                        ? widget.onSelectGateway
                                        : _reconnect,
                                  ),
                                  if (widget.onSelectGateway != null)
                                    TextButton.icon(
                                      onPressed: widget.onSelectGateway,
                                      icon: const Icon(
                                        Icons.dns_outlined,
                                        size: 18,
                                      ),
                                      label: Text(context.tr('管理网关')),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (platforms.isNotEmpty) ...[
                          const SizedBox(height: 18),
                          _section(
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Semantics(
                                  header: true,
                                  container: true,
                                  child: Text(
                                    context.tr('消息平台'),
                                    style: header,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                for (final (name, state) in platforms)
                                  _value(
                                    _platformLabel(context.strings, name),
                                    context.tr(switch (state) {
                                      'connected' ||
                                      'running' ||
                                      'ready' => '已连接',
                                      'connecting' || 'starting' => '正在连接',
                                      'retrying' || 'reconnecting' => '正在重连',
                                      'disabled' => '已停用',
                                      'paused' => '已暂停',
                                      'failed' || 'fatal' => '连接失败',
                                      _ => '未连接',
                                    }),
                                    color: colors.onSurfaceVariant,
                                  ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        _section(
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Semantics(
                                      header: true,
                                      container: true,
                                      child: Text(
                                        context.tr('近期网关日志'),
                                        style: header,
                                      ),
                                    ),
                                  ),
                                  if (!_more)
                                    TextButton(
                                      onPressed: _checking
                                          ? null
                                          : () => _refresh(moreLogs: true),
                                      child: Text(context.tr('更多日志')),
                                    ),
                                ],
                              ),
                              if (_logs.issue case final issue?)
                                Text(context.tr(issue)),
                              if (_logs.value case final lines?
                                  when lines.isNotEmpty)
                                SelectableText(
                                  lines.join('\n'),
                                  style: theme.textTheme.bodySmall
                                      ?.merge(CustomThemeTokens.codeStyle(context))
                                      .copyWith(height: 1.48),
                                )
                              else if (_logs.issue == null)
                                Text(
                                  context.tr(_checking ? '正在读取…' : '暂无可显示的日志'),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_checking || _repairing)
                  const PositionedDirectional(
                    top: 0,
                    start: 0,
                    end: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
