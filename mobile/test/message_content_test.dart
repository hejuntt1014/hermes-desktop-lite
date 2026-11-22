import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/message_content.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('repeated references render one preview in a restored message', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGNQzk0lCTGMahjVMHw1AAD++vUBLaREPQAAAABJRU5ErkJggg==';
    final gateway = Gateway('https://localhost', '');
    addTearDown(gateway.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageContent(
            body: '@image:$png\ncaption\nMEDIA:$png',
            gateway: gateway,
            profile: 'default',
            session: 'qa',
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ChatImage), findsOneWidget);
  });
}
