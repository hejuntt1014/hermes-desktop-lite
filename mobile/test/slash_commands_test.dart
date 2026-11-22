import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/chat.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/history.dart';
import 'package:hermes_mobile/slash_commands.dart';
import 'package:material_ui/material_ui.dart';

const catalog = <String, dynamic>{
  'categories': [
    {
      'name': 'Info',
      'pairs': [
        ['/status', ''],
        ['/usage', ''],
        ['/snapshot', ''],
      ],
    },
    {
      'name': 'Plugin commands',
      'pairs': [
        ['/report', 'Show a report'],
      ],
    },
  ],
  'pairs': [
    ['/status', ''],
    ['/release', 'Release notes'],
  ],
  'commands': {
    '/status': {'desktop': 'advanced'},
    '/usage': {'desktop': 'hidden'},
  },
  'skills': {
    '/release': {'origin': 'bundled', 'usage': 0},
  },
};

class _CommandsGateway extends Gateway {
  _CommandsGateway() : super('https://localhost', '');
  final calls = <(String, Json)>[];

  @override
  Future<HistoryPage> historyPage(
    String profile,
    String id,
    int offset, {
    FileTransferControl? control,
  }) async => HistoryPage(sessionId: id, rows: [], nextOffset: null);

  @override
  Future<Json> openSession(
    String profile,
    String? id, {
    bool paged = false,
    Json? launch,
  }) async => {
    'session_id': 'runtime',
    'stored_session_id': id ?? 'created',
    'messages_omitted': true,
  };

  @override
  Future<Json> call(
    String method,
    Json params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    calls.add((method, params));
    return switch (method) {
      'commands.catalog' => catalog,
      'slash.exec' => {'output': 'Ready for messages'},
      'command.dispatch' when params['name'] == 'report' => {
        'type': 'prefill',
        'message': 'Draft with a report',
      },
      'command.dispatch' => {
        'type': 'skill',
        'message': 'Expanded gateway prompt',
        'display': '/release notes',
      },
      'prompt.submit' => {},
      _ => throw StateError(method),
    };
  }
}

void main() {
  test(
    'catalog keeps PC routes and can find a bundled skill by description',
    () {
      final commands = SlashCatalog(catalog);
      expect(commands.entries['status']?.route, SlashRoute.diagnostic);
      expect(commands.entries.keys, isNot(contains('usage')));
      expect(commands.entries.keys, isNot(contains('snapshot')));
      expect(
        commands.search('').map((item) => item.name),
        isNot(contains('release')),
      );
      expect(
        commands.search('release notes').single.route,
        SlashRoute.extension,
      );
      expect(commands.entries['report']?.group, '插件命令');
      expect(parseSlashInput('/fork'), (name: 'branch', arg: ''));
      expect(parseSlashInput('/root/workspace/notes.md'), isNull);
      expect(diagnosticArgument('skills', 'apply'), isNull);
      expect(diagnosticArgument('skills', ''), 'pending');
    },
  );

  testWidgets(
    'chat scopes commands, prefills drafts and submits only a skill prompt',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final gateway = _CommandsGateway()..version = '0.23.2';
      addTearDown(gateway.close);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatPage(
            gateway: gateway,
            profile: 'work',
            id: 'history',
            title: 'Chat',
            onLibrary: () {},
            onNew: () {},
            recent: const [],
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final composer = find.byType(TextField);
      Future<void> send(String text) async {
        await tester.enterText(composer, text);
        await tester.pump();
        await tester.tap(find.byTooltip('发送'));
        await tester.pumpAndSettle();
      }

      await send('/version');
      expect(find.text('Hermes 网关 0.23.2'), findsOneWidget);
      expect(gateway.calls, isEmpty);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      await send('/status');
      expect(find.text('Ready for messages'), findsOneWidget);
      expect(gateway.calls.map((call) => call.$1), ['slash.exec']);
      expect(gateway.calls.last.$2, {
        'profile': 'work',
        'session_id': 'runtime',
        'command': '/status',
      });
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      await send('/report');
      expect(
        tester.widget<TextField>(composer).controller?.text,
        'Draft with a report',
      );
      expect(gateway.calls.last.$1, 'command.dispatch');
      expect(gateway.calls[1].$1, 'commands.catalog');
      expect(gateway.calls[1].$2, {'profile': 'work', 'session_id': 'runtime'});
      expect(gateway.calls.last.$2, {
        'profile': 'work',
        'session_id': 'runtime',
        'name': 'report',
        'arg': '',
      });

      await send('/release notes');
      expect(gateway.calls.last.$1, 'prompt.submit');
      expect(gateway.calls.last.$2, {
        'profile': 'work',
        'session_id': 'runtime',
        'text': 'Expanded gateway prompt',
      });
      expect(find.text('Expanded gateway prompt'), findsNothing);
      expect(find.text('/release notes'), findsOneWidget);
      expect(tester.widget<TextField>(composer).controller?.text, isEmpty);
    },
  );
}
