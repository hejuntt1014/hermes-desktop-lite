import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway.dart';

// Drive the gateway's real password form and loopback callback without an interactive browser.
class PasswordGateway extends Gateway {
  PasswordGateway(String address) : super(address, '');
  @override
  Future<bool> openLoginPage(Uri uri) async {
    final http = HttpClient();
    try {
      final auth = await http.getUrl(
        uri.replace(
          queryParameters: {...uri.queryParameters, 'provider': 'basic'},
        ),
      );
      auth.followRedirects = false;
      final begin = await auth.close();
      expect(begin.statusCode, 302);
      final cookies = begin.cookies;
      await begin.drain<void>();
      final login = await http.postUrl(base.resolve('auth/password-login'));
      login.followRedirects = false;
      login.cookies.addAll(cookies);
      login.headers.contentType = ContentType.json;
      login.headers.set('Origin', base.origin);
      login.write(
        jsonEncode({
          'provider': 'basic',
          'username': Platform.environment['QA_USERNAME'],
          'password': Platform.environment['QA_PASSWORD'],
        }),
      );
      final res = await login.close();
      expect(res.statusCode, 200);
      final data = jsonDecode(await res.transform(utf8.decoder).join()) as Json;
      final next = Uri.parse(data['next'] as String);
      final callback = Uri.parse(uri.queryParameters['redirect_uri']!);
      if (next.origin != callback.origin || next.path != callback.path) {
        throw StateError('Unexpected callback');
      }
      final result = await (await http.getUrl(next)).close();
      await result.drain<void>();
      return result.statusCode == 200;
    } finally {
      http.close(force: true);
    }
  }
}

void main() {
  test('authenticated profiles, session, image upload, streamed reply, image readback and resume', () async {
    final gateway = PasswordGateway(Platform.environment['QA_GATEWAY']!);
    addTearDown(gateway.close);
    await gateway.connect();
    final profiles = await gateway.api('api/profiles');
    final names = (profiles['profiles'] as List)
        .map((p) => p['name'])
        .whereType<String>()
        .toList();
    expect(names, isNotEmpty);
    final profile = names.contains('default') ? 'default' : names.first;
    for (final p in names.take(2)) {
      final list = await gateway.api(
        'api/sessions',
        query: {'profile': p, 'limit': '2'},
      );
      for (final row in list['sessions'] as List) {
        expect(row['profile'] ?? p, p);
      }
    }
    final snap = await gateway.openSession(profile, null);
    final sid = snap['session_id'] as String;
    final stored = (snap['stored_session_id'] ?? sid) as String;
    const data =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGNQzk0lCTGMahjVMHw1AAD++vUBLaREPQAAAABJRU5ErkJggg==';
    final uploaded = await gateway.api(
      'api/chat/image-upload',
      query: {'profile': profile},
      body: {'filename': 'mobile-smoke.png', 'data_url': data},
    );
    final path = uploaded['path'] as String;
    final wanted = 'MEDIA:$path';
    final text = '@image:$path\n移动端图片收发验收。请仅原样回复下一行，不加代码块。\n$wanted';
    final events = <Json>[];
    final completion = gateway.events
        .where((e) => e['session_id'] == sid || e['session_id'] == stored)
        .map((e) {
          events.add(e);
          return e;
        })
        .firstWhere((e) => e['type'] == 'message.complete')
        .timeout(const Duration(minutes: 3));
    final params = gateway.promptParams(
      sid,
      profile,
      text,
      path: path,
      mime: uploaded['mime_type'],
      dataUrl: data,
    );
    await gateway.call('prompt.submit', params);
    final done = await completion;
    expect(events.any((e) => e['type'] == 'message.delta'), true);
    expect(done['payload']['text'].toString().contains(wanted), true);
    final picture = await gateway.api(
      'api/fs/read-data-url',
      query: {'session_id': stored, 'profile': profile, 'path': path},
    );
    expect(picture['dataUrl'] == data, true);
    final resumed = await gateway.openSession(profile, stored);
    expect(
      (resumed['display_messages'] ?? resumed['messages'] as List).isNotEmpty,
      true,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
