import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway_book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'last connected gateway and rotated credentials survive relaunch',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final book = GatewayBook();
      const first = 'https://first.example/';
      const second = 'https://second.example/hermes/';
      await book.remember(
        const SavedGateway(first, '', {'refresh_token': 'old'}),
      );
      await book.remember(const SavedGateway(second, 'another-token', null));
      await book.remember(
        const SavedGateway(first, '', {'refresh_token': 'new'}),
      );

      final restored = GatewayBook();
      await restored.load();
      expect(restored.entries.map((e) => e.address), [first, second]);
      expect(restored.entries.first.session?['refresh_token'], 'new');
      expect(restored.entries.last.token, 'another-token');
      await restored.forget(first);
      await book.load();
      expect(book.entries.single.address, second);
    },
  );
}
