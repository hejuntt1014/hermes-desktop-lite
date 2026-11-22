import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/profile_manager.dart';
import 'package:hermes_mobile/profiles.dart';
import 'package:material_ui/material_ui.dart';

class _ProfileGateway extends Gateway {
  _ProfileGateway() : super('http://127.0.0.1:9119', '');
  String remote = '最初的指令';
  final writes = <({String path, String? method, Json? body})>[];
  final reads = <({String path, Map<String, String>? query})>[];
  bool created = false;

  @override
  Future<Json> api(
    String path, {
    Map<String, String>? query,
    Json? body,
    String? method,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (method == 'POST' || method == 'PUT') {
      writes.add((path: path, method: method, body: body));
      if (path.endsWith('/soul')) {
        expect(query?['profile'], 'blue');
        remote = body!['content'] as String;
      } else {
        created = true;
      }
      return {'ok': true};
    }
    reads.add((path: path, query: query));
    if (path == 'api/profiles') {
      return {
        'profiles': [
          {'name': 'default', 'is_default': true},
          {
            'name': 'blue',
            'display_name': '蓝色档案',
            'path': '/profiles/blue',
            'model': 'fixture-model',
            'provider': 'codex',
            'skill_count': 3,
          },
          if (created) {'name': 'blue-copy'},
        ],
      };
    }
    if (path.endsWith('/soul')) {
      expect(query?['profile'], 'blue');
      return {'exists': true, 'content': remote};
    }
    return {'text': '第一段记忆\n第二段测试内容'};
  }
}

void main() {
  test('SOUL save checks remote content and settles an already-applied draft without replay', () async {
    final gateway = _ProfileGateway();
    addTearDown(gateway.close);
    final service = ProfileService(gateway);
    final original = await service.soul('blue');
    gateway.remote = '别处改过';
    expect(await service.saveSoul('blue', original, '新的指令'), false);
    expect(gateway.writes, isEmpty);
    final current = await service.soul('blue');
    expect(await service.saveSoul('blue', current, '新的指令'), true);
    expect(await service.saveSoul('blue', current, '新的指令'), true);
    expect(gateway.writes.single.body, {'content': '新的指令'});
  });

  testWidgets(
    'profile details retain the SOUL draft while reading and filtering a scoped memory document',
    (tester) async {
      final gateway = _ProfileGateway();
      addTearDown(gateway.close);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileManager(
            service: ProfileService(gateway),
            activeProfile: 'default',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('蓝色档案'));
      await tester.pumpAndSettle();
      expect(find.text('fixture-model · codex'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '未保存草稿');
      await tester.tap(find.text('MEMORY.md'));
      await tester.pumpAndSettle();
      expect(gateway.reads.last.query, {
        'profile': 'blue',
        'path': '/profiles/blue/memories/MEMORY.md',
      });
      await tester.enterText(find.byType(TextField), '第二');
      await tester.pumpAndSettle();
      expect(find.text('第二段测试内容'), findsOneWidget);
      await tester.tap(find.text('SOUL.md').first);
      await tester.pumpAndSettle();
      expect(find.text('未保存草稿'), findsOneWidget);
      expect(gateway.writes, isEmpty);
    },
  );

  testWidgets('clone uses the source profile without copying credentials', (
    tester,
  ) async {
    final gateway = _ProfileGateway();
    addTearDown(gateway.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileManager(
          service: ProfileService(gateway),
          activeProfile: 'default',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('蓝色档案'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('克隆档案'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'blue-copy');
    await tester.tap(find.text('创建档案'));
    await tester.pumpAndSettle();
    final request = gateway.writes.single;
    expect(request.path, 'api/profiles');
    expect(request.body, {
      'name': 'blue-copy',
      'clone_from': 'blue',
      'clone_channels': false,
      'mirror_credentials': false,
      'share_auth': false,
    });
  });
}
