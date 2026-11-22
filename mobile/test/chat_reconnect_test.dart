import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/chat.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/history.dart';
import 'package:material_ui/material_ui.dart';

class _ChatGateway extends Gateway {
  _ChatGateway() : super('reconnect.local', '') {
    canonical = true;
    replayEpoch = 'current-epoch';
  }
  final frames = StreamController<Json>.broadcast();
  final submissions = <Json>[];
  final replay = <Json>[];
  var historyReads = 0, resumes = 0;
  bool loseFirst = false, admitted = false, resumeRunning = false;

  @override
  Stream<Json> get events => frames.stream;

  void edge(GatewayLink state) {
    link = state;
    frames.add({
      'type': 'client.connection',
      'payload': {'state': state.name, 'resumed': state == GatewayLink.online},
    });
  }

  @override
  Future<HistoryPage> historyPage(
    String profile,
    String id,
    int offset, {
    FileTransferControl? control,
  }) async {
    expect(id, 'stored');
    expect(profile, 'work');
    expect(offset, 0);
    historyReads++;
    return HistoryPage(
      sessionId: id,
      rows: [
        {'id': 51, 'role': 'assistant', 'content': '已有回复'},
        if (resumes > 1) {'id': 52, 'role': 'assistant', 'content': '离线期间的回复'},
        if (admitted)
          {
            'id': 54,
            'role': 'user',
            'content': '未确认消息',
            'submission_id': submissions.first['submission_id'],
          },
      ],
    );
  }

  @override
  Future<Json> openSession(
    String profile,
    String? id, {
    bool paged = false,
    Json? launch,
  }) async {
    expect(id, 'stored');
    expect(paged, isTrue);
    resumes++;
    return {
      'session_id': 'runtime',
      'stored_session_id': id,
      'last_sequence': 17,
      'replay_epoch': 'current-epoch',
      'execution_generation': 3,
      'running': resumeRunning && resumes > 1,
      'messages_omitted': true,
    };
  }

  @override
  Future<Json> call(
    String method,
    Json params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    switch (method) {
      case 'session.events.since':
        replay.add(params);
        if (resumeRunning && params['last_seen'] == 0) {
          return {
            'events': [
              {
                'type': 'message.start',
                'session_id': 'runtime',
                'seq': 16,
                'execution_generation': 3,
                'payload': {'turn_id': 'turn'},
              },
              {
                'type': 'message.delta',
                'session_id': 'runtime',
                'seq': 17,
                'execution_generation': 3,
                'payload': {'text': '正在生成的答复', 'offset': 0},
              },
            ],
          };
        }
        return {'events': [], 'last_sequence': 17};
      case 'prompt.submit':
        submissions.add(params);
        if (loseFirst && submissions.length == 1) throw GatewayDisconnected();
        admitted = true;
        return {'status': 'started'};
      default:
        throw StateError(method);
    }
  }
}

Widget _page(_ChatGateway gateway) => MaterialApp(
  home: ChatPage(
    gateway: gateway,
    profile: 'work',
    id: 'stored',
    title: '验证会话',
    onLibrary: () {},
    onNew: () {},
    recent: const [],
    onOpen: (_) {},
  ),
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'reconnect refreshes the current session and keeps the composer',
    (tester) async {
      final gateway = _ChatGateway();
      addTearDown(() async {
        gateway.close();
        await gateway.frames.close();
      });
      await tester.pumpWidget(_page(gateway));
      await tester.pumpAndSettle();
      final composer = find.byType(TextField);
      await tester.enterText(composer, '尚未发送的草稿');
      gateway.edge(GatewayLink.reconnecting);
      await tester.pump();
      expect(find.text('正在重新连接网关'), findsOneWidget);
      final submit = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '发送',
        ),
      );
      expect(submit.onPressed, isNull);
      gateway.edge(GatewayLink.online);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer).controller?.text, '尚未发送的草稿');
      expect(find.text('离线期间的回复'), findsOneWidget);
      expect(gateway.historyReads, 2);
      expect(gateway.replay.single, {
        'session_id': 'runtime',
        'profile': 'work',
        'last_seen': 17,
        'replay_epoch': 'current-epoch',
      });
      expect(gateway.submissions, isEmpty);
    },
  );

  testWidgets(
    'retrying a lost acknowledgement keeps the original submission ID',
    (tester) async {
      final gateway = _ChatGateway()..loseFirst = true;
      addTearDown(() async {
        gateway.close();
        await gateway.frames.close();
      });
      await tester.pumpWidget(_page(gateway));
      await tester.pumpAndSettle();
      final composer = find.byType(TextField);
      await tester.enterText(composer, '未确认消息');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(find.text('上次发送结果待确认'), findsOneWidget);
      expect(tester.widget<TextField>(composer).controller?.text, '未确认消息');
      expect(gateway.submissions.length, 1);
      await tester.tap(find.text('重试原消息'));
      await tester.pumpAndSettle();
      expect(gateway.submissions.length, 2);
      expect(gateway.submissions.last, gateway.submissions.first);
      expect(tester.widget<TextField>(composer).controller?.text, isEmpty);
      expect(find.text('上次发送结果待确认'), findsNothing);
    },
  );

  testWidgets('an in-flight response is rebuilt from its matching replay', (
    tester,
  ) async {
    final gateway = _ChatGateway()..resumeRunning = true;
    addTearDown(() async {
      gateway.close();
      await gateway.frames.close();
    });
    await tester.pumpWidget(_page(gateway));
    await tester.pumpAndSettle();
    gateway.edge(GatewayLink.reconnecting);
    await tester.pump();
    gateway.edge(GatewayLink.online);
    await tester.pumpAndSettle();
    expect(gateway.replay.map((params) => params['last_seen']), [17, 0]);
    expect(find.text('正在生成的答复'), findsOneWidget);
    expect(find.byTooltip('停止回复'), findsOneWidget);
  });
}
