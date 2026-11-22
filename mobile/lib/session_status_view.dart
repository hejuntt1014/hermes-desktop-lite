import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'gateway.dart';
import 'mobile_themes.dart';

typedef ContextMeter = ({int used, int maximum, bool estimated, num? cacheHit});

extension ContextMeterDisplay on ContextMeter {
  double get fraction => (used / maximum).clamp(0, 1);
  String get amount => '${_compactTokens(used)} / ${_compactTokens(maximum)}';

  static ContextMeter? fromWire(Json wire, {ContextMeter? known}) {
    int? count(String key) {
      final value = wire[key];
      return value is int && value >= 0 ? value : null;
    }

    final used = count('context_used') ?? count('last_prompt_tokens');
    final capacity = count('context_max') ?? count('context_length');
    if (used == null ||
        capacity == null ||
        capacity == 0 ||
        used == 0 && (known != null || wire['estimated_total'] == 0)) {
      return null;
    }
    final source = wire['context_source'];
    final cache = wire['cache_hit_pct'];
    return (
      used: used,
      maximum: capacity,
      estimated:
          wire['context_estimated'] == true ||
          source is String && source.isNotEmpty && source != 'provider_usage',
      cacheHit: cache is num && cache.isFinite
          ? cache.clamp(0, 100)
          : known?.cacheHit,
    );
  }
}

String _compactTokens(int count) {
  if (count < 1000) return '$count';
  if (count < 1000000) return '${(count / 1000).toStringAsFixed(1)}k';
  return '${(count / 1000000).toStringAsFixed(2)}M';
}

class ContextMeterLabel extends StatelessWidget {
  const ContextMeterLabel({super.key, required this.value});
  final ValueListenable<ContextMeter?> value;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: value,
    builder: (context, data, _) {
      if (data == null) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      return Flexible(
        child: Semantics(
          label: context.strings.format('上下文用量 {amount}', {
            "amount": data.amount,
          }),
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 8),
                SizedBox.square(
                  dimension: 10,
                  child: CircularProgressIndicator(
                    value: data.fraction,
                    strokeWidth: 1.5,
                    color: data.fraction >= .85
                        ? CustomThemeTokens.read(context, ThemeColor.warning) ??
                              colors.primary
                        : colors.primary,
                    backgroundColor: colors.outlineVariant,
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    data.amount,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

enum _ApprovalMode {
  manual('手动', '需要批准的操作会先询问'),
  smart('智能', '自动评估操作，需要时询问'),
  off('关闭审批', '操作无需审批');

  const _ApprovalMode(this.label, this.description);
  final String label, description;

  static _ApprovalMode? parse(Json reply) =>
      values.where((mode) => mode.name == reply['value']).firstOrNull;
}

class SessionStatusSheet extends StatefulWidget {
  const SessionStatusSheet({
    super.key,
    required this.gateway,
    required this.profile,
    required this.contextMeter,
    this.sessionApprovalBypass,
    this.refreshSessionApproval,
    this.refreshContext,
  });

  final Gateway gateway;
  final String profile;
  final ValueListenable<ContextMeter?> contextMeter;
  final ValueListenable<bool?>? sessionApprovalBypass;
  final Future<void> Function()? refreshSessionApproval;
  final Future<bool> Function()? refreshContext;

  @override
  State<SessionStatusSheet> createState() => _SessionStatusSheetState();
}

class _SessionStatusSheetState extends State<SessionStatusSheet> {
  late final StreamSubscription<Json> connection;
  int approvalRequest = 0;
  _ApprovalMode? mode;
  bool loadingApproval = false,
      loadingContext = false,
      contextUnavailable = false;
  String? approvalError;
  bool get approvalOnline => widget.gateway.link == GatewayLink.online;

  @override
  void initState() {
    super.initState();
    connection = widget.gateway.events.listen((event) {
      if (!mounted || event['type'] != 'client.connection') return;
      if (approvalOnline) {
        unawaited(loadApproval(reconnected: true));
      } else {
        setState(() {
          approvalRequest++;
          mode = null;
          loadingApproval = false;
          approvalError = '网关连接中断';
        });
      }
    });
    if (approvalOnline) {
      unawaited(loadApproval());
    } else {
      approvalError = '网关连接中断';
    }
    refreshContext();
  }

  @override
  void dispose() {
    unawaited(connection.cancel());
    super.dispose();
  }

  Future<void> loadApproval({
    _ApprovalMode? next,
    bool reconnected = false,
  }) async {
    if (!approvalOnline || loadingApproval && !reconnected) return;
    final request = ++approvalRequest;
    setState(() {
      loadingApproval = true;
      approvalError = null;
    });
    bool current() => mounted && request == approvalRequest && approvalOnline;
    final refreshingSession = widget.refreshSessionApproval?.call();
    try {
      final value = await widget.gateway.call(
        next == null ? 'config.get' : 'config.set',
        {
          'key': 'approvals.mode',
          'profile': widget.profile,
          'value': ?next?.name,
        },
        timeout: const Duration(seconds: 15),
      );
      final received = _ApprovalMode.parse(value);
      if (received == null || next != null && received != next) {
        throw GatewayError('网关未确认审批模式');
      }
      if (current()) setState(() => mode = received);
    } catch (_) {
      if (current()) {
        setState(() {
          if (next != null) mode = null;
          approvalError = next == null ? '暂时无法读取审批模式' : '未收到网关确认，请刷新后查看';
        });
      }
    } finally {
      await refreshingSession;
      if (current()) setState(() => loadingApproval = false);
    }
  }

  Future<void> refreshContext() async {
    final read = widget.refreshContext;
    if (read == null || loadingContext) return;
    setState(() => loadingContext = true);
    final refreshed = await read();
    if (!mounted) return;
    setState(() {
      loadingContext = false;
      contextUnavailable = !refreshed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .78,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('会话状态'),
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('关闭'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              if (widget.refreshContext != null ||
                  widget.contextMeter.value != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.tr('上下文用量'),
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: context.tr('刷新上下文用量'),
                      onPressed: loadingContext || widget.refreshContext == null
                          ? null
                          : refreshContext,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                    ),
                  ],
                ),
                ValueListenableBuilder(
                  valueListenable: widget.contextMeter,
                  builder: (context, data, _) {
                    if (data == null) {
                      return Text(
                        loadingContext
                            ? context.tr('正在读取…')
                            : contextUnavailable
                            ? context.tr('暂时无法读取上下文用量')
                            : context.tr('暂无上下文用量'),
                        style: caption,
                      );
                    }
                    final rate = (data.fraction * 100).round();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 8,
                      children: [
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 10,
                          runSpacing: 4,
                          children: [
                            Expanded(
                              child: Text(
                                context.strings.format('{amount} 词元', {
                                  'amount': data.amount,
                                }),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              data.estimated
                                  ? context.strings.format('{value}% · 估算', {
                                      'value': rate,
                                    })
                                  : '$rate%',
                              style: caption,
                            ),
                          ],
                        ),
                        LinearProgressIndicator(
                          value: data.fraction,
                          minHeight: 5,
                          borderRadius: BorderRadius.circular(3),
                          semanticsLabel: context.tr('上下文用量'),
                          semanticsValue: '$rate%',
                        ),
                        if (data.cacheHit case final hit?)
                          Text(
                            context.strings.format('缓存命中 {value}%', {
                              "value": hit.round(),
                            }),
                            style: caption,
                          ),
                        if (contextUnavailable)
                          Text(context.tr('暂时无法刷新'), style: caption),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 18),
                const Divider(),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.tr('档案审批模式'),
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          context.strings.profileName(widget.profile),
                          style: caption,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('刷新审批模式'),
                    onPressed: loadingApproval || !approvalOnline
                        ? null
                        : loadApproval,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                  ),
                ],
              ),
              if (loadingApproval) const LinearProgressIndicator(minHeight: 2),
              if (approvalError case final error?)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    context.tr(error),
                    style: caption?.copyWith(color: colors.error),
                  ),
                ),
              if (widget.sessionApprovalBypass case final bypass?
                  when mode != null && mode != _ApprovalMode.off)
                ValueListenableBuilder(
                  valueListenable: bypass,
                  builder: (context, active, _) => active != true
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 8),
                          child: Text(context.tr('当前会话免审批'), style: caption),
                        ),
                ),
              for (final item in _ApprovalMode.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  minTileHeight: 56,
                  minLeadingWidth: 24,
                  title: Text(context.tr(item.label)),
                  subtitle: Text(context.tr(item.description)),
                  selected: item == mode,
                  trailing: item == mode
                      ? Icon(
                          Icons.check_rounded,
                          color: colors.primary,
                          size: 20,
                        )
                      : null,
                  enabled: approvalOnline && mode != null && !loadingApproval,
                  onTap:
                      !approvalOnline ||
                          mode == null ||
                          loadingApproval ||
                          mode == item
                      ? null
                      : () => loadApproval(next: item),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
