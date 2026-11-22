import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/message_bookmarks.dart';
import 'package:hermes_mobile/transcript_navigation.dart';
import 'package:hermes_mobile/transcript_explorer.dart';
import 'package:hermes_mobile/transcript_reader.dart';
import 'package:hermes_mobile/transcript_search.dart';
import 'package:material_ui/material_ui.dart';

class _TranscriptGateway extends Gateway {
  _TranscriptGateway({
    this.around = true,
    this.grow = false,
    this.hostname = 'host',
  }) : super('http://$hostname:9119', '');
  final bool around, grow;
  final String hostname;
  final requests = <(String, Map<String, String>)>[];
  int end = 20550;
  static const start = 1;

  Map<String, dynamic> row(int id) => {
    'id': id,
    'role': id.isOdd ? 'user' : 'assistant',
    'content': id == 20 ? '**找到**答案' : '消息 $id',
  };

  @override
  Future<Json> api(
    String path, {
    Map<String, String>? query,
    Json? body,
    String? method,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    expect(query?['profile'], 'work');
    requests.add((path, query!));
    if (path.endsWith('/around')) {
      if (!around) throw GatewayError('deprecated', 404);
      final anchor = int.parse(query['row_id']!);
      return {
        'session_id': 'saved',
        'profile': 'work',
        'messages': [row(anchor), row(anchor + 1)],
        'pagination': {
          'offset': anchor - 1,
          'has_older': true,
          'has_newer': true,
        },
      };
    }
    if (path.endsWith('/timeline')) {
      return {
        'session_id': 'saved',
        'profile': 'work',
        'entries': [
          {'row_id': 5, 'preview': '问题'},
        ],
        'pagination': {'has_more': true, 'next_cursor': 5},
      };
    }
    expect(path, '/api/sessions/saved/messages'.substring(1));
    final latest = query['order'] == 'latest';
    final offset = int.parse(query['offset']!);
    final limit = int.parse(query['limit']!);
    if (grow && requests.length == 2) end += 3;
    final first = latest
        ? (end - offset - limit + 1).clamp(start, end + 1)
        : start + offset;
    final last = latest ? end - offset : (first + limit - 1).clamp(start, end);
    return {
      'session_id': 'saved',
      'profile': 'work',
      'messages': [for (var n = first; n <= last; n++) row(n)],
      'pagination': {'offset': offset, 'limit': limit, 'order': query['order']},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an assistant reply in a very old turn can jump via one bounded around page', () async {
    final gateway = _TranscriptGateway();
    addTearDown(gateway.close);
    final navigation = TranscriptNavigation(gateway, 'work', 'saved');
    final page = await navigation.locate(
      const MessageAddress(20, promptId: 19),
    );
    expect(page.contains(20), true);
    expect(gateway.requests, hasLength(1));
    expect(gateway.requests.single.$2['row_id'], '19');
    final newer = await navigation.adjacent(page, older: false);
    expect(newer.rows.first['id'], 20);
    expect(newer.rows.last['id'], 99);
    final timeline = await navigation.timeline(null);
    expect(timeline.next, 5);
  });

  test(
    'old gateway verifies the saved row before using a search offset hint',
    () async {
      final gateway = _TranscriptGateway(around: false);
      addTearDown(gateway.close);
      final page = await TranscriptNavigation(
        gateway,
        'work',
        'saved',
      ).locate(const MessageAddress(20, promptId: 19, tailOffset: 20530));
      expect(page.contains(20), true);
      expect(gateway.requests, hasLength(2));
      expect(gateway.requests.last.$2['order'], 'latest');
    },
  );

  test('new tail rows during a scan do not duplicate older results', () async {
    final gateway = _TranscriptGateway(grow: true);
    addTearDown(gateway.close);
    final rows = await TranscriptNavigation(
      gateway,
      'work',
      'saved',
    ).scan().take(250).toList();
    expect(rows.map((item) => item.row['id']), [
      for (var id = 20550; id > 20300; id--) id,
    ]);
    expect(rows[160].tailOffset, 163);
    expect(gateway.requests, hasLength(2));
  });

  test('search indexes rendered Markdown and skips concealed rows', () async {
    final matches = await searchTranscriptBatch([
      (
        row: {'id': 20, 'role': 'assistant', 'content': '**找到**答案'},
        tailOffset: 20530,
      ),
      (
        row: {
          'id': 21,
          'role': 'user',
          'display_kind': 'hidden',
          'content': '找到答案',
        },
        tailOffset: 0,
      ),
    ], '找到答案');
    expect(matches.single.address.rowId, 20);
    expect(matches.single.address.tailOffset, 20530);
    expect(matches.single.excerpt, '找到答案');
  });

  test('bookmarks survive a new connection and stay separated by gateway and profile', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final a = _TranscriptGateway();
    final b = _TranscriptGateway(hostname: 'another');
    final c = _TranscriptGateway();
    for (final connection in [a, b, c]) {
      addTearDown(connection.close);
    }
    const first = MessageBookmark(
      profile: 'work',
      session: 'saved',
      title: '会话',
      excerpt: '一句话',
      address: MessageAddress(20, promptId: 19),
    );
    const other = MessageBookmark(
      profile: 'test',
      session: 'saved',
      title: '另一份',
      excerpt: '一句话',
      address: MessageAddress(20),
    );
    expect(
      await MessageBookmarks.forGateway(a).setSaved(first, saved: true),
      true,
    );
    expect(
      await MessageBookmarks.forGateway(a).setSaved(other, saved: true),
      true,
    );
    expect(await MessageBookmarks.forGateway(b).read(), isEmpty);
    final reopened = MessageBookmarks.forGateway(c);
    expect((await reopened.read()).map((mark) => mark.profile), [
      'test',
      'work',
    ]);
    expect(await reopened.setSaved(first, saved: false), false);
    expect((await reopened.read()).single.profile, 'test');
  });

  testWidgets('reader anchors an assistant message then pages forward', (
    tester,
  ) async {
    final gateway = _TranscriptGateway();
    addTearDown(gateway.close);
    await tester.pumpWidget(
      MaterialApp(
        home: TranscriptReader(
          navigation: TranscriptNavigation(gateway, 'work', 'saved'),
          title: '旧会话',
          address: const MessageAddress(20, promptId: 19),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('找到答案'), findsOneWidget);
    await tester.tap(find.text('下一段'));
    await tester.pumpAndSettle();
    expect(find.text('消息 21'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('timeline tab opens the bounded reader from the selected row', (
    tester,
  ) async {
    final gateway = _TranscriptGateway();
    addTearDown(gateway.close);
    await tester.pumpWidget(
      MaterialApp(
        home: TranscriptExplorer(
          gateway: gateway,
          profile: 'work',
          session: 'saved',
          title: '长会话',
        ),
      ),
    );
    await tester.tap(find.text('轮次'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('问题'));
    await tester.pumpAndSettle();
    expect(find.text('历史消息'), findsOneWidget);
    expect(find.text('消息 5'), findsOneWidget);
    expect(gateway.requests.last.$1.endsWith('/around'), true);
  });
}
