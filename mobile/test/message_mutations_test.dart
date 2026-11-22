import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/message_rewrite.dart';
import 'package:hermes_mobile/session_branch.dart';
import 'package:hermes_mobile/timeline.dart';

class _MutationGateway extends Gateway {
  _MutationGateway({required bool useCanonical})
    : super('http://127.0.0.1:9119', '') {
    canonical = useCanonical;
  }
  final calls = <(String, Json)>[];
  bool loseNextSubmit = false, loseFirstBranch = false;
  int revision = 8, generation = 2;
  @override
  Future<Json?> mutationSnapshot(String id, String profile) async {
    expect(id, 'saved');
    expect(profile, 'work');
    return {
      'runtime_revision': revision,
      'runtime_generation': generation,
      'exists': true,
      'session_id': id,
    };
  }

  @override
  Future<Json> api(
    String path, {
    Map<String, String>? query,
    Json? body,
    String? method,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    expect(query?['profile'], 'work');
    final offset = int.parse(query!['offset']!);
    final source = [
      {'id': 1, 'role': 'user', 'content': 'first'},
      {'id': 2, 'role': 'assistant', 'content': ''},
      {'id': 3, 'role': 'assistant', 'content': 'answer'},
      {'id': 4, 'role': 'user', 'content': 'later'},
    ];
    return {
      'session_id': 'saved',
      'profile': 'work',
      'pagination': {'offset': offset, 'limit': 2},
      'messages': source.skip(offset).take(2).toList(),
    };
  }

  @override
  Future<Json> call(
    String method,
    Json params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    calls.add((method, Json.of(params)));
    if (method == 'session.mutate' && params['operation'] == 'rewind') {
      revision = 9;
      generation = 3;
      return {
        'operation': 'rewind',
        'revision': revision,
        'execution_generation': generation,
      };
    }
    if (method.startsWith('session.branch') ||
        params['operation'] == 'branch') {
      if (loseFirstBranch) {
        loseFirstBranch = false;
        throw TimeoutException('lost branch');
      }
      return {'stored_session_id': 'new', 'branched_session_id': 'new'};
    }
    if (loseNextSubmit) {
      loseNextSubmit = false;
      throw TimeoutException('lost submit');
    }
    return canonical
        ? {
            'admission_id': 'admitted',
            'ref': {'session_id': 'live'},
          }
        : {'status': 'streaming'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'retry is attached to a stored user row and only the last answer of a turn',
    () {
      const rows = [
        ChatRow(user: true, body: 'question', rowId: 11),
        ChatRow(user: false, body: 'part', rowId: 12),
        ChatRow(user: false, body: 'thought', activity: '思考'),
        ChatRow(user: false, body: 'answer', rowId: 13),
      ];
      expect(retryPromptIndex(rows, 1), isNull);
      expect(retryPromptIndex(rows, 3), 0);
    },
  );

  test('legacy boundary counts only nonempty chat messages across overlapping pages', () async {
    final gateway = _MutationGateway(useCanonical: false);
    addTearDown(gateway.close);
    final child = await branchConversation(
      gateway,
      profile: 'work',
      parent: 'saved',
      title: '原对话',
      runtime: 'live',
      through: 3,
    );
    expect(child['id'], 'new');
    expect(gateway.calls.single.$2['count'], 2);
    expect(gateway.calls.single.$2['session_id'], 'live');
  });

  test('canonical fork repeats the exact request ID and boundary on a lost response', () async {
    final gateway = _MutationGateway(useCanonical: true)
      ..loseFirstBranch = true;
    addTearDown(gateway.close);
    Future<Json> fork() => branchConversation(
      gateway,
      profile: 'work',
      parent: 'saved',
      title: '原对话',
      through: 3,
    );
    await expectLater(fork(), throwsA(isA<TimeoutException>()));
    expect((await fork())['id'], 'new');
    expect(gateway.calls.first.$2, gateway.calls.last.$2);
    expect(gateway.calls.last.$2['payload'], {'through_message_id': 3});
  });

  test('canonical edit stores the submit phase and reuses its admission after a timeout', () async {
    final gateway = _MutationGateway(useCanonical: true)..loseNextSubmit = true;
    addTearDown(gateway.close);
    final journal = RewriteJournal(gateway, 'work', 'saved');
    final state = await journal.prepare(
      caption: 'edited',
      original: RewriteDraft.fromMessage(
        '@file:attachments/source.txt\n\nquestion',
      ),
      row: 11,
      deep: true,
      version: (revision: 8, generation: 2),
    );

    await expectLater(
      journal.send('live', state),
      throwsA(isA<TimeoutException>()),
    );
    final recovering = await journal.load();
    expect(recovering?['phase'], 'submit');
    await journal.send('live', recovering!);
    expect(await journal.load(), isNull);
    expect(gateway.calls.map((entry) => entry.$1), [
      'session.mutate',
      'prompt.submit',
      'prompt.submit',
    ]);
    final first = gateway.calls[1].$2;
    expect(first['text'], '@file:attachments/source.txt\n\nedited');
    expect(first['submission_id'], gateway.calls[2].$2['submission_id']);
  });

  test(
    'legacy edit retains unknown outcome and declines a second submission',
    () async {
      final gateway = _MutationGateway(useCanonical: false)
        ..loseNextSubmit = true;
      addTearDown(gateway.close);
      final journal = RewriteJournal(gateway, 'work', 'saved');
      final state = await journal.prepare(
        caption: 'edited',
        original: RewriteDraft.fromMessage('question'),
        row: 11,
        deep: true,
        version: null,
      );
      await expectLater(
        journal.send('live', state),
        throwsA(isA<TimeoutException>()),
      );
      final retained = await journal.load();
      expect(retained?['phase'], 'review');
      await expectLater(
        journal.send('live', retained!),
        throwsA(isA<GatewayError>()),
      );
      expect(gateway.calls.length, 1);
      expect(gateway.calls.single.$2['truncate_before_row_id'], 11);
      expect(gateway.calls.single.$2['confirm_deep_truncate'], true);
    },
  );
}
