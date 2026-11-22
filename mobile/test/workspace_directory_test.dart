import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/chat.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/workspace_directory.dart';
import 'package:material_ui/material_ui.dart';

class _WorkspaceGateway extends Gateway {
  _WorkspaceGateway() : super('workspace.test', '');
  final calls = <(String, Json)>[];
  final launches = <Json>[];
  bool conflict = false;

  @override
  Future<Json> api(
    String path, {
    Map<String, String>? query,
    Json? body,
    String? method,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    return switch (path) {
      'api/fs/default-cwd' => {'cwd': '/workspace'},
      'api/fs/list' => {
        'entries': [
          if (query!['path'] == '/workspace') ...[
            {'name': 'docs', 'path': '/workspace/docs', 'isDirectory': true},
            {
              'name': 'example.txt',
              'path': '/workspace/example.txt',
              'isDirectory': false,
            },
          ],
        ],
      },
      _ => throw StateError(path),
    };
  }

  @override
  Future<Json> call(
    String method,
    Json params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    calls.add((method, params));
    if (method == 'session.mutate') {
      if (conflict) {
        conflict = false;
        throw GatewayError.rpc('revision_conflict', 409, {
          'reason': 'revision_conflict',
          'revision': 6,
          'execution_generation': 4,
        });
      }
      return {
        'cwd': '/workspace/docs',
        'revision': 7,
        'execution_generation': 5,
      };
    }
    return switch (method) {
      'session.cwd.set' || 'config.get' => {'cwd': '/workspace/docs'},
      'prompt.submit' => {'status': 'started'},
      _ => throw StateError(method),
    };
  }

  @override
  Future<Json> openSession(
    String profile,
    String? id, {
    bool paged = false,
    Json? launch,
  }) async {
    expect(id, isNull);
    launches.add(launch!);
    return {
      'session_id': 'runtime',
      'stored_session_id': 'stored',
      'info': {'cwd': launch['cwd']},
    };
  }
}

Widget _draft(_WorkspaceGateway gateway) => MaterialApp(
  home: ChatPage(
    gateway: gateway,
    profile: 'work',
    id: null,
    title: '新会话',
    onLibrary: () {},
    onNew: () {},
    recent: const [],
    onOpen: (_) {},
  ),
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('directory parents respect Unix, Windows drive, and UNC roots', () {
    expect(parentWorkspacePath('/home'), '/');
    expect(parentWorkspacePath('/'), isNull);
    expect(parentWorkspacePath('~/project'), '~/');
    expect(parentWorkspacePath(r'C:\work'), 'C:\\');
    expect(parentWorkspacePath('C:\\'), isNull);
    expect(
      parentWorkspacePath(r'\\server\share\dir'),
      r'\\server\share'
      '\\',
    );
    expect(parentWorkspacePath(r'\\server\share'), isNull);
  });

  test(
    'workspace mutations retry fenced conflicts with the same request ID',
    () async {
      final gateway = _WorkspaceGateway()
        ..canonical = true
        ..conflict = true;
      addTearDown(gateway.close);
      final changed = await WorkspaceDirectoryChange(
        gateway,
        'work',
        'stored',
        'runtime',
      ).change('/workspace/docs', baseline: (revision: 5, generation: 4));
      expect(changed, (
        path: '/workspace/docs',
        version: (revision: 7, generation: 5),
      ));
      expect(gateway.calls.map((call) => call.$1), [
        'session.mutate',
        'session.mutate',
      ]);
      expect(
        gateway.calls.first.$2['request_id'],
        gateway.calls.last.$2['request_id'],
      );
      expect(gateway.calls.last.$2, containsPair('expected_revision', 6));
      expect(gateway.calls.last.$2, containsPair('session_id', 'stored'));
      expect(gateway.calls.last.$2['payload'], {'cwd': '/workspace/docs'});

      gateway.canonical = false;
      await WorkspaceDirectoryChange(
        gateway,
        'work',
        'stored',
        'runtime',
      ).change('/workspace/docs');
      expect(gateway.calls.last.$1, 'session.cwd.set');
      expect(gateway.calls.last.$2, {
        'profile': 'work',
        'session_id': 'runtime',
        'cwd': '/workspace/docs',
      });
    },
  );

  testWidgets(
    'selecting a draft folder persists the preference without creating a session',
    (tester) async {
      final gateway = _WorkspaceGateway();
      addTearDown(gateway.close);
      await tester.pumpWidget(_draft(gateway));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('工作区'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更改工作目录'));
      await tester.pumpAndSettle();
      expect(find.text('example.txt'), findsNothing);
      await tester.tap(find.text('docs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用此目录'));
      await tester.pumpAndSettle();
      expect(gateway.launches, isEmpty);
      expect(
        await WorkspaceDefaults(gateway, 'work').read(),
        '/workspace/docs',
      );
      expect(await WorkspaceDefaults(gateway, 'other').read(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_draft(gateway));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '测试工作区');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(gateway.launches.single, {
        'cwd': '/workspace/docs',
        'cwd_explicit': true,
      });
    },
  );
}
