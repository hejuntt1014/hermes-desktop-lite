import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/conversation_files.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/protocol.dart';
import 'package:hermes_mobile/transcript_navigation.dart';

class _FileHistory extends Gateway {
  _FileHistory() : super('https://localhost', '');
  final queries = <Map<String, String>>[];

  @override
  Future<Json> api(
    String path, {
    Map<String, String>? query,
    Json? body,
    String? method,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    expect(path, 'api/sessions/current/messages/around');
    queries.add(query!);
    return {
      'session_id': 'current',
      'profile': 'work',
      'pagination': {'offset': 0},
      'messages': [
        {
          'role': 'user',
          'id': 7,
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,YQ=='},
            },
            {
              'type': 'image_url',
              'image_url': {'url': '/home/output.png'},
            },
          ],
        },
      ],
    };
  }
}

void main() {
  test('file collection keeps attachment scope and message identity', () async {
    final rows = <HistoryRecord>[
      (
        row: {
          'id': 9,
          'role': 'tool',
          'content': '{"host_image":"./graph.png"}',
        },
        tailOffset: 0,
      ),
      (
        row: {
          'id': 8,
          'role': 'assistant',
          'content':
              '[季度报告](./reports/Q%204.xlsx#overview)\n'
              '[网页](https://example.org/a.xlsx)\n'
              '~~'
              '~text\n@file:/ignored.txt\n~~'
              '~',
        },
        tailOffset: 1,
      ),
      (
        row: {'id': 7, 'role': 'user', 'content': '[image]\n[image]'},
        tailOffset: 2,
      ),
      (
        row: {'id': 1, 'role': 'user', 'content': '@file:"monthly report.pdf"'},
        tailOffset: 6,
      ),
    ];
    final files = await scanConversationFiles(rows, '/project');
    expect(files.map((file) => file.name), [
      'graph.png',
      '季度报告',
      '图片',
      '图片',
      'monthly report.pdf',
    ]);
    expect(files[0].address.rowId, 9);
    expect(files[1].path, '/project/./reports/Q 4.xlsx');
    expect(files[1].address.tailOffset, 1);
    expect(files.last.address.promptId, 1);
    final gateway = _FileHistory();
    addTearDown(gateway.close);
    final navigation = TranscriptNavigation(gateway, 'work', 'current');
    expect(await files[2].resolve(navigation), 'data:image/png;base64,YQ==');
    expect(await files[3].resolve(navigation), '/home/output.png');
    expect(gateway.queries.first, {
      'profile': 'work',
      'row_id': '7',
      'limit': '120',
    });
  });

  test(
    'native XLSX reader switches visible sheets and retains sparse cells',
    () {
      const fixture = 'test/fixtures/preview.xlsx';
      final first = workbookSheet(fixture, 0);
      expect(first['sheets'], ['总览', '明细']);
      expect(first['rows'], 3);
      expect(first['columns'], 3);
      expect(first['cells'], [
        [0, 0, '测试表'],
        [2, 2, '42'],
      ]);
      final second = workbookSheet(fixture, 1);
      expect(second['cells'], [
        [0, 0, 'true'],
        [0, 1, '3'],
      ]);
      expect(workbookSheet(fixture, 2)['error'], 'no_sheet');
    },
  );
}
