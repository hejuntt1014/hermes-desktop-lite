import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/attachment_view.dart';
import 'package:hermes_mobile/gateway.dart';

void main() {
  test('attachment references preserve quoted names', () {
    expect(attachedPath('@file:`attachments/a b.txt`'), 'attachments/a b.txt');
    expect(attachedPath('@file:attachments/a.txt'), 'attachments/a.txt');
    expect(attachedPath('@file:attachments/a.txt additional text'), isNull);
    expect(attachedPath('@file:..'), isNull);
  });

  for (final uploadStatus in [200, 404, 413]) {
    test('attachment transport respects upload status $uploadStatus', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final gateway = Gateway('http://127.0.0.1:${server.port}', 'test-token');
      addTearDown(() async {
        gateway.close();
        await server.close(force: true);
      });

      final original = Uint8List.fromList([0, 42, 255, 10]);
      final requests = <Json>[];
      final body = BytesBuilder();
      final observed = <String, String?>{};

      server.listen((http) async {
        final response = http.response;
        switch (http.uri.path) {
          case '/api/status':
            response.write('{}');
          case '/api/ws':
            final socket = await WebSocketTransformer.upgrade(http);
            socket.add(
              jsonEncode({
                'method': 'event',
                'params': {
                  'type': 'gateway.ready',
                  'payload': {'session_authority': uploadStatus == 200},
                },
              }),
            );
            socket.listen((raw) {
              final request = jsonDecode(raw as String) as Json;
              if (request['method'] == 'client.capabilities') {
                socket.add(jsonEncode({'id': request['id'], 'result': {}}));
                return;
              }
              requests.add(request);
              socket.add(
                jsonEncode({
                  'id': request['id'],
                  'result': {
                    'attached': true,
                    'ref_text': '@file:`attachments/a b.txt`',
                  },
                }),
              );
            });
            return;
          case '/api/chat/file-upload':
            observed['uploadProfile'] = http.uri.queryParameters['profile'];
            observed['uploadToken'] = http.headers.value(
              'X-Hermes-Session-Token',
            );
            await for (final chunk in http) {
              body.add(chunk);
            }
            response.statusCode = uploadStatus;
            if (uploadStatus == 200) {
              response.write(
                jsonEncode({
                  'path': '/uploads/staged',
                  'staged_upload': {
                    'home': '/profile',
                    'path': '/uploads/staged',
                  },
                }),
              );
            }
          case '/api/fs/download':
            observed['downloadProfile'] = http.uri.queryParameters['profile'];
            observed['downloadSession'] =
                http.uri.queryParameters['session_id'];
            observed['downloadPath'] = http.uri.queryParameters['path'];
            response.add(original);
          case '/api/cron/jobs':
            observed['cronProfile'] = http.uri.queryParameters['profile'];
            response.write('[{"id":"job-1"}]');
          default:
            response.statusCode = 404;
        }
        await response.close();
      });

      await gateway.connect();
      final dir = await Directory.systemTemp.createTemp('hermes-file-test-');
      addTearDown(() => dir.delete(recursive: true));
      final source = await File('${dir.path}/a b.txt').writeAsBytes(original);
      final picked = XFile(source.path);
      final attachment = gateway.attachFile(
        picked,
        sessionId: 'runtime-1',
        profile: 'work',
      );

      if (uploadStatus == 413) {
        await expectLater(
          attachment,
          throwsA(isA<GatewayError>().having((e) => e.status, 'status', 413)),
        );
        expect(requests, isEmpty);
      } else {
        expect(await attachment, '@file:`attachments/a b.txt`');
        final call = requests.single;
        expect(call['method'], 'file.attach');
        final params = call['params'] as Json;
        expect(params['session_id'], 'runtime-1');
        expect(params['profile'], 'work');
        expect(params['name'], 'a b.txt');
        if (uploadStatus == 200) {
          expect(params['staged_upload'], {
            'home': '/profile',
            'path': '/uploads/staged',
          });
          expect(params.containsKey('data_url'), false);
        } else {
          expect(
            UriData.parse(params['data_url'] as String).contentAsBytes(),
            original,
          );
        }
      }
      final payload = latin1.decode(body.takeBytes());
      expect(payload, contains('filename="a b.txt"'));
      expect(payload, contains(latin1.decode(original)));
      expect(observed['uploadProfile'], 'work');
      expect(observed['uploadToken'], 'test-token');
      final downloaded = File('${dir.path}/saved.txt');
      await gateway.downloadFile(
        'attachments/a b.txt',
        downloaded,
        sessionId: 'stored-1',
        profile: 'work',
      );
      expect(await downloaded.readAsBytes(), original);
      expect(observed['downloadProfile'], 'work');
      expect(observed['downloadSession'], 'stored-1');
      expect(observed['downloadPath'], 'attachments/a b.txt');
      expect(
        await gateway.apiRows('api/cron/jobs', query: {'profile': 'work'}),
        [
          {'id': 'job-1'},
        ],
      );
      expect(observed['cronProfile'], 'work');
    });
  }
}
