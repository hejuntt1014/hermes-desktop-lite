import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/model_picker.dart';
import 'package:material_ui/material_ui.dart';

class _CatalogGateway extends Gateway {
  _CatalogGateway() : super('http://127.0.0.1:9119', '');
  final requests = <Json>[];
  @override
  Future<Json> call(
    String method,
    Json params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    expect(method, 'model.options');
    requests.add(params);
    return {
      'model': 'gpt-6.2-sol-900k',
      'provider': 'openai',
      'providers': [
        {
          'slug': 'openai',
          'name': 'OpenAI',
          'models': ['gpt-6.2-sol-900k', 'gpt-6.2-astra-900k'],
          'capabilities': {
            'gpt-6.2-sol-900k': {'reasoning': true, 'ultrafast': true},
          },
        },
        {
          'slug': 'other',
          'name': '其他供应商',
          'models': ['gpt-6.2-sol-900k'],
        },
      ],
    };
  }
}

void main() {
  testWidgets(
    'composer abbreviates the label and settings return a reasoning change',
    (tester) async {
      tester.view.physicalSize = const Size(360, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = _CatalogGateway();
      addTearDown(gateway.close);
      ModelPickerResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ModelControl(
                model: 'gpt-6.2-sol-900k',
                effort: 'low',
                onPressed: () async {
                  result = await showModalBottomSheet<ModelPickerResult>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => ModelPicker(
                      gateway: gateway,
                      profile: 'work',
                      selected: 'gpt-6.2-sol-900k',
                      provider: 'openai',
                      effort: 'low',
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('6.2 Sol'), findsOneWidget);
      expect(find.text('轻度'), findsOneWidget);
      await tester.tap(find.text('6.2 Sol'));
      await tester.pumpAndSettle();
      expect(find.text('模型设置'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.tap(find.byTooltip('刷新模型'));
      await tester.pumpAndSettle();
      expect(gateway.requests.last['refresh'], isTrue);
      await tester.tap(find.text('推理与速度'));
      await tester.pumpAndSettle();
      expect(find.text('Ultrafast'), findsOneWidget);
      final slider = find.byType(Slider);
      expect(tester.widget<Slider>(slider).value, 2);
      final track = tester.getRect(slider).deflate(19);
      await tester.tapAt(
        Offset(track.left + track.width * 4 / 7, track.center.dy),
      );
      await tester.pumpAndSettle();
      expect(find.text('高强度'), findsOneWidget);
      expect(result, isNull);
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(result?.effort, 'high');
      expect(result?.model, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
