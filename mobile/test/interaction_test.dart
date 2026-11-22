import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/interaction.dart';

void main() {
  testWidgets(
    'clarification keeps question IDs and serializes multi-select answers',
    (tester) async {
      final prompt = Interaction.fromPrompt('clarify', {
        'prompt_id': 'clarify-1',
        'questions': [
          {
            'qid': 'first',
            'question': '选两项',
            'choices': ['A', 'B'],
            'multi_select': true,
          },
          {'qid': 'second', 'question': '补充说明'},
        ],
      }, 4)!;
      Json? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  result = await showModalBottomSheet<Json>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => InteractionSheet(interaction: prompt),
                  );
                },
                child: const Text('打开问题'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开问题'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A'));
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('提交'));
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(result, {
        'outcome': 'submitted',
        'answers': {'first': '["A","B"]', 'second': null},
      });
    },
  );
}
