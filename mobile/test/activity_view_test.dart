import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/activity_view.dart';
import 'package:hermes_mobile/timeline.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'live reasoning starts with a bounded preview and expands on tap',
    (tester) async {
      final text = '开始分析。${List.filled(55, '这是一条思考记录。').join()}最新一段。';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ReasoningPreview(text: text)),
        ),
      );
      expect(find.text('正在思考'), findsOneWidget);
      expect(find.textContaining('最新一段。'), findsOneWidget);
      expect(find.textContaining('开始分析。'), findsNothing);
      await tester.tap(find.text('正在思考'));
      await tester.pump();
      expect(find.text(text), findsOneWidget);
      await tester.tap(find.text('正在思考'));
      await tester.pump();
      expect(find.textContaining('最新一段。'), findsNothing);
      expect(find.text('正在思考'), findsOneWidget);
    },
  );

  testWidgets(
    'consecutive activities summarize and retain the individual results',
    (tester) async {
      final rows = displayRows([
        {'role': 'user', 'content': '测试请求', 'id': 1},
        {
          'role': 'assistant',
          'reasoning_content': '先读取配置',
          'tool_calls': [
            {
              'id': 'skill',
              'function': {
                'name': 'skill_view',
                'arguments': '{"name":"fixture"}',
              },
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'skill', 'content': '技能说明'},
        {
          'role': 'tool',
          'name': 'terminal',
          'content': '{"exit_code":1,"output":"文件不存在"}',
        },
        {'role': 'assistant', 'content': '已完成', 'id': 5},
        {'role': 'tool', 'name': 'read_file', 'content': '另一个文件'},
      ]).toList();
      final timeline = groupTimeline(rows);
      expect(timeline.map((item) => item.runtimeType), [
        TimelineMessage,
        TimelineActivity,
        TimelineMessage,
        TimelineActivity,
      ]);
      final activity = timeline[1] as TimelineActivity;
      expect(activity.rows[1].arguments, '{"name":"fixture"}');
      expect(activity.rows.last.failed, isTrue);
      final hidden =
          groupTimeline(rows, showReasoning: false)[1] as TimelineActivity;
      expect(hidden.rows.map((row) => row.activity), [
        'skill_view',
        'terminal',
      ]);
      expect(
        (groupTimeline(rows, expandReasoning: true)[1] as TimelineActivity)
            .expanded,
        isTrue,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ActivityGroup(activity: activity)),
        ),
      );
      expect(find.text('执行过程 · 2 项操作'), findsOneWidget);
      expect(find.text('1 项失败'), findsOneWidget);
      expect(find.text('fixture'), findsNothing);
      expect(find.text('skill_view'), findsNothing);
      await tester.tap(find.text('执行过程 · 2 项操作'));
      await tester.pumpAndSettle();
      expect(find.text('fixture'), findsOneWidget);
      await tester.tap(find.text('加载技能'));
      await tester.pumpAndSettle();
      expect(find.text('{"name":"fixture"}'), findsOneWidget);
      expect(find.text('技能说明'), findsOneWidget);
    },
  );
}
