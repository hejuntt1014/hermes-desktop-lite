import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/chat.dart';
import 'package:hermes_mobile/followup_queue.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/history.dart';
import 'package:material_ui/material_ui.dart';

class _QueueGateway extends Gateway {
  _QueueGateway() : super('queue.local', '') {
    canonical = true;
  }
  final frames = StreamController<Json>.broadcast();
  final calls = <(String, Json)>[];
  List<Json> pending = [];
  List<Json> history = [];
  bool startingBusy = true;

  @override
  Stream<Json> get events => frames.stream;

  @override
  Future<HistoryPage> historyPage(
    String profile,
    String id,
    int offset, {
    FileTransferControl? control,
  }) async => HistoryPage(sessionId: id, rows: history);

  @override
  Future<Json> openSession(
    String profile,
    String? id, {
    bool paged = false,
    Json? launch,
  }) async => {
    'session_id': 'runtime',
    'stored_session_id': id,
    'messages_omitted': true,
    'running': startingBusy,
    'pending': pending,
  };

  @override
  Future<Json> call(
    String method,
    Json params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    calls.add((method, params));
    if (method == 'prompt.cancel') {
      pending = [];
      return {'status': 'terminal', 'admission_id': params['admission_id']};
    }
    if (method == 'prompt.submit') return {'status': 'started'};
    if (method == 'session.events.since') return {'events': []};
    throw StateError(method);
  }

  void complete(int seq) => frames.add({
    'type': 'message.complete',
    'session_id': 'runtime',
    'seq': seq,
    'payload': {'text': '回复 $seq'},
  });
}

Widget _chat(_QueueGateway gateway) => MaterialApp(
  home: ChatPage(
    gateway: gateway,
    profile: 'work',
    id: 'stored',
    title: '排队测试',
    onLibrary: () {},
    onNew: () {},
    recent: const [],
    onOpen: (_) {},
  ),
);

void _cleanup(_QueueGateway gateway) {
  addTearDown(() async {
    gateway.close();
    await gateway.frames.close();
  });
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('queued attachments survive loss of the selected source and stay profile scoped', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hermes-queue-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final gateway = _QueueGateway();
    _cleanup(gateway);
    final store = FollowupQueue(
      gateway,
      'work',
      'stored',
      storageRoot: () async => directory,
    );
    final original = File('${directory.path}/selected.txt');
    await original.writeAsString('attachment fixture');
    final saved = (await store.add('caption', [
      XFile(original.path),
    ], null)).single;
    await original.delete();
    final reopened = FollowupQueue(
      gateway,
      'work',
      'stored',
      storageRoot: () async => directory,
    );
    final other = FollowupQueue(
      gateway,
      'personal',
      'stored',
      storageRoot: () async => directory,
    );
    expect(await other.read(), isEmpty);
    final entry = (await reopened.read()).single;
    expect(entry.id, saved.id);
    final recovered = await reopened.source(entry.id, entry.files.single);
    expect(recovered.name, 'selected.txt');
    expect(await recovered.readAsString(), 'attachment fixture');
    await reopened.remove(entry.id);
    expect(await File(recovered.path).exists(), isFalse);
  });

  testWidgets(
    'messages queued during a reply drain in FIFO order with the recorded IDs',
    (tester) async {
      final gateway = _QueueGateway();
      _cleanup(gateway);
      await tester.pumpWidget(_chat(gateway));
      await tester.pumpAndSettle();
      final store = FollowupQueue(gateway, 'work', 'stored');
      final composer = find.byType(TextField);
      for (final caption in ['先发这条', '再发这条']) {
        await tester.enterText(composer, caption);
        await tester.pump();
        await tester.tap(find.byTooltip('加入队列'));
        await tester.pumpAndSettle();
      }
      expect(find.text('待发送 2 条'), findsOneWidget);
      expect(find.byTooltip('停止回复'), findsOneWidget);
      final entries = await store.read();
      expect(entries.map((row) => row.text), ['先发这条', '再发这条']);
      expect(gateway.calls, isEmpty);
      gateway.complete(1);
      await tester.pumpAndSettle();
      expect(gateway.calls.length, 1);
      expect(gateway.calls.first.$2['text'], '先发这条');
      expect(gateway.calls.first.$2['submission_id'], entries.first.id);
      expect(gateway.calls.first.$2['queued'], isTrue);
      expect((await store.read()).single.id, entries.last.id);
      gateway.complete(2);
      await tester.pumpAndSettle();
      expect(gateway.calls.length, 2);
      expect(gateway.calls.last.$2['text'], '再发这条');
      expect(gateway.calls.last.$2['submission_id'], entries.last.id);
      expect(await store.read(), isEmpty);
    },
  );

  testWidgets(
    'resume reconciles an acknowledged queue item and can withdraw the remote admission',
    (tester) async {
      final gateway = _QueueGateway();
      _cleanup(gateway);
      final store = FollowupQueue(gateway, 'work', 'stored');
      final entry = (await store.add('需核对的消息', [], null)).single;
      await store.stage(entry, {
        'session_id': 'runtime',
        'text': entry.text,
        'queued': true,
        'submission_id': entry.id,
      });
      gateway.pending = [
        {
          'admission_id': 'remote-id',
          'input_id': entry.id,
          'status': 'queued',
          'text': entry.text,
          'sequence': 1,
        },
      ];
      await tester.pumpWidget(_chat(gateway));
      await tester.pumpAndSettle();
      expect(await store.read(), isEmpty);
      expect(gateway.calls, isEmpty);
      await tester.tap(find.text('待发送 1 条'));
      await tester.pumpAndSettle();
      expect(find.text('已在网关排队'), findsOneWidget);
      await tester.tap(find.byTooltip('网关排队消息操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤回'));
      await tester.pumpAndSettle();
      expect(gateway.calls.first.$1, 'prompt.cancel');
      expect(gateway.calls.first.$2['admission_id'], 'remote-id');
      expect(find.text('待发送 1 条'), findsNothing);
    },
  );
}
