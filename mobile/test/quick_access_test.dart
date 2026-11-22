import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/chat.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/message_bookmarks.dart';
import 'package:hermes_mobile/mobile_settings.dart';
import 'package:hermes_mobile/quick_access.dart';
import 'package:hermes_mobile/transcript_navigation.dart';
import 'package:material_ui/material_ui.dart';

class _QuickGateway extends Gateway {
  _QuickGateway() : super('quick.test', '');
  final searches = <String, Completer<Json>>{};
  final requested = <Map<String, String>>[];

  @override
  Future<Json> api(
    String path, {
    Map<String, String>? query,
    Json? body,
    String? method,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requested.add(query!);
    if (path == 'api/sessions') {
      return {
        'sessions': [
          {'id': 'recent', 'title': '最近的会话', 'profile': 'work'},
        ],
      };
    }
    if (path == 'api/sessions/search') {
      return searches.putIfAbsent(query['q']!, Completer<Json>.new).future;
    }
    throw StateError(path);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'appearance preference survives a new instance and serializes choices',
    () async {
      final appearance = MobileAppearance();
      addTearDown(appearance.dispose);
      expect(appearance.mode, ThemeMode.system);
      await appearance.select(ThemeMode.dark);
      final reloaded = MobileAppearance();
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.mode, ThemeMode.dark);
      await Future.wait([
        reloaded.select(ThemeMode.light),
        reloaded.select(ThemeMode.system),
      ]);
      await appearance.load();
      expect(appearance.mode, ThemeMode.system);
    },
  );

  testWidgets(
    'quick access keeps bookmark and search results scoped, ignoring late results',
    (tester) async {
      final gateway = _QuickGateway();
      addTearDown(gateway.close);
      final books = MessageBookmarks.forGateway(gateway);
      await books.setSaved(
        const MessageBookmark(
          profile: 'work',
          session: 'local-bookmark',
          title: '本档案书签',
          excerpt: '已收藏消息',
          address: MessageAddress(18),
        ),
        saved: true,
      );
      await books.setSaved(
        const MessageBookmark(
          profile: 'other',
          session: 'outside-bookmark',
          title: '其他档案书签',
          excerpt: '其他档案消息',
          address: MessageAddress(21),
        ),
        saved: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: QuickAccessPage(
            gateway: gateway,
            profile: 'work',
            actions: QuickAction.values,
            recent: const [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('最近的会话'), findsOneWidget);
      expect(find.text('已收藏消息'), findsOneWidget);
      expect(find.text('其他档案消息'), findsNothing);
      final input = find.byType(TextField);
      await tester.enterText(input, 'first');
      await tester.pump(const Duration(milliseconds: 260));
      await tester.enterText(input, 'next');
      await tester.pump(const Duration(milliseconds: 260));
      gateway.searches['next']!.complete({
        'results': [
          {'id': 'right', 'title': '当前结果', 'profile': 'work'},
          {'id': 'outside', 'title': '其他档案结果', 'profile': 'other'},
        ],
      });
      await tester.pumpAndSettle();
      gateway.searches['first']!.complete({
        'results': [
          {'id': 'old', 'title': '过期结果', 'profile': 'work'},
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('当前结果'), findsOneWidget);
      expect(find.text('其他档案结果'), findsNothing);
      expect(find.text('过期结果'), findsNothing);
      expect(
        gateway.requested.every((query) => query['profile'] == 'work'),
        isTrue,
      );
    },
  );

  testWidgets(
    'chat keyboard shortcut opens settings without discarding the composer',
    (tester) async {
      final gateway = _QuickGateway();
      addTearDown(gateway.close);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatPage(
            gateway: gateway,
            profile: 'work',
            id: null,
            title: '新会话',
            onLibrary: () {},
            onNew: () {},
            recent: const [],
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '未发送草稿');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('快捷入口'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('设置'),
        150,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('网关连接'), findsOneWidget);
      expect(find.text('跟随系统'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(
              find.ancestor(
                of: find.text('跟随系统'),
                matching: find.byType(ListTile),
              ),
            )
            .selected,
        isTrue,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('未发送草稿'), findsOneWidget);
    },
  );
}
