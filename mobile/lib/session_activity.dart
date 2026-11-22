import 'dart:async';

import 'package:flutter/widgets.dart';

import 'gateway.dart';

enum ActivityKind {
  agents('子代理', 'subagent.list', 'subagents'),
  processes('后台进程', 'process.list', 'processes');

  const ActivityKind(this.label, this.method, this.field);
  final String label, method, field;
}

class SessionWork {
  const SessionWork(
    this.id,
    this.kind,
    this.title,
    this.status,
    this.detail,
    this.output, {
    this.depth = 0,
    this.exitCode,
  });

  final String id, title, status, detail, output;
  final ActivityKind kind;
  final int depth;
  final int? exitCode;

  bool get active => status == 'running' || status == 'queued';

  static SessionWork? fromWire(
    ActivityKind kind,
    Json row, {
    SessionWork? previous,
  }) {
    final agent = kind == ActivityKind.agents;
    final title = _value(row[agent ? 'goal' : 'command']).split('\n').first;
    final id = _value(row[agent ? 'subagent_id' : 'session_id']);
    if (id.isEmpty) return null;
    final status = _value(row['status']);
    final details = [
      _value(row['model']),
      _value(row['last_tool'] ?? row['tool_name']),
    ].where((part) => part.isNotEmpty).join(' · ');
    final output = _value(row['output_tail'] ?? row['output_preview']);
    return SessionWork(
      id,
      kind,
      title.isEmpty ? previous?.title ?? (agent ? '子代理' : '后台进程') : title,
      status.isEmpty ? previous?.status ?? 'running' : status,
      details.isEmpty ? previous?.detail ?? '' : details,
      output.isEmpty ? previous?.output ?? '' : output,
      depth: (row['depth'] as num?)?.toInt() ?? previous?.depth ?? 0,
      exitCode: row['exit_code'] is int
          ? row['exit_code'] as int
          : previous?.exitCode,
    );
  }
}

String _value(Object? value) => value is String ? value.trim() : '';

enum ConversationActivity {
  running('会话正在回复'),
  waiting('会话等待处理'),
  background('有后台活动');

  const ConversationActivity(this.label);

  final String label;
}

typedef TurnRoster = ({
  Map<String, ConversationActivity> states,
  Set<String> storedSessions,
});

class SessionActivityService {
  const SessionActivityService(this.gateway, this.profile, this.session);
  final Gateway gateway;
  final String profile, session;

  Json get _scope => {'profile': profile, 'session_id': session};

  Future<List<SessionWork>> list(
    ActivityKind kind, {
    bool includeFinished = false,
  }) async {
    final response = await gateway.call(
      kind.method,
      _scope,
      timeout: const Duration(seconds: 8),
    );
    final source = response[kind.field];
    if (source is! List) throw GatewayError('网关未返回可读取的活动');
    return source
        .whereType<Json>()
        .map((row) => SessionWork.fromWire(kind, row))
        .nonNulls
        .where((item) => includeFinished || item.active)
        .toList();
  }

  Future<String?> agentOutput(String id) async {
    final response = await gateway.call('subagent.tail', {
      ..._scope,
      'subagent_id': id,
    }, timeout: const Duration(seconds: 8));
    if (response['available'] != true) return null;
    return _value(response['text']);
  }

  static Future<Set<String>> roster(Gateway gateway, String profile) async {
    final response = await gateway.call('subagent.roster', {
      'profile': profile,
    }, timeout: const Duration(seconds: 8));
    final rows = response['sessions'];
    if (rows is! List) return {};
    return {
      for (final row in rows.whereType<Json>())
        if (((row['subagents'] as num?) ?? 0) > 0 ||
            ((row['background'] as num?) ?? 0) > 0)
          if (row['session_id'] case final String id when id.isNotEmpty) id,
    };
  }

  static Future<TurnRoster> turns(Gateway gateway, String profile) async {
    final response = await gateway.call('session.active_list', {
      'profile': profile,
    }, timeout: const Duration(seconds: 8));
    final rows = response['sessions'];
    if (rows is! List) throw GatewayError('网关未返回可读取的活动');
    final result = <String, ConversationActivity>{};
    final stored = <String>{};
    for (final row in rows.whereType<Json>()) {
      if (row['profile'] != null && row['profile'] != profile) continue;
      final state = switch (row['status']) {
        'waiting' => ConversationActivity.waiting,
        'working' || 'starting' || 'running' => ConversationActivity.running,
        _ => null,
      };
      if (state == null) continue;
      if (row['session_key'] case final String id when id.isNotEmpty) {
        stored.add(id);
      }
      for (final key in const ['id', 'session_key']) {
        if (row[key] case final String id when id.isNotEmpty) {
          if (result[id] != ConversationActivity.waiting) result[id] = state;
        }
      }
    }
    return (states: result, storedSessions: stored);
  }
}

class AgentActivity {
  final _active = <String, SessionWork>{};
  final _retired = <String>{};
  final _completed = <String, SessionWork>{};
  int revision = 0;

  List<SessionWork> get rows => _active.values.toList();
  bool get hasActive => _active.isNotEmpty;
  SessionWork? item(String id) => _active[id] ?? _completed[id];

  void replace(List<SessionWork> rows, int before) {
    if (before != revision) return;
    _active
      ..clear()
      ..addEntries(
        rows
            .where((row) => !_retired.contains(row.id))
            .map((row) => MapEntry(row.id, row)),
      );
  }

  bool apply(Json event, {required String session, required String profile}) {
    final type = event['type'];
    final payload = event['payload'];
    if (event['session_id'] != session ||
        event['profile'] != null && event['profile'] != profile ||
        payload is! Json ||
        type is! String ||
        !type.startsWith('subagent.')) {
      return false;
    }
    final id = _value(payload['subagent_id']);
    if (id.isEmpty) return false;
    final status = _value(payload['status']);
    if (type == 'subagent.complete' ||
        {
          'completed',
          'failed',
          'timeout',
          'cancelled',
          'canceled',
          'interrupted',
        }.contains(status)) {
      final previous = _active.remove(id) ?? _completed[id];
      final summary = _value(payload['summary']);
      final result = summary.isNotEmpty ? summary : _value(payload['text']);
      final finished = SessionWork.fromWire(ActivityKind.agents, {
        ...payload,
        'status': status.isEmpty ? 'completed' : status,
        if (result.isNotEmpty) 'output_tail': result,
      }, previous: previous);
      if (finished != null) {
        _completed[id] = finished;
        if (_completed.length > 16) _completed.remove(_completed.keys.first);
      }
      _retired.add(id);
    } else if (!_retired.contains(id)) {
      final updated = SessionWork.fromWire(ActivityKind.agents, {
        ...payload,
        if (type == 'subagent.spawn_requested')
          'status': 'queued'
        else if (type == 'subagent.start')
          'status': 'running',
      }, previous: _active[id]);
      if (updated == null) return false;
      _active[id] = updated;
    } else {
      return false;
    }
    revision++;
    return true;
  }
}

class SessionActivityMonitor extends ChangeNotifier {
  SessionActivityMonitor(this.service, {this.storedSession}) {
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground =
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached;
    _lifecycle = AppLifecycleListener(
      onResume: () => _setForeground(true),
      onHide: () => _setForeground(false),
      onPause: () => _setForeground(false),
    );
    _subscription = service.gateway.events.listen(_onEvent);
  }

  final SessionActivityService service;
  final String? storedSession;
  final _agents = AgentActivity();
  final _failures = <ActivityKind, String>{};
  final _unavailable = <ActivityKind>{};
  final _pending = <ActivityKind>{};
  late final StreamSubscription<Json> _subscription;
  late final AppLifecycleListener _lifecycle;
  List<SessionWork> _processes = [];
  Timer? _timer;
  bool _foreground = true, _watching = false, _disposed = false;
  int _generation = 0;

  bool get online => service.gateway.usable;
  bool get refreshing => _pending.isNotEmpty;
  bool get hasWork => _processes.isNotEmpty || _agents.hasActive;
  bool loading(ActivityKind kind) => _pending.contains(kind);
  String? failure(ActivityKind kind) => _failures[kind];
  List<SessionWork> items(ActivityKind kind) =>
      kind == ActivityKind.agents ? _agents.rows : _processes;
  SessionWork? agent(String id) => _agents.item(id);

  bool get _canPoll => !_disposed && _watching && _foreground && online;

  void watch(bool watching) {
    if (_disposed || _watching == watching) return;
    _watching = watching;
    _cancelRequests();
    if (_canPoll) unawaited(Future<void>.microtask(refresh));
  }

  void _setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _cancelRequests();
    notifyListeners();
    if (_canPoll) unawaited(refresh());
  }

  void _cancelRequests() {
    _generation++;
    _pending.clear();
    _timer?.cancel();
  }

  void _onEvent(Json event) {
    if (_disposed) return;
    final kind = event['type'];
    if (kind == 'client.connection') {
      _cancelRequests();
      _unavailable.clear();
      notifyListeners();
      if (_canPoll) unawaited(refresh());
      return;
    }
    final id = event['session_id'];
    if ((id != service.session && id != storedSession) ||
        id == null ||
        (event['profile'] != null && event['profile'] != service.profile)) {
      return;
    }
    if (_agents.apply(event, session: id as String, profile: service.profile)) {
      notifyListeners();
      if (_canPoll && !refreshing) _schedule();
    } else if (_canPoll) {
      final payload = event['payload'];
      final name = payload is Json
          ? payload['tool_name'] ?? payload['name']
          : null;
      if (kind == 'message.complete' ||
          kind == 'status.update' &&
              payload is Json &&
              payload['kind'] == 'process' ||
          kind == 'tool.complete' &&
              (name == 'terminal' || name == 'process')) {
        unawaited(refresh());
      }
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!_canPoll || _unavailable.length == ActivityKind.values.length) return;
    _timer = Timer(
      Duration(seconds: hasWork ? 5 : 15),
      () => unawaited(refresh()),
    );
  }

  Future<void> refresh({bool manual = false}) async {
    if (!_canPoll) return;
    if (manual) _unavailable.clear();
    final before = _generation;
    await Future.wait(ActivityKind.values.map(_load));
    if (_canPoll && before == _generation) _schedule();
  }

  Future<void> _load(ActivityKind kind) async {
    if (_unavailable.contains(kind) || !_pending.add(kind)) return;
    final before = _generation;
    final agentRevision = _agents.revision;
    notifyListeners();
    try {
      final result = await service.list(kind);
      if (_disposed || before != _generation) return;
      _failures.remove(kind);
      if (kind == ActivityKind.agents) {
        _agents.replace(result, agentRevision);
      } else {
        _processes = result;
      }
    } catch (error) {
      if (_disposed || before != _generation) return;
      if (error is GatewayError && error.code == -32601) {
        _unavailable.add(kind);
        _failures[kind] = '当前网关未提供此类活动';
      } else {
        _failures[kind] = '暂时无法更新，拉动或点刷新重试';
      }
    } finally {
      if (!_disposed && before == _generation) {
        _pending.remove(kind);
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_subscription.cancel());
    _lifecycle.dispose();
    super.dispose();
  }
}
