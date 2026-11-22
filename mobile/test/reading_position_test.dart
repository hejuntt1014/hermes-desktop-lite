import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/chat.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/history.dart';
import 'package:hermes_mobile/reading_position.dart';
import 'package:hermes_mobile/transcript_navigation.dart';
import 'package:material_ui/material_ui.dart';

class _ReadingGateway extends Gateway {
  _ReadingGateway() : super('https://reading.local', '');
  final requested = <int>[];
  final around = <int>[];

  List<Json> rows(int start, int end) => [
    for (var id = start; id <= end; id++)
      {'role': id.isOdd ? 'user' : 'assistant', 'content': '消息 $id', 'id': id},
  ];

  @override
  Future<HistoryPage> historyPage(
    String profile,
    String id,
    int offset, {
    FileTransferControl? control,
  }) async {
    requested.add(offset);
    return HistoryPage(
      sessionId: id,
      rows: rows(22001 - offset, 22080 - offset),
      nextOffset: offset + 79,
    );
  }

  @override
  Future<Json> openSession(
    String profile,
    String? id, {
    bool paged = false,
    Json? launch,
  }) async => {
    'session_id': 'runtime',
    'stored_session_id': id,
    'messages_omitted': true,
  };

  @override
  Future<Json> api(
    String path, {
    Map<String, String>? query,
    Json? body,
    String? method,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (path.endsWith('/messages/around')) {
      final id = int.parse(query!['row_id']!);
      around.add(id);
      return {
        'session_id': 'stored',
        'profile': 'work',
        'pagination': {'offset': id - 15, 'has_older': true, 'has_newer': true},
        'messages': rows(id - 15, id + 35),
      };
    }
    throw StateError(path);
  }
}

Widget _chat(_ReadingGateway gateway) => MaterialApp(
  home: ChatPage(
    gateway: gateway,
    profile: 'work',
    id: 'stored',
    title: '长会话',
    onLibrary: () {},
    onNew: () {},
    recent: const [],
    onOpen: (_) {},
  ),
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'reopens a deep row at its saved offset without paging from the tail',
    (tester) async {
      final gateway = _ReadingGateway();
      addTearDown(gateway.close);
      final store = ReadingPositions(gateway, 'work', 'stored');
      await store.write(
        const ReadingPosition(
          MessageAddress(1012, promptId: 1011, tailOffset: 21068),
          23,
        ),
      );
      final other = ReadingPositions(gateway, 'personal', 'stored');
      expect(await other.read(), isNull);

      await tester.pumpWidget(_chat(gateway));
      await tester.pumpAndSettle();
      expect(gateway.requested, [0]);
      expect(gateway.around, [1011]);
      expect(find.text('消息 1012'), findsOneWidget);
      final window = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      expect(window.controller?.offset, closeTo(23, 1));
      await tester.tap(find.text('回到最新'));
      await tester.pumpAndSettle();
      expect(find.text('消息 22080'), findsOneWidget);
      expect(await store.read(), isNull);
    },
  );

  testWidgets(
    'an actual drag records a position and a new chat widget restores it',
    (tester) async {
      final gateway = _ReadingGateway();
      addTearDown(gateway.close);
      await tester.pumpWidget(_chat(gateway));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 340));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 240));
      final saved = await ReadingPositions(gateway, 'work', 'stored').read();
      expect(saved?.address.tailOffset, greaterThan(0));
      expect(saved?.address.rowId, lessThan(22080));
      final reopening = _ReadingGateway();
      addTearDown(reopening.close);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_chat(reopening));
      await tester.pumpAndSettle();
      expect(find.text('回到最新'), findsOneWidget);
      expect(find.text('消息 ${saved!.address.rowId}'), findsOneWidget);
      final window = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      expect(window.controller?.offset, closeTo(saved.offset, 1));
    },
  );
}
