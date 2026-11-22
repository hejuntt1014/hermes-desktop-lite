import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/protocol.dart';

void main() {
  test('native session parameters match both gateway protocols', () {
    expect(sessionParams(create: true, canonical: true, key: 'request'), {
      'source': 'gui',
      'request_id': 'request',
    });
    expect(sessionParams(create: true, canonical: false, key: 'request'), {
      'source': 'desktop',
      'idempotency_key': 'request',
    });
    expect(sessionParams(create: false, canonical: true, key: 'stored'), {
      'session_id': 'stored',
      'display_projection': true,
    });
    expect(sessionParams(create: false, canonical: false, key: 'stored'), {
      'session_id': 'stored',
      'source': 'desktop',
    });
  });

  test('older gateways accept image prompts without a submission ID', () {
    final gateway = Gateway('https://localhost/hermes', '');
    addTearDown(gateway.close);
    final params = gateway.promptParams(
      'run',
      'default',
      'caption',
      path: '/test.png',
      mime: 'image/png',
      dataUrl: 'data:image/png;base64,eA==',
    );
    expect(params.containsKey('submission_id'), false);
    expect(
      (params['text'] as List).last['image_url']['url'],
      'data:image/png;base64,eA==',
    );
  });
}
