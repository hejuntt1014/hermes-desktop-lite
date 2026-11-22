import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/models.dart';

class ModelGateway extends Gateway {
  ModelGateway() : super('https://localhost', '') {
    canonical = true;
  }
  final requests = <Json>[];

  @override
  Future<Json> call(
    String method,
    Json params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    expect(method, 'session.mutate');
    requests.add(params);
    if (requests.length == 1) {
      throw GatewayError.rpc('revision_conflict', 4090, {
        'reason': 'revision_conflict',
        'revision': 13,
        'execution_generation': 4,
      });
    }
    if (requests.length == 2) {
      return {'status': 'confirmation_required', 'confirm': 'ticket'};
    }
    return {'model': 'beta', 'revision': 14, 'execution_generation': 4};
  }
}

void main() {
  test('model confirmation retries once on revision conflict and keeps the gateway version', () async {
    final gateway = ModelGateway();
    addTearDown(gateway.close);
    final settings = SessionModelControls(
      gateway: gateway,
      profile: 'dingding',
      stored: 'stored',
      runtime: 'runtime',
      version: (revision: 12, generation: 4),
    );
    const pick = ModelChoice('beta', 'provider');
    final preview = await settings.change(model: pick);
    expect(preview['status'], 'confirmation_required');
    expect(
      gateway.requests[0]['request_id'],
      gateway.requests[1]['request_id'],
    );
    expect(gateway.requests[1]['expected_revision'], 13);
    await settings.change(
      model: pick,
      confirmation: preview['confirm'],
      confirmed: true,
    );
    expect(gateway.requests[2]['expected_revision'], 13);
    expect(gateway.requests[2]['payload']['confirm'], 'ticket');
    expect(settings.version, (revision: 14, generation: 4));
  });
}
