import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'mobile_themes.dart';
import 'gateway.dart';
import 'session_activity.dart';

class SessionActivityPage extends StatefulWidget {
  const SessionActivityPage({
    super.key,
    required this.service,
    required this.title,
    this.monitor,
  });
  final SessionActivityService service;
  final String title;
  final SessionActivityMonitor? monitor;

  @override
  State<SessionActivityPage> createState() => _SessionActivityPageState();
}

class _SessionActivityPageState extends State<SessionActivityPage> {
  late final monitor =
      widget.monitor ?? (SessionActivityMonitor(widget.service)..watch(true));

  @override
  void dispose() {
    if (widget.monitor == null) monitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: monitor,
    builder: (context, _) => buildPage(context),
  );

  Widget buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final online = monitor.online;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('会话活动')),
        actions: [
          IconButton(
            tooltip: context.tr('刷新活动'),
            onPressed: online && !monitor.refreshing
                ? () => monitor.refresh(manual: true)
                : null,
            icon: const Icon(Icons.refresh_rounded, size: 21),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: RefreshIndicator(
              onRefresh: () => monitor.refresh(manual: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (!online)
                    Padding(
                      padding: EdgeInsets.only(top: 14),
                      child: Text(context.tr('网关暂时断开，正在等待连接')),
                    ),
                  const SizedBox(height: 18),
                  section(
                    ActivityKind.agents,
                    monitor.items(ActivityKind.agents),
                  ),
                  const SizedBox(height: 22),
                  section(
                    ActivityKind.processes,
                    monitor.items(ActivityKind.processes),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget section(ActivityKind kind, List<SessionWork> items) {
    final theme = Theme.of(context);
    final opening = monitor.loading(kind) && items.isEmpty;
    final failure = monitor.failure(kind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.tr(kind.label),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        if (opening)
          const LinearProgressIndicator(minHeight: 2)
        else if (failure != null || items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              failure != null
                  ? context.tr(failure)
                  : (kind == ActivityKind.agents
                        ? context.tr('暂无运行中的子代理')
                        : context.tr('暂无运行中的后台进程')),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final row in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(13),
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
                title: Text(
                  context.tr(row.title),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    row.status == 'queued'
                        ? context.tr('排队中')
                        : context.tr('运行中'),
                    if (row.detail.isNotEmpty) row.detail,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => showWorkOutput(context, monitor, row),
              ),
            ),
          ),
      ],
    );
  }
}

Future<void> showWorkOutput(
  BuildContext context,
  SessionActivityMonitor monitor,
  SessionWork item,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => _WorkOutput(monitor: monitor, item: item),
  ),
);

class SessionWorkSummary extends StatefulWidget {
  const SessionWorkSummary({super.key, required this.monitor});

  final SessionActivityMonitor monitor;

  @override
  State<SessionWorkSummary> createState() => _SessionWorkSummaryState();
}

class _SessionWorkSummaryState extends State<SessionWorkSummary> {
  ActivityKind? expanded;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.monitor,
    builder: (context, _) {
      final monitor = widget.monitor;
      if (!monitor.online || !monitor.hasWork) return const SizedBox.shrink();
      final colors = Theme.of(context).colorScheme;
      final groups = {
        for (final kind in [ActivityKind.processes, ActivityKind.agents])
          if (monitor.items(kind) case final items when items.isNotEmpty)
            kind: items,
      };
      final rows = MediaQuery.viewInsetsOf(context).bottom == 0
          ? groups[expanded]
          : null;
      return Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(18, 3, 18, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 7,
              children: [
                for (final group in groups.entries)
                  ChoiceChip(
                    visualDensity: VisualDensity.compact,
                    showCheckmark: false,
                    selected: expanded == group.key,
                    avatar: Icon(
                      group.key == ActivityKind.processes
                          ? Icons.terminal_rounded
                          : Icons.account_tree_outlined,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                    label: Text(
                      '${context.tr(group.key.label)} · ${group.value.length}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    onSelected: (selected) {
                      if (selected) {
                        FocusManager.instance.primaryFocus?.unfocus();
                      }
                      setState(() => expanded = selected ? group.key : null);
                    },
                  ),
              ],
            ),
            if (rows != null)
              Material(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 135),
                  child: ListView.builder(
                    primary: false,
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      return ListTile(
                        dense: true,
                        minTileHeight: 43,
                        contentPadding: EdgeInsetsDirectional.only(
                          start: 12 + 8 * row.depth.clamp(0, 4).toDouble(),
                          end: 10,
                        ),
                        title: Text(
                          context.tr(row.title),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: row.detail.isEmpty
                            ? null
                            : Text(
                                row.detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: Text(
                          context.tr(row.status == 'queued' ? '排队中' : '运行中'),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                        onTap: () => showWorkOutput(context, monitor, row),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _WorkOutput extends StatefulWidget {
  const _WorkOutput({required this.monitor, required this.item});
  final SessionActivityMonitor monitor;
  final SessionWork item;
  @override
  State<_WorkOutput> createState() => _WorkOutputState();
}

class _WorkOutputState extends State<_WorkOutput> {
  late SessionWork item = widget.item;
  late String output = item.output;
  late final AppLifecycleListener lifecycle;
  Timer? update;
  bool loading = false, foreground = true, retained = true;
  String? failure;
  bool get process => item.kind == ActivityKind.processes;
  bool get mayRefresh => process || item.active;

  @override
  void initState() {
    super.initState();
    if (!process) widget.monitor.addListener(syncAgent);
    lifecycle = AppLifecycleListener(
      onHide: () {
        foreground = false;
        update?.cancel();
      },
      onResume: () {
        foreground = true;
        if (item.active && ModalRoute.isCurrentOf(context) == true) {
          unawaited(read());
        }
      },
    );
    unawaited(read());
  }

  void syncAgent() {
    final next = widget.monitor.agent(item.id);
    if (!mounted || next == null || identical(next, item)) return;
    setState(() {
      item = next;
      if (!next.active) {
        update?.cancel();
        retained = true;
        failure = null;
        if (next.output.isNotEmpty) output = next.output;
      }
    });
  }

  Future<void> read() async {
    if (!mounted || loading || !mayRefresh) return;
    update?.cancel();
    setState(() => loading = true);
    try {
      if (process) {
        final rows = await widget.monitor.service.list(
          ActivityKind.processes,
          includeFinished: true,
        );
        if (!mounted) return;
        final refreshed = rows.where((row) => row.id == item.id).firstOrNull;
        setState(() {
          retained = refreshed != null;
          failure = retained ? null : '后台进程记录已不可用';
          if (refreshed != null) {
            item = refreshed;
            if (refreshed.output.isNotEmpty) output = refreshed.output;
          }
        });
      } else {
        final result = await widget.monitor.service.agentOutput(item.id);
        if (!mounted || !item.active) return;
        setState(() {
          if (result?.isNotEmpty == true) output = result!;
          failure = null;
        });
      }
    } catch (error) {
      if (!mounted || !mayRefresh) return;
      final unsupported = error is GatewayError && error.code == -32601;
      setState(() {
        retained = !unsupported;
        failure = unsupported ? '当前网关未提供活动输出' : '暂时无法读取活动输出';
      });
    } finally {
      if (mounted) {
        setState(() => loading = false);
        if (retained && item.active && foreground) {
          update = Timer(const Duration(seconds: 3), () {
            if (mounted && ModalRoute.isCurrentOf(context) == true) {
              unawaited(read());
            }
          });
        }
      }
    }
  }

  @override
  void dispose() {
    if (!process) widget.monitor.removeListener(syncAgent);
    update?.cancel();
    lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        IconButton(
          tooltip: context.tr('刷新输出'),
          icon: const Icon(Icons.refresh_rounded),
          onPressed: loading || !mayRefresh ? null : read,
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (loading) const LinearProgressIndicator(minHeight: 2),
          if (retained)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text(
                item.exitCode != null
                    ? context.strings.format('已退出 · 退出码 {code}', {
                        'code': item.exitCode!,
                      })
                    : context.tr(switch (item.status) {
                        'queued' => '排队中',
                        'running' => '运行中',
                        'exited' => '已退出',
                        'timeout' => '已超时',
                        'failed' => '失败',
                        'cancelled' || 'canceled' || 'interrupted' => '已取消',
                        _ => '已完成',
                      }),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          if (failure case final error?)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text(
                context.tr(error),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: output.isEmpty
                ? Center(child: Text(context.tr(loading ? '正在读取…' : '暂无输出')))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: SelectableText(
                      output,
                      style: CustomThemeTokens.codeStyle(context).copyWith(
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}
