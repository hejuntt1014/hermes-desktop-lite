import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'attachment_view.dart';
import 'followup_queue.dart'
    show
        admittedSubmissionIds,
        completedSubmissionInReplay,
        readSubmissionCursor;
import 'gateway.dart';
import 'message_content.dart' show composeAttachedPrompt, messageFence;
import 'models.dart';
import 'timeline.dart';

enum RewritePhase { rewind, submit, legacy, review }

class RewriteDraft {
  const RewriteDraft(this.caption, this.fileRefs, this.images);
  final String caption;
  final List<String> fileRefs, images;

  static RewriteDraft fromMessage(String text) {
    final files = <String>[];
    final images = <String>[];
    final caption = <String>[];
    String? fence;
    for (final line in text.split('\n')) {
      if (messageFence.firstMatch(line) case final marker?) {
        final mark = marker[1]!;
        if (fence == null) {
          fence = mark;
        } else if (mark.startsWith(fence) &&
            line.substring(marker.end).trim().isEmpty) {
          fence = null;
        }
      }
      if (fence == null && attachedPath(line) != null) {
        files.add(line);
      } else if (fence == null && line.startsWith('@image:')) {
        var path = line.substring(7).trim();
        if (path.length > 2 &&
            ['`', '"', "'"].contains(path[0]) &&
            path.endsWith(path[0])) {
          path = path.substring(1, path.length - 1);
        }
        if (path.isNotEmpty && !images.contains(path)) images.add(path);
      } else {
        caption.add(line);
      }
    }
    if (images.isNotEmpty) {
      while (caption.isNotEmpty &&
          {
            '',
            '[image]',
            '[图片]',
            '[screenshot]',
          }.contains(caption.last.trim())) {
        caption.removeLast();
      }
    }
    return RewriteDraft(caption.join('\n').trim(), files, images);
  }
}

bool rewriteTurnBoundary(ChatRow row) =>
    row.user || row.backgroundNotice != null;

bool isRetryableReply(List<ChatRow> rows, int answerIndex) {
  if (answerIndex < 0 ||
      answerIndex >= rows.length ||
      rows[answerIndex].user ||
      rows[answerIndex].archived ||
      rows[answerIndex].activity != null ||
      rows[answerIndex].backgroundNotice != null ||
      rows[answerIndex].commandReceipt != null ||
      rows[answerIndex].rowId == null) {
    return false;
  }
  for (var i = answerIndex + 1; i < rows.length; i++) {
    final row = rows[i];
    if (rewriteTurnBoundary(row)) break;
    if (row.activity == null && row.commandReceipt == null) return false;
  }
  return true;
}

int? retryPromptIndex(List<ChatRow> rows, int answerIndex) {
  if (!isRetryableReply(rows, answerIndex)) return null;
  for (var i = answerIndex - 1; i >= 0; i--) {
    if (rows[i].backgroundNotice != null) return null;
    if (rows[i].user) {
      return rows[i].rowId == null || rows[i].archived ? null : i;
    }
  }
  return null;
}

class RewriteJournal {
  RewriteJournal(this.gateway, this.profile, this.stored);
  static const _vault = FlutterSecureStorage();

  final Gateway gateway;
  final String profile, stored;
  String get _key =>
      'hermes.mobile.rewrite.v1.${base64Url.encode(utf8.encode(jsonEncode([gateway.base.toString(), profile, stored])))}';

  Future<Json?> load() async {
    final value = await _vault.read(key: _key);
    return value == null ? null : jsonDecode(value) as Json;
  }

  Future<void> _save(Json value) =>
      _vault.write(key: _key, value: jsonEncode(value));
  Future<void> clear() => _vault.delete(key: _key);

  Future<Json> prepare({
    required String caption,
    required RewriteDraft original,
    required int row,
    required bool deep,
    required ModelVersion? version,
    required String replayEpoch,
    required int replaySequence,
  }) async {
    if (await load() != null) throw GatewayError('请先处理待确认的消息');
    if (gateway.canonical && version == null) {
      throw GatewayError('网关未提供历史变更所需的会话版本');
    }
    final attachments = <Json>[];
    final imageRefs = <String>[];
    for (final path in original.images) {
      final url = path.startsWith('data:image/')
          ? path
          : (await gateway.api(
              'api/fs/read-data-url',
              query: {'path': path, 'profile': profile, 'session_id': stored},
            ))['dataUrl'];
      if (url is! String || !url.startsWith('data:image/')) {
        throw GatewayError('无法读取消息中的原图');
      }
      final name = path.startsWith('data:')
          ? 'image'
          : path.split(RegExp(r'[/\\]')).last;
      final upload = await gateway.api(
        'api/chat/image-upload',
        query: {'profile': profile},
        body: {'filename': name, 'data_url': url},
      );
      final staged = upload['path'];
      if (staged is! String ||
          staged.isEmpty ||
          staged.contains('\n') ||
          staged.contains('\r')) {
        throw GatewayError('网关未返回可用的原图地址');
      }
      attachments.add(
        gateway.canonical
            ? {
                'path': staged,
                'mime': upload['mime_type'] ?? UriData.parse(url).mimeType,
              }
            : {'data_url': url},
      );
      imageRefs.add('@image:$staged');
    }
    // Legacy requests are never replayed after an unknown outcome. Their inline image bytes
    // stay in memory; the persisted draft retains the caption and original attachment references.
    final id = const Uuid().v4();
    final text = composeAttachedPrompt(caption, original.fileRefs, imageRefs);
    final value = <String, dynamic>{
      'id': id,
      'row': row,
      'deep': deep,
      'text': text,
      'caption': caption,
      'phase':
          (gateway.canonical ? RewritePhase.rewind : RewritePhase.legacy).name,
      if (gateway.canonical) ...{
        'revision': version!.revision,
        'generation': version.generation,
        'attachments': attachments,
        'replay_epoch': replayEpoch,
        'replay_sequence': replaySequence,
      } else
        'legacy_image_count': original.images.length,
    };
    await _save(value);
    return {...value, if (!gateway.canonical) 'inline_images': attachments};
  }

  Future<bool> confirmSeen(Json snapshot, List<Json> history) async {
    final pending = await load();
    if (pending == null || pending['phase'] != RewritePhase.submit.name) {
      return false;
    }
    final id = pending['id'];
    if (id is! String) return false;
    final messages = snapshot['messages'];
    final confirmed = admittedSubmissionIds(snapshot, [
      ...history,
      if (messages is List) ...messages.whereType<Json>(),
    ]).contains(id);
    if (!confirmed &&
        await completedSubmissionInReplay(
              gateway,
              snapshot,
              profile: profile,
              stored: stored,
              id: id,
              cursor: readSubmissionCursor(pending),
            ) ==
            null) {
      return false;
    }
    if ((await load())?['id'] != id) return false;
    await clear();
    return true;
  }

  Future<void> send(String runtime, Json pending) async {
    final id = pending['id'] as String;
    var phase = RewritePhase.values.byName(pending['phase'] as String);
    if (phase == RewritePhase.review) throw GatewayError('上一次结果待确认，请先查看会话记录');
    if ((phase != RewritePhase.legacy) != gateway.canonical) {
      throw GatewayError('网关协议发生了变化，请先查看会话记录');
    }
    if (phase == RewritePhase.rewind) {
      try {
        final cut = await gateway.call('session.mutate', {
          'session_id': runtime,
          'profile': profile,
          'request_id': id,
          'operation': 'rewind',
          'expected_revision': pending['revision'],
          'expected_generation': pending['generation'],
          'payload': {'target_message_id': pending['row']},
        });
        if (cut['operation'] != 'rewind' ||
            cut['revision'] is! int ||
            cut['execution_generation'] is! int) {
          throw GatewayError('网关未确认回退结果，可继续核对');
        }
        pending = {
          ...pending,
          'phase': RewritePhase.submit.name,
          'cut_revision': cut['revision'],
          'cut_generation': cut['execution_generation'],
        };
        await _save(pending);
        phase = RewritePhase.submit;
      } on GatewayError catch (e) {
        if (e.code != null &&
            (e.code! >= 4000 && e.code! <= 4999 ||
                {-32601, -32602}.contains(e.code))) {
          await _save({...pending, 'phase': RewritePhase.review.name});
        }
        rethrow;
      }
    }

    if (phase == RewritePhase.submit) {
      final version = await gateway.mutationSnapshot(stored, profile);
      if (version?['runtime_revision'] != pending['cut_revision'] ||
          version?['runtime_generation'] != pending['cut_generation']) {
        throw GatewayError('回退后会话版本已变化，请先刷新核对发送结果');
      }

      final photos = (pending['attachments'] as List).cast<Json>();
      final result = await gateway.call('prompt.submit', {
        'session_id': runtime,
        'profile': profile,
        'submission_id': id,
        'text': pending['text'],
        if (photos.isNotEmpty) 'attachments': photos,
        if (gateway.clarifyBatch) 'clarify_batch': true,
      });
      if (result['admission_id'] is! String ||
          result['ref']?['session_id'] != runtime) {
        throw GatewayError('网关未确认发送结果，可继续核对');
      }
      await clear();
      return;
    }

    final urls = (pending['inline_images'] as List?)?.cast<Json>();
    if (((pending['legacy_image_count'] as int?) ?? 0) > 0 &&
        (urls == null || urls.isEmpty)) {
      await _save({...pending, 'phase': RewritePhase.review.name});
      throw GatewayError('请重新检查消息中的原图后再编辑');
    }
    final params = <String, dynamic>{
      'session_id': runtime,
      'profile': profile,
      'truncate_before_row_id': pending['row'],
      'confirm_truncate': true,
      'confirm_empty_truncate': true,
      if (pending['deep'] == true) 'confirm_deep_truncate': true,
      'text': urls == null || urls.isEmpty
          ? pending['text']
          : [
              {'type': 'text', 'text': pending['text']},
              for (final item in urls)
                {
                  'type': 'image_url',
                  'image_url': {'url': item['data_url']},
                },
            ],
    };
    final review = {...pending, 'phase': RewritePhase.review.name}
      ..remove('inline_images');
    await _save(review);
    Json accepted;
    try {
      accepted = await gateway.call('prompt.submit', params);
    } on GatewayError catch (e) {
      if (e.code != 4000 ||
          !e.message.contains('confirm_deep_truncate:') ||
          !params.containsKey('confirm_deep_truncate')) {
        rethrow;
      }
      params.remove('confirm_deep_truncate');
      accepted = await gateway.call('prompt.submit', params);
    }
    if (accepted['status'] != 'streaming') {
      throw GatewayError('网关未确认发送，请先检查会话记录');
    }
    await clear();
  }
}
