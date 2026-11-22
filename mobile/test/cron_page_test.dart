import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hermes_mobile/cron_page.dart';
import 'package:hermes_mobile/gateway.dart';

class _CronGateway extends Gateway {
  _CronGateway() : super('http://127.0.0.1:9119', '');
  final requests = <(String?, String, Json?)>[];
  bool paused = false;
  Json get job => {
    'id': 'routine-1',
    'profile': 'work',
    'name': '日报',
    'schedule': {'expr': '0 9 * * *'},
    'enabled': !paused,
    'state': paused ? 'paused' : 'scheduled',
    'prompt': '汇总日报',
  };

  @override
  Future<List<Json>> apiRows(String path, {Map<String, String>? query}) async {
    expect(path, cronJobsPath);
    expect(query?['profile'], 'work');
    return [
      job,
      {...job, 'id': 'other', 'profile': 'other', 'name': '其他档案'},
    ];
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
    requests.add((method, path, body));
    if (path.endsWith('/runs')) {
      return {
        'runs': [
          {
            'id': 'run-1',
            'profile': 'work',
            'title': '前一次运行',
            'ended_at': 1795000000,
          },
        ],
      };
    }
    if (path.endsWith('/pause')) paused = true;
    if (path.endsWith('/resume')) paused = false;
    return job;
  }
}

void main() {
  testWidgets(
    'cron actions use the selected profile and an ended run opens its session',
    (tester) async {
      final gateway = _CronGateway();
      addTearDown(gateway.close);
      Json? open;
      await tester.pumpWidget(
        MaterialApp(
          home: CronPage(
            gateway: gateway,
            profile: 'work',
            openConversation: (run) => open = run,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('日报'), findsOneWidget);
      expect(find.text('其他档案'), findsNothing);

      await tester.tap(find.text('日报'));
      await tester.pumpAndSettle();
      expect(find.text('前一次运行'), findsOneWidget);

      await tester.tap(find.byTooltip('任务操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('暂停'));
      await tester.pumpAndSettle();
      expect(find.text('已暂停'), findsOneWidget);
      expect(
        gateway.requests,
        contains(('POST', '$cronJobsPath/routine-1/pause', null)),
      );

      await tester.tap(find.text('立即运行'));
      await tester.pumpAndSettle();
      expect(gateway.requests.any((req) => req.$2.endsWith('/trigger')), false);
      await tester.tap(find.text('运行'));
      await tester.pumpAndSettle();
      expect(
        gateway.requests,
        contains(('POST', '$cronJobsPath/routine-1/trigger', null)),
      );

      await tester.tap(find.text('前一次运行'));
      await tester.pumpAndSettle();
      expect(open?['id'], 'run-1');
    },
  );
}
