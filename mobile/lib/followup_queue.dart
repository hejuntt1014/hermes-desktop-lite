import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'gateway.dart';
import 'slash_commands.dart' show QueuedSkill;

typedef SubmissionCursor = ({String epoch, int sequence});

SubmissionCursor? readSubmissionCursor(Json wire) {
  final epoch = wire['replay_epoch'];
  final sequence = wire['replay_sequence'];
  if (epoch is! String || epoch.isEmpty || sequence is! int || sequence < 0) {
    return null;
  }
  return (epoch: epoch, sequence: sequence);
}

class FollowupFile {
  const FollowupFile(this.name, this.index);
  final String name;
  final int index;

  Json toWire() => {'name': name, 'index': index};
  static FollowupFile fromWire(Json value) =>
      FollowupFile(value['name'] as String, value['index'] as int);
}

class FollowupDraft {
  const FollowupDraft(
    this.id,
    this.text,
    this.files,
    this.pictures,
    this.request, {
    this.accepted = false,
    this.draftStamp,
    this.skill,
    this.display,
    this.composerInputs = const [],
    this.uploadPaused = false,
    this.cursor,
  });
  final String id, text;
  final List<FollowupFile> files;
  final List<FollowupFile> pictures;
  final Json? request;
  final bool accepted;
  final bool uploadPaused;
  final String? draftStamp, display;
  final QueuedSkill? skill;
  final List<String> composerInputs;
  final SubmissionCursor? cursor;
  int get attachmentCount => files.length + pictures.length;

  FollowupDraft staged(
    Json request,
    String? display,
    SubmissionCursor? cursor,
  ) => FollowupDraft(
    id,
    text,
    files,
    pictures,
    request,
    accepted: accepted,
    draftStamp: draftStamp,
    skill: skill,
    composerInputs: composerInputs,
    display: display,
    cursor: cursor,
  );

  FollowupDraft withUploadPaused(bool paused) => FollowupDraft(
    id,
    text,
    files,
    pictures,
    request,
    accepted: accepted,
    draftStamp: draftStamp,
    skill: skill,
    display: display,
    composerInputs: composerInputs,
    uploadPaused: paused,
    cursor: cursor,
  );

  Json toWire() => {
    'id': id,
    'text': text,
    'files': files.map((file) => file.toWire()).toList(),
    if (pictures.isNotEmpty)
      'pictures': pictures.map((file) => file.toWire()).toList(),
    'request': ?request,
    if (accepted) 'accepted': true,
    if (uploadPaused) 'upload_paused': true,
    'draft_stamp': ?draftStamp,
    'skill': ?skill?.toWire(),
    'display': ?display,
    if (cursor case final position?) ...{
      'replay_epoch': position.epoch,
      'replay_sequence': position.sequence,
    },
    if (composerInputs.any((id) => id.isNotEmpty))
      'composer_inputs': composerInputs,
  };

  static FollowupDraft? fromWire(Json value) {
    final id = value['id'];
    if (id is! String || !_uuid.hasMatch(id)) return null;
    return FollowupDraft(
      id,
      value['text'] as String,
      (value['files'] as List)
          .whereType<Json>()
          .map(FollowupFile.fromWire)
          .toList(),
      switch (value['pictures']) {
        final List photos =>
          photos.whereType<Json>().map(FollowupFile.fromWire).toList(),
        _ => [
          if (value['picture'] case final Json photo)
            FollowupFile.fromWire(photo),
        ],
      },
      value['request'] as Json?,
      accepted: value['accepted'] == true,
      uploadPaused: value['upload_paused'] == true,
      draftStamp: value['draft_stamp'] as String?,
      skill: value['skill'] is Json
          ? QueuedSkill.fromWire(value['skill'] as Json)
          : null,
      display: value['display'] as String?,
      cursor: readSubmissionCursor(value),
      composerInputs: value['composer_inputs'] is List
          ? [
              for (final input in value['composer_inputs'] as List)
                input is String ? input : '',
            ]
          : const [],
    );
  }
}

Set<String> admittedSubmissionIds(Json snapshot, Iterable<Json> history) {
  final pending = snapshot['pending'];
  final active = snapshot['inflight'];
  final turn = snapshot['persisted_turn'];
  return {
    for (final row in [
      ...history,
      if (pending is List) ...pending.whereType<Json>(),
      if (active is Json) active,
      if (turn is Json) turn,
      snapshot,
    ])
      for (final field in ['input_id', 'submission_id', 'admission_id'])
        if (row[field] case final String id when id.isNotEmpty) id,
  };
}

Future<Json?> completedSubmissionInReplay(
  Gateway gateway,
  Json snapshot, {
  required String profile,
  required String stored,
  required String id,
  SubmissionCursor? cursor,
}) async {
  final runtime = snapshot['session_id'];
  final epoch = snapshot['replay_epoch'] ?? gateway.replayEpoch;
  if (!gateway.canonical ||
      runtime is! String ||
      (snapshot['stored_session_id'] ?? runtime) != stored ||
      epoch is! String ||
      epoch.isEmpty) {
    return null;
  }
  try {
    // History rows can omit the submission ID even after the reply is saved.
    final replay = await gateway.call('session.events.since', {
      'session_id': runtime,
      'profile': profile,
      'replay_epoch': epoch,
      'last_seen': cursor?.epoch == epoch ? cursor!.sequence : 0,
    }, timeout: const Duration(seconds: 5));
    final events = replay['events'];
    if (replay['snapshot_required'] == true ||
        replay['truncated'] == true ||
        events is! List) {
      return null;
    }
    for (final event in events.whereType<Json>()) {
      if (event['type'] != 'message.complete' ||
          event['session_id'] != runtime) {
        continue;
      }
      final payload = event['payload'];
      if (payload is Json &&
          admittedSubmissionIds(payload, const []).contains(id)) {
        return payload;
      }
    }
    return null;
  } on GatewayError {
    return null;
  } on TimeoutException {
    return null;
  }
}

final _uuid = RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$');

class FollowupQueue {
  FollowupQueue(
    Gateway gateway,
    String profile,
    String session, {
    Future<Directory> Function()? storageRoot,
  }) : this._(gateway, profile, session, 'followups', storageRoot);

  FollowupQueue.submissions(Gateway gateway, String profile, String session)
    : this._(gateway, profile, session, 'submissions', null);

  FollowupQueue._(
    Gateway gateway,
    String profile,
    String session,
    this._kind,
    Future<Directory> Function()? storageRoot,
  ) : _scope = sha256
          .convert(
            utf8.encode(
              jsonEncode([gateway.base.toString(), profile, session]),
            ),
          )
          .toString(),
      _root = storageRoot ?? getApplicationSupportDirectory;

  static const _vault = FlutterSecureStorage();
  static final _writes = <String, Future<void>>{};
  static final _drains = <String, Future<void>>{};
  final String _scope, _kind;
  final Future<Directory> Function() _root;
  String get _key => 'hermes.mobile.$_kind.v1.$_scope';
  Future<void>? get currentDrain => _drains[_key];

  Future<List<FollowupDraft>> read() async {
    await _writes[_key];
    return _read();
  }

  Future<List<FollowupDraft>> _read() async {
    final stored = await _vault.read(key: _key);
    if (stored == null) return [];
    return (jsonDecode(stored) as List)
        .whereType<Json>()
        .map(FollowupDraft.fromWire)
        .nonNulls
        .toList();
  }

  Future<List<FollowupDraft>> _update(
    void Function(List<FollowupDraft>) change,
  ) {
    final result = (_writes[_key] ?? Future<void>.value()).then((_) async {
      final queue = await _read();
      change(queue);
      if (queue.isEmpty) {
        await _vault.delete(key: _key);
      } else {
        await _vault.write(
          key: _key,
          value: jsonEncode(queue.map((item) => item.toWire()).toList()),
        );
      }
      return queue;
    });
    final settled = result.then<void>((_) {}, onError: (Object _) {});
    _writes[_key] = settled;
    unawaited(
      settled.whenComplete(() {
        if (identical(_writes[_key], settled)) _writes.remove(_key);
      }),
    );
    return result;
  }

  Future<void> drainOnce(Future<void> Function() run) async {
    final prior = _drains[_key];
    if (prior != null) {
      await prior;
      return;
    }
    final flight = Completer<void>();
    _drains[_key] = flight.future;
    try {
      await run();
    } finally {
      _drains.remove(_key);
      flight.complete();
    }
  }

  Future<Directory> _folder(String id) async {
    if (!_uuid.hasMatch(id)) throw GatewayError('待发送消息的文件位置无效');
    final root = await _root();
    return Directory('${root.path}/$_kind/$_scope/$id');
  }

  Future<List<FollowupDraft>> add(
    String text,
    List<XFile> files,
    XFile? picture, {
    List<XFile> pictures = const [],
    String? draftStamp,
    QueuedSkill? skill,
    List<String> composerInputs = const [],
  }) async {
    final id = const Uuid().v4();
    Directory? folder;
    try {
      final copies = <FollowupFile>[];
      final photos = <FollowupFile>[];
      final images = [?picture, ...pictures];
      if (files.isNotEmpty || images.isNotEmpty) {
        folder = await (await _folder(id)).create(recursive: true);
        for (final file in files) {
          final index = copies.length;
          await file.saveTo('${folder.path}/$index');
          copies.add(FollowupFile(attachmentName(file), index));
        }
        for (final image in images) {
          final index = copies.length + photos.length;
          await image.saveTo('${folder.path}/$index');
          photos.add(FollowupFile(attachmentName(image), index));
        }
      }
      return await _update((items) {
        if (_kind == 'submissions') {
          if (items.any((entry) => !entry.accepted)) {
            throw GatewayError('已有一条发送结果待确认的消息');
          }
          items.clear();
        }
        items.add(
          FollowupDraft(
            id,
            text,
            copies,
            photos,
            null,
            draftStamp: draftStamp,
            skill: skill,
            composerInputs: composerInputs,
          ),
        );
      });
    } catch (_) {
      if (folder != null && await folder.exists()) {
        await folder.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<XFile> source(String id, FollowupFile file) async {
    final folder = await _folder(id);
    final path = '${folder.path}/${file.index}';
    if (!await File(path).exists()) throw GatewayError('待发送附件已无法读取');
    return _FollowupXFile(path, file.name);
  }

  Future<void> markSubmitted(FollowupDraft draft) async {
    await _update((items) {
      final index = items.indexWhere((item) => item.id == draft.id);
      if (index < 0 || items[index].accepted) return;
      items[index] = FollowupDraft(
        draft.id,
        draft.text,
        const [],
        const [],
        null,
        accepted: true,
        draftStamp: draft.draftStamp,
        composerInputs: draft.composerInputs,
      );
    });
    if (draft.attachmentCount == 0) return;
    final folder = await _folder(draft.id);
    if (await folder.exists()) await folder.delete(recursive: true);
  }

  Future<({List<XFile> files, List<XFile> pictures})> copyToEditor(
    FollowupDraft draft,
  ) async {
    if (draft.attachmentCount == 0) {
      return (files: const <XFile>[], pictures: const <XFile>[]);
    }
    final directory = await Directory.systemTemp.createTemp(
      'hermes-retained-draft-',
    );
    try {
      Future<XFile> copy(FollowupFile original) async {
        final input = await source(draft.id, original);
        final path = '${directory.path}/${original.index}';
        await input.saveTo(path);
        return _FollowupXFile(path, original.name);
      }

      return (
        files: await Future.wait(draft.files.map(copy)),
        pictures: await Future.wait(draft.pictures.map(copy)),
      );
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<List<FollowupDraft>> edit(
    String id,
    String text, {
    QueuedSkill? skill,
  }) => _update((items) {
    final i = items.indexWhere((item) => item.id == id && item.request == null);
    if (i < 0) throw GatewayError('这条消息已进入发送流程');
    final old = items[i];
    items[i] = FollowupDraft(
      old.id,
      text,
      old.files,
      old.pictures,
      null,
      draftStamp: old.draftStamp,
      skill: skill,
      composerInputs: old.composerInputs,
      uploadPaused: old.uploadPaused,
    );
  });

  Future<List<FollowupDraft>> setUploadPaused(String id, bool paused) =>
      _update((items) {
        final index = items.indexWhere(
          (item) => item.id == id && item.request == null,
        );
        if (index >= 0) items[index] = items[index].withUploadPaused(paused);
      });

  Future<List<FollowupDraft>> stage(
    FollowupDraft expected,
    Json request, {
    String? display,
    SubmissionCursor? cursor,
  }) => _update((items) {
    final i = items.indexWhere(
      (item) =>
          item.id == expected.id &&
          item.text == expected.text &&
          item.request == null &&
          !item.uploadPaused,
    );
    if (i < 0) throw GatewayError('这条待发送消息已处理');
    items[i] = items[i].staged(request, display, cursor);
  });

  Future<List<FollowupDraft>> unstage(String id) => _update((items) {
    final i = items.indexWhere((item) => item.id == id && item.request != null);
    if (i < 0) return;
    final item = items[i];
    items[i] = FollowupDraft(
      item.id,
      item.text,
      item.files,
      item.pictures,
      null,
      draftStamp: item.draftStamp,
      skill: item.skill,
      composerInputs: item.composerInputs,
    );
  });

  Future<List<FollowupDraft>> remove(
    String id, {
    bool allowStaged = false,
  }) async {
    FollowupDraft? removed;
    final queue = await _update((items) {
      final i = items.indexWhere((item) => item.id == id);
      if (i < 0) return;
      if (!allowStaged && items[i].request != null) {
        throw GatewayError('请先核对这条消息的发送结果');
      }
      removed = items.removeAt(i);
    });
    if (removed case final item? when item.attachmentCount > 0) {
      final folder = await _folder(item.id);
      if (await folder.exists()) {
        await folder.delete(recursive: true).catchError((_) => folder);
      }
    }
    return queue;
  }
}

class _FollowupXFile extends XFile {
  _FollowupXFile(super.path, this.name);
  @override
  final String name;
}

class RemoteFollowup {
  RemoteFollowup(Json value)
    : id = value['admission_id'] as String? ?? '',
      text = value['text'] as String? ?? '',
      sequence = value['sequence'] as int? ?? 0,
      canReplace =
          value['controls'] is List &&
          (value['controls'] as List).contains('replace');

  static List<RemoteFollowup>? parse(Object? pending) => pending is! List
      ? null
      : (pending
            .whereType<Json>()
            .where((row) => row['status'] == 'queued')
            .map(RemoteFollowup.new)
            .where((row) => row.id.isNotEmpty)
            .toList()
          ..sort((a, b) => a.sequence.compareTo(b.sequence)));

  final String id, text;
  final int sequence;
  final bool canReplace;
}
