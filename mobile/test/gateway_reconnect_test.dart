import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway.dart';

void main() {
  test('expired browser credentials refresh before the status probe', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = Gateway('127.0.0.1:${server.port}', '')
      ..session = {
        'access_token': 'fixture-expired',
        'refresh_token': 'fixture-refresh',
        'expires_at': 0,
      };
    final routes = <String>[];
    addTearDown(() async {
      gateway.close();
      await server.close(force: true);
    });
    server.listen((request) async {
      final route = request.uri.path;
      routes.add(route);
      if (route == '/api/ws') {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'session_authority': true},
            },
          }),
        );
        socket.listen((raw) {
          final frame = jsonDecode(raw as String) as Json;
          socket.add(jsonEncode({'id': frame['id'], 'result': {}}));
        });
        return;
      }
      if (route == '/auth/native/refresh') {
        await request.drain<void>();
        request.response.write(
          jsonEncode({
            'access_token': 'fixture-current',
            'refresh_token': 'fixture-renewed',
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          }),
        );
      } else if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer fixture-current') {
        request.response.statusCode = 401;
      } else {
        request.response.write(
          route == '/api/status'
              ? '{"auth_required":true}'
              : '{"ticket":"fixture-ticket"}',
        );
      }
      await request.response.close();
    });
    await gateway.connect();
    expect(routes, [
      '/auth/native/refresh',
      '/api/status',
      '/api/auth/ws-ticket',
      '/api/ws',
    ]);
    expect(gateway.link, GatewayLink.online);
  });

  test(
    'reconnect retains listeners and releases RPCs of the replaced socket',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final gateway = Gateway('127.0.0.1:${server.port}', 'fixture-token');
      final sockets = <WebSocket>[];
      final started = Completer<void>();
      addTearDown(() async {
        gateway.close();
        await server.close(force: true);
      });
      server.listen((request) async {
        if (request.uri.path == '/api/status') {
          request.response.write('{"version":"test"}');
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.add(
          jsonEncode({
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {
                'session_authority': true,
                'replay_epoch': 'epoch-${sockets.length}',
              },
            },
          }),
        );
        socket.listen((raw) {
          final json = jsonDecode(raw as String) as Json;
          if (json['method'] == 'fixture.pending') {
            started.complete();
          } else {
            socket.add(
              jsonEncode({
                'id': json['id'],
                'result': {'canonical_clarify_batch': true, 'ok': true},
              }),
            );
          }
        });
      });
      final events = <Json>[];
      final subscription = gateway.events.listen(events.add);
      addTearDown(subscription.cancel);
      await gateway.connect();
      expect(gateway.replayEpoch, 'epoch-1');
      final result = expectLater(
        gateway.call('fixture.pending', {}),
        throwsA(isA<GatewayDisconnected>()),
      );
      final back = gateway.events.firstWhere(
        (e) =>
            e['type'] == 'client.connection' && e['payload']['resumed'] == true,
      );
      await started.future;
      await sockets[0].close(1001);
      await result;
      await back.timeout(const Duration(seconds: 8));
      expect(gateway.replayEpoch, 'epoch-2');
      expect(gateway.link, GatewayLink.online);
      expect((await gateway.call('fixture.check', {}))['ok'], isTrue);
      expect(
        events.any((event) => event['payload']?['state'] == 'reconnecting'),
        isTrue,
      );

      final signIn = gateway.events.firstWhere(
        (e) => e['payload']?['state'] == 'signIn',
      );
      await sockets[1].close(4401);
      await signIn.timeout(const Duration(seconds: 4));
      await gateway.foreground();
      expect(sockets.length, 2);
      expect(gateway.closed, isFalse);
    },
  );
}
