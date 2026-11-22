import 'package:uuid/uuid.dart';

import 'gateway.dart';
import 'history.dart';
import 'message_content.dart';

typedef _BranchKey = ({String profile, String parent, int? through});
typedef _BranchRequest = ({String method, Json params});
final _plans = Expando<Map<_BranchKey, _BranchRequest>>('branch plans');

Future<Json> branchConversation(
  Gateway gateway, {
  required String profile,
  required String parent,
  required String title,
  String? runtime,
  int? through,
}) async {
  final key = (profile: profile, parent: parent, through: through);
  final plans = _plans[gateway] ??= {};
  final plan = plans[key] ??= await _prepareBranch(gateway, key, runtime);
  final params = {
    ...plan.params,
    if (plan.method == 'session.branch' && runtime != null)
      'session_id': runtime,
  };
  final Json result;
  try {
    result = await gateway.call(plan.method, params);
  } on GatewayError catch (e) {
    final reason = e.data?['reason'] ?? e.message;
    if ({-32601, -32602, 4008, 4018}.contains(e.code) ||
        {
          'revision_conflict',
          'stale_generation',
          'session_busy',
          'invalid_params',
          'not_found',
          'permission_denied',
          'profile_mismatch',
          'admission_conflict',
        }.contains(reason)) {
      plans.remove(key);
    }
    rethrow;
  }
  final id = plan.method == 'session.mutate'
      ? result['branched_session_id']
      : result['stored_session_id'] ?? result['session_id'];
  if (id is! String || id.isEmpty || id == parent) {
    throw GatewayError('网关未确认分叉结果，可重试同一次请求');
  }
  plans.remove(key);
  return {
    'id': id,
    'profile': profile,
    '_branched_from': parent,
    'title': result['title'] ?? '$title · 分叉',
  };
}

Future<_BranchRequest> _prepareBranch(
  Gateway gateway,
  _BranchKey key,
  String? runtime,
) async {
  final request = const Uuid().v4();
  final through = key.through;
  if (gateway.canonical) {
    final snapshot = await gateway.mutationSnapshot(key.parent, key.profile);
    if (snapshot == null) throw GatewayError('网关未提供分叉所需的会话版本');
    return (
      method: 'session.mutate',
      params: {
        'session_id': key.parent,
        'profile': key.profile,
        'request_id': request,
        'expected_revision': snapshot['runtime_revision'],
        'expected_generation': snapshot['runtime_generation'],
        'operation': 'branch',
        'payload': {'through_message_id': ?through},
      },
    );
  }
  if (through != null) {
    if (runtime == null) throw GatewayError('请等待会话连接后再分叉');
    final count = await _countThrough(
      gateway,
      key.profile,
      key.parent,
      through,
    );
    return (
      method: 'session.branch',
      params: {
        'session_id': runtime,
        'profile': key.profile,
        'count': count,
        'idempotency_key': request,
      },
    );
  }
  return (
    method: 'session.branch_stored',
    params: {
      'parent_session_id': key.parent,
      'profile': key.profile,
      'source': 'desktop',
      'idempotency_key': request,
    },
  );
}

Future<int> _countThrough(
  Gateway gateway,
  String profile,
  String parent,
  int target,
) async {
  final path = 'api/sessions/${Uri.encodeComponent(parent)}/messages';
  Json? boundary;
  var offset = 0, count = 0;
  while (true) {
    final page = await gateway.api(
      path,
      query: {
        'profile': profile,
        'offset': '$offset',
        'limit': '250',
        'order': 'oldest',
        'include_compacted': 'true',
        'inline_images': 'false',
      },
    );
    final pagination = page['pagination'];
    final data = page['messages'];
    if ((page['session_id'] ?? parent) != parent ||
        page['profile'] != null && page['profile'] != profile ||
        pagination is! Json ||
        pagination['offset'] != offset ||
        data is! List) {
      throw GatewayError('会话历史已发生变化，请刷新后重试');
    }
    final records = data.cast<Json>();
    if (boundary != null &&
        (records.isEmpty || !sameHistoryRow(records.first, boundary))) {
      throw GatewayError('会话历史已发生变化，请刷新后重试');
    }
    for (final row in records.skip(boundary == null ? 0 : 1)) {
      final role = row['role'];
      if (role != 'user' && role != 'assistant' ||
          !_hasContent(row['content'])) {
        continue;
      }
      count++;
      if (role == 'assistant' && historyRowId(row) == target) return count;
    }
    final limit = pagination['limit'];
    if (limit is! int || records.length < 2 || records.length < limit) break;
    boundary = records.last;
    offset += records.length - 1;
  }
  throw GatewayError('找不到要分叉的回复，请刷新后重试');
}

bool _hasContent(dynamic content) {
  if (content is List) return content.any(_hasContent);
  if (content is Json) {
    final text = content['text'];
    if (text is String) return text.trim().isNotEmpty;
    if ({'text', 'input_text', 'output_text'}.contains(content['type'])) {
      return (content['content']?.toString() ?? '').trim().isNotEmpty;
    }
    return content['type'] is String || content.isNotEmpty;
  }
  return messageBody(content).trim().isNotEmpty;
}
