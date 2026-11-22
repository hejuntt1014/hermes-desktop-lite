import 'dart:async';
import 'dart:io' show HttpException, SocketException;

import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'gateway.dart';
import 'ui_kit.dart';


const cronJobsPath = 'api/cron/jobs';

final _activeCronTriggers = Expando<ValueNotifier<Set<(String, String)>>>();

ValueNotifier<Set<(String, String)>> _cronTriggers(Gateway gateway) =>
    _activeCronTriggers[gateway] ??= ValueNotifier<Set<(String, String)>>({});

String _jobPath(String id) => '$cronJobsPath/${Uri.encodeComponent(id)}';

bool _belongsTo(Json row, String profile) =>
    row['profile'] == null || row['profile'] == '' || row['profile'] == profile;

bool _cronChanged(Json event, String profile) {
  final payload = event['payload'];
  if (event['type'] == 'cron.changed') {
    return _belongsTo(event, profile) &&
        (payload is! Json || _belongsTo(payload, profile));
  }
  return event['type'] == 'client.connection' &&
      payload is Json &&
      payload['state'] == 'online' &&
      payload['resumed'] == true;
}

String _jobTitle(Json job, String fallback) {
  for (final key in ['name', 'prompt', 'script', 'id']) {
    final value = job[key]?.toString().split('\n').first.trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return fallback;
}

String _scheduleText(Json job) {
  final schedule = job['schedule'];
  return (job['schedule_display'] ??
          (schedule is Json
              ? schedule['display'] ?? schedule['expr']
              : schedule) ??
          '')
      .toString();
}

String _editableSchedule(Json? job) {
  if (job == null) return '';
  final schedule = job['schedule'];
  if (schedule is String) return schedule.trim();
  if (schedule is Json) {
    final runAt = schedule['run_at'];
    if (schedule['kind'] == 'once' &&
        runAt is String &&
        runAt.trim().isNotEmpty) {
      return runAt.trim();
    }
    for (final value in [schedule['expr'], runAt]) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    final minutes = schedule['minutes'];
    if (schedule['kind'] == 'interval' && minutes is int && minutes > 0) {
      return 'every ${minutes}m';
    }
  }
  return _scheduleText(job).trim();
}

DateTime? _scheduledInstant(String expression) {
  final value = DateTime.tryParse(expression.trim());
  return value != null && value.isUtc ? value.toLocal() : null;
}

String _stateText(Json job) {
  final execution = job['live_execution'];
  if (execution is Json &&
      {'running', 'claimed'}.contains(execution['status'])) {
    return '执行中';
  }
  return switch (job['state']) {
    'running' => '执行中',
    'paused' => '已暂停',
    'completed' => '已完成',
    'error' => '执行异常',
    _ => job['enabled'] == false ? '已停用' : '待调度',
  };
}

DateTime? _runTime(Object? value) => switch (value) {
  DateTime x => x.toLocal(),
  String x => DateTime.tryParse(x)?.toLocal(),
  num x when x.isFinite && x.abs() <= 8640000000000 =>
    DateTime.fromMillisecondsSinceEpoch((x * 1000).round()),
  _ => null,
};

String _jobStatus(
  BuildContext context,
  Json job,
  DateTime now, {
  bool triggering = false,
}) {
  if (triggering) return context.tr('执行中');
  final state = _stateText(job);
  final next = _runTime(job['next_run_at']);
  if (next == null || state != '待调度') return context.tr(state);
  final seconds = next.difference(now).inSeconds;
  return switch (seconds) {
    <= -901 => context.tr('已逾期'),
    <= 0 => context.tr('待执行'),
    < 60 => context.tr('即将执行'),
    < 3600 => context.strings.format('{count} 分钟后', {'count': seconds ~/ 60}),
    < 86400 => context.strings.format('{count} 小时后', {
      'count': seconds ~/ 3600,
    }),
    _ => context.strings.format('{count} 天后', {'count': seconds ~/ 86400}),
  };
}

int _compareJobs(Json a, Json b) {
  final first = _runTime(a['next_run_at']);
  final second = _runTime(b['next_run_at']);
  if (first != null && second == null) return -1;
  if (first == null && second != null) return 1;
  if (first != null && second != null) {
    final order = first.compareTo(second);
    if (order != 0) return order;
  }
  return _jobTitle(a, '').compareTo(_jobTitle(b, ''));
}

Future<List<Json>> _readJobs(Gateway gateway, String profile) async {
  final rows = await gateway.apiRows(cronJobsPath, query: {'profile': profile});
  return rows.where((row) {
    final id = row['id'];
    return id is String && id.isNotEmpty && _belongsTo(row, profile);
  }).toList()..sort(_compareJobs);
}

String _formatDate(BuildContext context, dynamic value) {
  final local = _runTime(value);
  if (local == null) return '';
  final locale = MaterialLocalizations.of(context);
  return '${locale.formatShortDate(local)} ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

String? _outcome(String? value) => switch (value?.trim().toUpperCase()) {
  'COMPLETED' || 'SUCCESS' => '已完成',
  'FAILED' || 'ERROR' => '失败',
  'CANCELLED' => '已取消',
  'MISSED' => '已错过',
  'RUNNING' || 'CLAIMED' => '执行中',
  _ => null,
};

const _stopReason = 'cancelled on request (Stop)';

class _CronRun {
  _CronRun(this.row);
  final Json row;

  bool get script =>
      row['source'] == 'cron_output' ||
      (row['id'] is String && (row['id'] as String).startsWith('cron_output:'));
  String? get sessionId {
    final id = row['session_id'] ?? row['id'];
    return !script &&
            id is String &&
            id.isNotEmpty &&
            _runTime(row['ended_at']) != null
        ? id
        : null;
  }

  String get _title => row['title']?.toString().trim() ?? '';
  String? get outcome =>
      _outcome(_title.split(' · ').first) ??
      _outcome(row['status']?.toString()) ??
      (row['is_active'] == true ? '执行中' : null);

  String title(BuildContext context) {
    final delimiter = _title.indexOf(' · ');
    final text = _outcome(_title.split(' · ').first) == null
        ? _title
        : delimiter < 0
        ? ''
        : _title.substring(delimiter + 3).trim();
    if (text == _stopReason) return context.tr(script ? '脚本运行' : '运行记录');
    if (script &&
        (text.isEmpty ||
            text.startsWith('# Cron Job:') ||
            text == 'Script-only run')) {
      return context.tr('脚本运行');
    }
    return text.isEmpty ? context.tr('运行记录') : text;
  }

  String preview(BuildContext context) {
    final raw = row['preview']?.toString().trim() ?? '';
    if (raw == _stopReason) return '';
    if (!raw.startsWith('# Cron Job:')) return raw;
    final mode = raw.indexOf('**Mode:**');
    final output = mode < 0 ? -1 : raw.indexOf(' --- ', mode);
    if (output >= 0) return raw.substring(output + ' --- '.length).trim();
    final status = raw.indexOf('**Status:**', mode < 0 ? 0 : mode);
    if (status < 0) return mode < 0 ? raw : '';
    final text = raw.substring(status + '**Status:**'.length).trim();
    return switch (text) {
      'silent (empty output)' => context.tr('本次无输出'),
      'silent (wakeAgent=false)' => context.tr('本次未唤醒智能体'),
      'no_change (agent run suppressed)' => context.tr('无变化，本次未唤醒智能体'),
      _ => text,
    };
  }
}

Future<({T? value, String? error})> _readCron<T>(
  Future<T> Function() read,
) async {
  try {
    return (value: await read(), error: null);
  } catch (error) {
    return (value: null, error: _cronError(error));
  }
}

String _cronError(Object error, {String fallback = '暂时无法读取此信息'}) =>
    switch (error) {
      HttpException() || SocketException() => '无法访问网关',
      TimeoutException() => '网关请求超时',
      GatewayError(:final message) => message,
      _ => fallback,
    };

enum CronSheetIntent { open, create, manage }

typedef CronSheetChoice = ({CronSheetIntent intent, String? jobId});

/// The sidebar's quick look at this profile's jobs, in the same glass sheet
/// as the active and unread lists. Editing and run history stay on
/// [CronPage]; the choice says where to land there.
Future<CronSheetChoice?> chooseCronJob(
  BuildContext context, {
  required Gateway gateway,
  required String profile,
}) {
  var pending = _readJobs(gateway, profile);
  return showGlassSheet<CronSheetChoice>(
    context,
    heightFactor: .6,
    builder: (sheet) => StatefulBuilder(
      builder: (context, update) {
        final colors = Theme.of(context).colorScheme;
        void choose(CronSheetIntent intent, [String? jobId]) =>
            Navigator.pop(sheet, (intent: intent, jobId: jobId));
        return GlassSheetFrame(
          title: context.tr('定时任务'),
          subtitle: profile,
          expand: true,
          actions: [
            IconButton(
              tooltip: context.tr('新建定时任务'),
              onPressed: () => choose(CronSheetIntent.create),
              icon: const Icon(Icons.add_rounded),
            ),
            IconButton(
              tooltip: context.tr('管理定时任务'),
              onPressed: () => choose(CronSheetIntent.manage),
              icon: const Icon(Icons.open_in_full_rounded, size: 20),
            ),
          ],
          child: FutureBuilder(
            future: pending,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return glassSheetMessage(
                  context,
                  context.tr('定时任务读取失败'),
                  action: TextButton.icon(
                    onPressed: () => update(() {
                      pending = _readJobs(gateway, profile);
                    }),
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(context.tr('重新读取')),
                  ),
                );
              }
              final jobs = snapshot.data ?? const <Json>[];
              if (jobs.isEmpty) {
                return glassSheetMessage(
                  context,
                  context.tr('暂无定时任务'),
                  action: TextButton.icon(
                    onPressed: () => choose(CronSheetIntent.create),
                    icon: const Icon(Icons.add_rounded),
                    label: Text(context.tr('新建定时任务')),
                  ),
                );
              }
              final now = DateTime.now();
              final triggers = _cronTriggers(gateway).value;
              return SingleChildScrollView(
                child: GlassGroup(
                  children: [
                    for (final job in jobs)
                      GlassListRow(
                        icon: Icons.schedule_rounded,
                        iconColor: switch (_stateText(job)) {
                          '执行中' => colors.primary,
                          '执行异常' => colors.error,
                          '已暂停' || '已停用' || '已完成' =>
                            colors.onSurfaceVariant.withValues(alpha: .45),
                          _ => null,
                        },
                        title: _jobTitle(job, context.tr('定时任务')),
                        subtitle: [
                          _jobStatus(
                            context,
                            job,
                            now,
                            triggering: triggers.contains((
                              profile,
                              job['id'] as String,
                            )),
                          ),
                          _scheduleText(job),
                        ].where((s) => s.isNotEmpty).join(' · '),
                        trailing: Icon(
                          Icons.chevron_right_rounded,
                          size: 20,
                          color: colors.onSurfaceVariant,
                        ),
                        onTap: () => choose(
                          CronSheetIntent.open,
                          job['id'] as String,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        );
      },
    ),
  );
}

class CronPage extends StatefulWidget {
  const CronPage({
    super.key,
    required this.gateway,
    required this.profile,
    required this.openConversation,
    this.initialJobId,
    this.startCreating = false,
  });
  final Gateway gateway;
  final String profile;
  final ValueChanged<Json> openConversation;

  /// Opens the editor for a new job as soon as the page appears.
  final bool startCreating;
  final String? initialJobId;

  @override
  State<CronPage> createState() => _CronPageState();
}

class _CronPageState extends State<CronPage> {
  late final triggers = _cronTriggers(widget.gateway);
  late final StreamSubscription<Json> subscription;
  late final Timer clock;
  List<Json> jobs = [];
  bool loading = true;
  bool separateDetailOpen = false;
  String? failure;
  String? selection;
  bool initialSelectionHandled = false;
  bool inlineDetails = false;
  int request = 0;

  @override
  void initState() {
    super.initState();
    clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && ModalRoute.isCurrentOf(context) == true) setState(() {});
    });
    subscription = widget.gateway.events.listen((event) {
      if (mounted && _cronChanged(event, widget.profile)) {
        unawaited(load());
      }
    });
    load();
    if (widget.startCreating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(create());
      });
    }
  }

  @override
  void dispose() {
    clock.cancel();
    subscription.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (!mounted) return;
    final id = ++request;
    setState(() {
      loading = true;
      failure = null;
    });
    try {
      final rows = await _readJobs(widget.gateway, widget.profile);
      if (!mounted || id != request) return;
      final pending = initialSelectionHandled ? null : widget.initialJobId;
      final initial = pending == null
          ? null
          : rows.where((job) => job['id'] == pending).firstOrNull;
      setState(() {
        jobs = rows;
        if (!jobs.any((job) => job['id'] == selection)) selection = null;
        if (pending != null) {
          initialSelectionHandled = true;
          selection = initial == null ? null : pending;
          if (initial == null) failure = '该定时任务已不存在';
        }
      });
      if (initial != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              selection == pending &&
              !inlineDetails &&
              ModalRoute.isCurrentOf(context) == true) {
            unawaited(openJob(initial, inline: false));
          }
        });
      }
    } catch (e) {
      if (mounted && id == request) setState(() => failure = _cronError(e));
    } finally {
      if (mounted && id == request) setState(() => loading = false);
    }
  }

  Future<void> create() async {
    final saved = await Navigator.of(context).push<Json>(
      MaterialPageRoute(
        builder: (_) =>
            _CronEditor(gateway: widget.gateway, profile: widget.profile),
      ),
    );
    if (saved == null || !mounted) return;
    final id = saved['id'];
    if (id is! String || id.isEmpty || !_belongsTo(saved, widget.profile)) {
      await load();
      return;
    }
    request++;
    setState(() {
      jobs = [...jobs.where((job) => job['id'] != id), saved]
        ..sort(_compareJobs);
      failure = null;
      loading = false;
    });
    final inline = inlineDetails;
    await openJob(saved, inline: inline);
    if (inline && mounted) await load();
  }

  Future<void> openJob(Json job, {required bool inline}) async {
    if (separateDetailOpen) return;
    setState(() {
      selection = job['id'] as String;
      separateDetailOpen = !inline;
    });
    if (inline) return;
    final Json? run;
    try {
      run = await Navigator.of(context).push<Json>(
        MaterialPageRoute(
          builder: (_) => _CronJobPage(
            gateway: widget.gateway,
            profile: widget.profile,
            initial: job,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => separateDetailOpen = false);
    }
    if (!mounted) return;
    if (run != null) {
      widget.openConversation(run);
    } else {
      await load();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: triggers,
    builder: (context, _) => buildPage(context),
  );

  Widget buildPage(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.tr('定时任务')),
            Text(
              widget.profile,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: context.tr('刷新定时任务'),
            onPressed: loading ? null : load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: context.tr('新建定时任务'),
            onPressed: create,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, bounds) {
            final inline = inlineDetails =
                bounds.maxWidth >= 700 && !separateDetailOpen;
            final list = buildList(inline: inline);
            if (!inline) return list;
            final selected = jobs
                .where((job) => job['id'] == selection)
                .firstOrNull;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: (bounds.maxWidth * .34).clamp(240.0, 320.0),
                  child: list,
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: selected == null
                      ? Center(child: Text(context.tr('选择一项定时任务')))
                      : _CronJobPage(
                          key: ValueKey(selected['id']),
                          gateway: widget.gateway,
                          profile: widget.profile,
                          initial: selected,
                          onOpenRun: widget.openConversation,
                          onChanged: load,
                          onDeleted: () {
                            if (!mounted) return;
                            if (selection == selected['id']) {
                              setState(() => selection = null);
                            }
                            unawaited(load());
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget buildList({required bool inline}) {
    final colors = Theme.of(context).colorScheme;
    final now = DateTime.now();
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (loading) const LinearProgressIndicator(),
          if (failure != null)
            ListTile(
              title: Text(context.tr(failure!)),
              trailing: TextButton(
                onPressed: load,
                child: Text(context.tr('重试')),
              ),
            ),
          if (!loading && failure == null && jobs.isEmpty)
            Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text(context.tr('暂无定时任务'))),
            ),
          for (final job in jobs)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Card(
                elevation: 0,
                color: colors.surfaceContainerLow,
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  selected: inline && job['id'] == selection,
                  selectedTileColor: colors.secondaryContainer,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 3,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: colors.surfaceContainer,
                    foregroundColor: colors.onSurfaceVariant,
                    child: const Icon(Icons.schedule_outlined, size: 19),
                  ),
                  title: Text(
                    _jobTitle(job, context.tr('定时任务')),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    [
                      _jobStatus(
                        context,
                        job,
                        now,
                        triggering: triggers.value.contains((
                          widget.profile,
                          job['id'] as String,
                        )),
                      ),
                      _scheduleText(job),
                    ].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => openJob(job, inline: inline),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CronJobPage extends StatefulWidget {
  const _CronJobPage({
    super.key,
    required this.gateway,
    required this.profile,
    required this.initial,
    this.onOpenRun,
    this.onChanged,
    this.onDeleted,
  });
  final Gateway gateway;
  final String profile;
  final Json initial;
  final ValueChanged<Json>? onOpenRun;
  final VoidCallback? onChanged, onDeleted;
  @override
  State<_CronJobPage> createState() => _CronJobPageState();
}

class _CronJobPageState extends State<_CronJobPage> {
  late Json job = widget.initial;
  late final StreamSubscription<Json> subscription;
  List<_CronRun> runs = [];
  bool working = false, loading = true;
  bool finished = false;
  String? failure;
  String? detailFailure, runsFailure;
  int request = 0;
  late final triggers = _cronTriggers(widget.gateway);

  String get path => _jobPath(widget.initial['id'] as String);
  Map<String, String> get scope => {'profile': widget.profile};
  (String, String) get triggerKey =>
      (widget.profile, widget.initial['id'] as String);
  bool get triggering => triggers.value.contains(triggerKey);
  bool get running => triggering || _stateText(job) == '执行中';

  @override
  void initState() {
    super.initState();
    subscription = widget.gateway.events.listen((event) {
      if (mounted && !finished && _cronChanged(event, widget.profile)) {
        unawaited(load());
      }
    });
    load();
  }

  @override
  void dispose() {
    subscription.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (!mounted || finished) return;
    final id = ++request;
    setState(() {
      loading = true;
      detailFailure = null;
      runsFailure = null;
    });
    final (details, history) = await (
      _readCron(() async {
        final next = await widget.gateway.api(path, query: scope);
        if (next['id'] != widget.initial['id'] ||
            !_belongsTo(next, widget.profile)) {
          throw GatewayError('任务所属档案不匹配');
        }
        return next;
      }),
      _readCron(() async {
        final result = await widget.gateway.api(
          '$path/runs',
          query: {...scope, 'limit': '20'},
        );
        final rows = result['runs'];
        if (rows is! List) throw GatewayError('网关返回了无效的执行记录');
        return rows
            .whereType<Json>()
            .where((run) => _belongsTo(run, widget.profile))
            .map(_CronRun.new)
            .toList();
      }),
    ).wait;
    if (!mounted || id != request || finished) return;
    setState(() {
      if (details.value case final next?) job = next;
      if (history.value case final next?) runs = next;
      detailFailure = details.error;
      runsFailure = history.error;
      loading = false;
    });
  }

  Future<void> edit() async {
    final saved = await Navigator.of(context).push<Json>(
      MaterialPageRoute(
        builder: (_) => _CronEditor(
          gateway: widget.gateway,
          profile: widget.profile,
          initial: job,
        ),
      ),
    );
    if (saved != null) {
      widget.onChanged?.call();
      if (mounted) await load();
    }
  }

  Future<void> act(String action) async {
    final starting = action == 'trigger';
    if (working || starting && running || action == 'cancel' && !running) return;
    if (starting || action == 'delete') {
      final deleting = action == 'delete';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(deleting ? context.tr('删除定时任务？') : context.tr('立即运行任务？')),
          content: Text(_jobTitle(job, context.tr('定时任务'))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(context.tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(deleting ? context.tr('删除') : context.tr('运行')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || working || starting && triggering) {
        return;
      }
    }
    final key = triggerKey;
    if (starting) triggers.value = {...triggers.value, key};
    setState(() {
      working = !starting;
      failure = null;
    });
    final changed = widget.onChanged;
    final deleted = widget.onDeleted;
    try {
      await widget.gateway.api(
        action == 'delete' ? path : '$path/$action',
        query: scope,
        method: action == 'delete' ? 'DELETE' : 'POST',
        timeout: starting
            ? const Duration(hours: 24)
            : const Duration(seconds: 30),
      );
      if (action == 'delete') {
        if (mounted) finished = true;
        if (deleted != null) {
          deleted();
        } else if (mounted) {
          Navigator.pop(context);
        }
      } else {
        changed?.call();
        if (mounted) await load();
      }
    } catch (e) {
      if (mounted) {
        setState(() => failure = _cronError(e, fallback: '定时任务操作失败'));
      }
    } finally {
      if (starting) {
        triggers.value = {...triggers.value}..remove(key);
      } else if (mounted && !finished) {
        setState(() => working = false);
      }
    }
  }

  void openRun(_CronRun run) {
    if (run.sessionId case final id?) {
      final row = {...run.row, 'id': id};
      if (widget.onOpenRun case final open?) {
        open(row);
      } else {
        Navigator.pop(context, row);
      }
      return;
    }
    final output = run.preview(context);
    final outcome = run.outcome;
    if (output.isEmpty && outcome == null) return;
    showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.tr('运行记录')),
        content: SingleChildScrollView(
          child: SelectableText(
            [
              _formatDate(context, run.row['started_at']),
              if (outcome != null) context.tr(outcome),
              output,
            ].where((text) => text.isNotEmpty).join('\n\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(context.tr('关闭')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: triggers,
    builder: (context, _) => buildDetails(context),
  );

  Widget buildDetails(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final inline = widget.onOpenRun != null;
    final paused = job['state'] == 'paused' || job['enabled'] == false;
    final nextRun = _formatDate(context, job['next_run_at']);
    final lastRun = _formatDate(context, job['last_run_at']);
    final delivery = job['deliver']?.toString().trim() ?? '';
    final prompt = job['prompt']?.toString().trim() ?? '';
    final script = job['script']?.toString().trim() ?? '';
    final showScript =
        script.isNotEmpty && (job['no_agent'] == true || prompt.isEmpty);
    final command = showScript ? script : prompt;
    final toolbar = AppBar(
      primary: !inline,
      automaticallyImplyLeading: !inline,
      title: Text(
        _jobTitle(job, context.tr('定时任务')),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        IconButton(
          tooltip: context.tr('刷新任务详情'),
          onPressed: loading || working ? null : load,
          icon: const Icon(Icons.refresh_rounded),
        ),
        PopupMenuButton<String>(
          enabled: !working,
          tooltip: context.tr('任务操作'),
          onSelected: (item) {
            if (item == 'edit') {
              edit();
            } else {
              act(item);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(context.tr('编辑'))),
            PopupMenuItem(
              value: paused ? 'resume' : 'pause',
              child: Text(paused ? context.tr('恢复') : context.tr('暂停')),
            ),
            PopupMenuItem(value: 'delete', child: Text(context.tr('删除'))),
          ],
        ),
      ],
    );
    final body = RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          if (loading || working || triggering) const LinearProgressIndicator(),
          if (failure ?? detailFailure case final message?)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                context.tr(message),
                style: TextStyle(color: colors.error),
              ),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule_outlined),
            title: Text(
              _jobStatus(context, job, DateTime.now(), triggering: triggering),
            ),
            subtitle: Text(_scheduleText(job)),
          ),
          if (nextRun.isNotEmpty) jobField(context.tr('下次执行'), nextRun),
          if (lastRun.isNotEmpty) jobField(context.tr('上次执行'), lastRun),
          if (delivery.isNotEmpty)
            jobField(
              context.tr('投递目标'),
              delivery == 'local' ? context.tr('仅本地保存') : delivery,
            ),
          if (job['last_error'] is String &&
              (job['last_error'] as String).trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(job['last_error'] as String),
            ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: working ? null : () => act(running ? 'cancel' : 'trigger'),
              label: Text(context.tr(running ? '停止运行' : '立即运行')),
              icon: Icon(running ? Icons.stop_rounded : Icons.play_arrow_rounded),
            ),
          ),
          if (command.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              context.tr(showScript ? '脚本' : '执行指令'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 7),
            SelectableText(
              command,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 18),
          Text(
            context.tr('运行记录'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (runsFailure case final error?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                context.tr('执行记录读取失败'),
                style: TextStyle(color: colors.error),
              ),
              subtitle: Text(context.tr(error)),
              trailing: TextButton(
                onPressed: load,
                child: Text(context.tr('重试')),
              ),
            )
          else if (!loading && runs.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Text(context.tr('暂无运行记录')),
            ),
          for (final run in runs) buildRun(run),
        ],
      ),
    );
    final safe = SafeArea(top: false, child: body);
    if (!inline) return Scaffold(appBar: toolbar, body: safe);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: toolbar.preferredSize.height, child: toolbar),
        Expanded(child: safe),
      ],
    );
  }

  Widget jobField(String name, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(name, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(flex: 3, child: Text(value)),
      ],
    ),
  );

  Widget buildRun(_CronRun run) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final outcome = run.outcome;
    final date = _formatDate(context, run.row['started_at']);
    final preview = run.preview(context);
    final link = run.sessionId != null;
    final detail = link || outcome != null || preview.isNotEmpty;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        run.title(context),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            children: [
              Text(
                date.isEmpty ? context.tr('时间未知') : date,
                style: theme.textTheme.bodySmall,
              ),
              if (outcome != null)
                Text(
                  context.tr(outcome),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: outcome == '失败' || outcome == '已错过'
                        ? colors.error
                        : colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          if (preview.isNotEmpty && !link)
            Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
      trailing: link ? const Icon(Icons.chevron_right, size: 18) : null,
      onTap: detail ? () => openRun(run) : null,
    );
  }
}

class _CronEditor extends StatefulWidget {
  const _CronEditor({
    required this.gateway,
    required this.profile,
    this.initial,
  });
  final Gateway gateway;
  final String profile;
  final Json? initial;
  @override
  State<_CronEditor> createState() => _CronEditorState();
}

class _CronEditorState extends State<_CronEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(
    text: widget.initial?['name']?.toString(),
  );
  late final schedule = TextEditingController(
    text: _editableSchedule(widget.initial),
  );
  late final prompt = TextEditingController(
    text: widget.initial?['prompt']?.toString(),
  );
  late final script = TextEditingController(
    text: widget.initial?['script']?.toString(),
  );
  late final delivery = TextEditingController(
    text: widget.initial?['deliver']?.toString() ?? 'local',
  );
  bool saving = false;
  String? failure;
  DateTime? pickedRunTime;
  late bool scriptOnly =
      widget.initial?['no_agent'] == true ||
      (widget.initial?['script']?.toString().trim().isNotEmpty == true &&
          widget.initial?['prompt']?.toString().trim().isNotEmpty != true);

  @override
  void dispose() {
    name.dispose();
    schedule.dispose();
    prompt.dispose();
    script.dispose();
    delivery.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    final initial = widget.initial;
    final title = name.text.trim();
    final instructions = prompt.text.trim();
    final scriptPath = script.text.trim();
    final target = delivery.text.trim().isEmpty
        ? 'local'
        : delivery.text.trim();
    final originalTarget = initial?['deliver']?.toString().trim() ?? '';
    final updates = {
      if (initial == null || title != initial['name']?.toString().trim())
        'name': title,
      if (initial == null ||
          target != (originalTarget.isEmpty ? 'local' : originalTarget))
        'deliver': target,
      if (initial == null || schedule.text.trim() != _editableSchedule(initial))
        'schedule': schedule.text.trim(),
      if (!scriptOnly &&
          (initial == null ||
              instructions != initial['prompt']?.toString().trim()))
        'prompt': instructions,
      if (initial == null && scriptOnly) 'no_agent': true,
      if ((scriptOnly || initial?['script'] != null) &&
          scriptPath != (initial?['script']?.toString().trim() ?? ''))
        'script': scriptPath,
    };
    if (updates.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      saving = true;
      failure = null;
    });
    try {
      final saved = await widget.gateway.api(
        initial == null ? cronJobsPath : _jobPath(initial['id'] as String),
        query: {'profile': widget.profile},
        method: initial == null ? 'POST' : 'PUT',
        body: initial == null ? updates : {'updates': updates},
      );
      final id = saved['id'];
      if (id is! String ||
          id.isEmpty ||
          initial != null && initial['id'] != id ||
          !_belongsTo(saved, widget.profile)) {
        throw GatewayError('网关未确认保存定时任务');
      }
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          failure = _cronError(e, fallback: '无法保存定时任务');
          saving = false;
        });
      }
    }
  }

  String? requiredField(String? value) =>
      value?.trim().isNotEmpty == true ? null : context.tr('请填写此项');

  String? validateSchedule(String? value) {
    final required = requiredField(value);
    if (required != null) return required;
    if (pickedRunTime case final selected?
        when !selected.isAfter(DateTime.now())) {
      return context.tr('请选择未来的运行时间');
    }
    return null;
  }

  Future<void> pickRunTime() async {
    final now = DateTime.now();
    final saved = _scheduledInstant(schedule.text);
    final initial = saved != null && saved.isAfter(now)
        ? saved
        : now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateUtils.dateOnly(now),
      lastDate: DateTime(9999, 12, 31),
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted || time == null) return;
    final local = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (!local.isAfter(DateTime.now())) {
      setState(() => failure = '请选择未来的运行时间');
      return;
    }
    if (local.hour != time.hour || local.minute != time.minute) {
      setState(() => failure = '该时间在本机时区不可用');
      return;
    }
    final encoded = local.toUtc().toIso8601String();
    setState(() {
      pickedRunTime = local;
      schedule.text = encoded;
      failure = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheduled = _scheduledInstant(schedule.text);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initial == null ? context.tr('新建定时任务') : context.tr('编辑定时任务'),
        ),
      ),
      body: SafeArea(
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              TextFormField(
                controller: name,
                enabled: !saving,
                validator: requiredField,
                decoration: InputDecoration(labelText: context.tr('名称')),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: schedule,
                enabled: !saving,
                validator: validateSchedule,
                onChanged: (_) => setState(() {
                  pickedRunTime = null;
                  failure = null;
                }),
                decoration: InputDecoration(
                  labelText: context.tr('执行计划'),
                  hintText: '0 9 * * *',
                  helperText: scheduled == null
                      ? null
                      : context.strings.format('本机时间 · {time}', {
                          'time': _formatDate(context, scheduled),
                        }),
                  suffixIcon: IconButton(
                    tooltip: context.tr('选择一次运行时间'),
                    onPressed: saving ? null : pickRunTime,
                    icon: const Icon(Icons.event_outlined, size: 21),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (widget.initial == null) ...[
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(context.tr('智能体任务')),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(context.tr('脚本任务')),
                    ),
                  ],
                  selected: {scriptOnly},
                  onSelectionChanged: saving
                      ? null
                      : (value) => setState(() {
                          scriptOnly = value.single;
                          failure = null;
                        }),
                ),
                const SizedBox(height: 14),
              ],
              if (scriptOnly || widget.initial?['script']?.toString().isNotEmpty == true) ...[
                TextFormField(
                  controller: script,
                  enabled: !saving,
                  validator: scriptOnly ? requiredField : null,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: context.tr('脚本'),
                    helperText: context.tr('相对于档案 scripts 目录的路径'),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (!scriptOnly) ...[
                TextFormField(
                  controller: prompt,
                  enabled: !saving,
                  validator: requiredField,
                  minLines: 4,
                  maxLines: 10,
                  decoration: InputDecoration(labelText: context.tr('执行指令')),
                ),
                const SizedBox(height: 14),
              ],
              TextFormField(
                controller: delivery,
                enabled: !saving,
                decoration: InputDecoration(
                  labelText: context.tr('投递目标'),
                  helperText: context.tr("local 将结果保存在网关"),
                ),
              ),
              if (failure != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    failure!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: saving ? null : save,
                child: Text(saving ? context.tr('正在保存…') : context.tr('保存')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
