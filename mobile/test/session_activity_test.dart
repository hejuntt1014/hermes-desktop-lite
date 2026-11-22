import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/session_activity.dart';
import 'package:hermes_mobile/session_activity_view.dart';
import 'package:material_ui/material_ui.dart';

class _ActivityGateway extends Gateway {
  _ActivityGateway() : super('activity.local', '');
  final frames = StreamController<Json>.broadcast();
  final requests = <(String, Json)>[];
  bool processesUnsupported = false;

  @override
  Stream<Json> get events => frames.stream;

  @override
  Future<Json> call(
    String method,
    Json params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    requests.add((method, params));
    return switch (method) {
      'subagent.roster' => {
        'sessions': [
          {'session_id': 's1', 'subagents': 1},
          {'session_id': 's2', 'background': 2},
          {'session_id': 's3', 'background': 0},
        ],
      },
      'subagent.list' => {
        'subagents': [
          {'subagent_id': 'a1', 'goal': '检查文档', 'status': 'running'},
        ],
      },
      'process.list' when processesUnsupported => throw GatewayError.rpc(
        'unavailable',
        -32601,
        null,
      ),
      'process.list' => {
        'processes': [
          {
            'session_id': 'p1',
            'command': '索引工作区',
            'status': 'running',
            'output_tail': '已索引 2 个文件',
          },
          {'session_id': 'p2', 'command': '已完成的任务', 'status': 'exited'},
        ],
      },
      'subagent.tail' => {'available': true, 'text': '已完成第一部分'},
      _ => throw StateError(method),
    };
  }
}

void main() {
  test(
    'late polls do not revive completed agents or accept another profile',
    () {
      final state = AgentActivity();
      final work = SessionWork.fromWire(ActivityKind.agents, {
        'subagent_id': 'a1',
        'status': 'running',
        'goal': '工作',
      })!;
      state.replace([work], state.revision);
      final before = state.revision;
      Json completed(String profile) => {
        'type': 'subagent.complete',
        'session_id': 'runtime',
        'profile': profile,
        'payload': {'subagent_id': 'a1'},
      };
      expect(
        state.apply(completed('other'), session: 'runtime', profile: 'work'),
        isFalse,
      );
      expect(state.rows, hasLength(1));
      expect(
        state.apply(completed('work'), session: 'runtime', profile: 'work'),
        isTrue,
      );
      state.replace([work], before);
      expect(state.rows, isEmpty);
    },
  );

  testWidgets('activity reads are scoped and show process and child output', (
    tester,
  ) async {
    final gateway = _ActivityGateway();
    addTearDown(() async {
      gateway.close();
      await gateway.frames.close();
    });
    expect(await SessionActivityService.roster(gateway, 'work'), {'s1', 's2'});
    expect(gateway.requests.first.$2, {'profile': 'work'});
    await tester.pumpWidget(
      MaterialApp(
        home: SessionActivityPage(
          service: SessionActivityService(gateway, 'work', 'runtime'),
          title: '测试会话',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('检查文档'), findsOneWidget);
    expect(find.text('索引工作区'), findsOneWidget);
    expect(find.text('已完成的任务'), findsNothing);
    expect(
      gateway.requests
          .where((entry) => entry.$1.endsWith('.list'))
          .map((entry) => entry.$2),
      everyElement({'profile': 'work', 'session_id': 'runtime'}),
    );
    await tester.tap(find.text('索引工作区'));
    await tester.pumpAndSettle();
    expect(find.text('已索引 2 个文件'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    gateway.processesUnsupported = true;
    await tester.tap(find.byTooltip('刷新活动'));
    await tester.pumpAndSettle();
    expect(find.text('当前网关未提供此类活动'), findsOneWidget);
    await tester.tap(find.text('检查文档'));
    await tester.pumpAndSettle();
    expect(find.text('已完成第一部分'), findsOneWidget);
    expect(gateway.requests.last.$2, {
      'profile': 'work',
      'session_id': 'runtime',
      'subagent_id': 'a1',
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
