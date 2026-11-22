import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hermes_mobile/chat.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/history.dart';
import 'package:hermes_mobile/protocol.dart';
import 'package:material_ui/material_ui.dart';

HistoryPage page(
  int first,
  int last, {
  int? nextOffset,
  String id = 'orders',
}) => HistoryPage(
  sessionId: id,
  nextOffset: nextOffset,
  rows: [
    for (var i = first; i <= last; i++)
      {'id': i, 'role': 'assistant', 'content': '记录 $i'},
  ],
);

class HistoryGateway extends Gateway {
  HistoryGateway({this.limitReached = false}) : super('https://localhost', '');
  final bool limitReached;
  final offsets = <int>[];
  Completer<void>? olderRequest;
  bool? paged;

  @override
  Future<HistoryPage> historyPage(
    String profile,
    String id,
    int offset, {
    FileTransferControl? control,
  }) async {
    expect(profile, 'dingding');
    expect(id, 'orders');
    offsets.add(offset);
    if (offset > 0) {
      final release = Completer<void>();
      olderRequest = release;
      await release.future;
    }
    final end = 20080 - offset;
    final selected = page(end - 79, end, nextOffset: offset + 79);
    // Stored system rows have no bubble in the timeline.
    for (final row in selected.rows) {
      if ((row['id'] as int) % 20 != 0) row['role'] = 'system';
    }
    return selected;
  }

  @override
  Future<Json> openSession(
    String profile,
    String? id, {
    bool paged = false,
    Json? launch,
  }) async {
    this.paged = paged;
    if (limitReached) throw GatewayError.rpc('Remote guard', 4130, null);
    return {
      'session_id': 'live',
      'stored_session_id': id,
      'messages_omitted': true,
    };
  }
}

void main() {
  test('paged session request restores only the active segment', () {
    final params = sessionParams(
      create: false,
      canonical: false,
      key: 'orders',
      paged: true,
    );
    expect(params['defer_history'], true);
    expect(params['omit_messages'], true);
  });

  test('an overlapping page joins once and refuses a changed lineage', () {
    final first = page(20001, 20080, nextOffset: 79);
    final prefix = olderPrefix(first, page(19924, 20003, nextOffset: 158));
    expect(prefix.last['id'], 20000);
    expect(prefix.length, 77);
    expect(
      () => olderPrefix(first, page(19924, 20003, id: 'successor')),
      throwsA(isA<GatewayError>()),
    );
  });

  for (final limitReached in [false, true]) {
    testWidgets('stored history is readable with runtime guard=$limitReached', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(800, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = HistoryGateway(limitReached: limitReached);
      addTearDown(gateway.close);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatPage(
            gateway: gateway,
            profile: 'dingding',
            id: 'orders',
            title: '下单',
            onLibrary: () {},
            onNew: () {},
            recent: const [],
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(gateway.paged, true);
      expect(gateway.offsets, [0]);
      expect(find.text('记录 20080'), findsOneWidget);
      final send = find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == '发送',
      );
      expect(tester.widget<IconButton>(send).onPressed, isNull);
      if (!limitReached) {
        await tester.enterText(find.byType(TextField), '测试消息');
        await tester.pump();
        expect(tester.widget<IconButton>(send).onPressed, isNotNull);
      }
      if (limitReached) {
        expect(find.text('当前会话超过网关的恢复上限，可查看历史或新建会话。'), findsOneWidget);
      }
      final scrollable = find.byType(Scrollable).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      final loadEarlier = find.text('查看更早消息').hitTestable();
      for (var index = 1; index <= 3; index++) {
        for (
          var drag = 0;
          drag < 12 && gateway.offsets.length <= index;
          drag++
        ) {
          if (loadEarlier.evaluate().isNotEmpty) {
            await tester.tap(loadEarlier);
          } else {
            await tester.drag(scrollable, const Offset(0, 260));
          }
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(gateway.offsets, [for (var n = 0; n <= index; n++) n * 79]);
        await tester.pump(const Duration(seconds: 1));
        final oldPosition = position.pixels;
        gateway.olderRequest!.complete();
        await tester.pumpAndSettle();
        expect(gateway.offsets, [for (var n = 0; n <= index; n++) n * 79]);
        expect(position.pixels, closeTo(oldPosition, 1));
      }
      position.jumpTo(position.minScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('记录 20080'), findsOneWidget);
    });
  }
}
