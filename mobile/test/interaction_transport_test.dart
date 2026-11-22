import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/interaction.dart';

void main() {
  test(
    'peer approval response echoes the same request and cannot answer twice',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final gateway = Gateway('http://127.0.0.1:${server.port}', 'test-token');
      addTearDown(() async {
        gateway.close();
        await server.close(force: true);
      });
      final reply = Completer<Json>();
      server.listen((http) async {
        if (http.uri.path == '/api/status') {
          http.response.write('{}');
          await http.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(http);
        socket.add(
          jsonEncode({
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'session_authority': true},
            },
          }),
        );
        socket.listen((value) {
          final frame = jsonDecode(value as String) as Json;
          if (frame['method'] == 'client.capabilities') {
            socket.add(
              jsonEncode({
                'id': frame['id'],
                'result': {'canonical_clarify_batch': true},
              }),
            );
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': 'req-1',
                'method': 'approval',
                'params': {
                  'session_id': 'runtime',
                  'request_id': 'prompt-4',
                  'description': '请求确认',
                  'choices': ['once', 'session', 'always', 'deny'],
                  'allow_permanent': false,
                },
              }),
            );
          } else {
            reply.complete(frame);
          }
        });
      });
      final arriving = gateway.events.firstWhere(
        (event) => event['type'] == 'client.interaction',
      );
      await gateway.connect();
      expect(
        gateway.promptParams('runtime', 'work', 'question')['clarify_batch'],
        true,
      );
      final arrival = await arriving;
      expect(arrival['session_id'], 'runtime');
      final interaction = Interaction.fromRequest(arrival['payload'] as Json)!;
      expect(interaction.approvals, ['once', 'session', 'deny']);
      await interaction.answer(gateway, 'runtime', 'work', {'choice': 'deny'});
      expect(await reply.future, {
        'jsonrpc': '2.0',
        'id': 'req-1',
        'result': {'choice': 'deny'},
      });
      expect(gateway.pendingInteractionRequests, isEmpty);
      await expectLater(
        interaction.answer(gateway, 'runtime', 'work', {'choice': 'once'}),
        throwsA(isA<GatewayError>()),
      );
    },
  );
}
