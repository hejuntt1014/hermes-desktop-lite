import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'composer_attachments.dart';
import 'gateway.dart';

typedef PhotoDraftTarget = ({String gateway, String profile, String tab});

PhotoDraftTarget? _targetFromWire(Json wire) {
  final gateway = wire['gateway'];
  final profile = wire['profile'];
  final tab = wire['tab'];
  if (gateway is! String ||
      gateway.isEmpty ||
      profile is! String ||
      profile.isEmpty ||
      tab is! String ||
      tab.isEmpty) {
    return null;
  }
  return (gateway: gateway, profile: profile, tab: tab);
}

Json _targetToWire(PhotoDraftTarget scope) => {
  'gateway': scope.gateway,
  'profile': scope.profile,
  'tab': scope.tab,
};

class PickedDraftPhotos {
  const PickedDraftPhotos(this.id, this.target, this.attachments);
  final String id;
  final PhotoDraftTarget target;
  final List<ComposerAttachment> attachments;

  Json toWire() => {
    ..._targetToWire(target),
    'id': id,
    'attachments': attachments.map((entry) => entry.toWire()).toList(),
  };

  static PickedDraftPhotos? fromWire(Json wire) {
    final id = wire['id'];
    final target = _targetFromWire(wire);
    final attachments = wire['attachments'];
    if (id is! String || target == null || attachments is! List) return null;
    return PickedDraftPhotos(
      id,
      target,
      attachments
          .whereType<Json>()
          .map(ComposerAttachment.fromWire)
          .nonNulls
          .toList(growable: false),
    );
  }
}

class AndroidDraftPhotos {
  static final shared = AndroidDraftPhotos();
  static const _storage = FlutterSecureStorage();
  static const _launchKey = 'hermes.mobile.photos.launch.v1';
  static const _resultsKey = 'hermes.mobile.photos.results.v1';
  Future<void>? _startup;
  Future<void> _writing = Future<void>.value();
  List<PickedDraftPhotos> _results = [];
  bool _picking = false;

  Future<void> start() async {
    if (!Platform.isAndroid) return;
    final startup = _startup ??= _restoreStartup();
    try {
      await startup;
    } catch (_) {
      if (identical(_startup, startup)) _startup = null;
      rethrow;
    }
  }

  Future<void> _restoreStartup() async {
    final saved = await _storage.read(key: _resultsKey);
    final entries = saved == null ? null : jsonDecode(saved);
    if (entries is List) {
      _results = entries
          .whereType<Json>()
          .map(PickedDraftPhotos.fromWire)
          .nonNulls
          .toList();
    }
    final launching = await _storage.read(key: _launchKey);
    final lost = await ImagePicker().retrieveLostData();
    if (launching == null) return;
    final launch = jsonDecode(launching);
    try {
      final photos = lost.files;
      if (launch is Json &&
          photos != null &&
          !_results.any((result) => result.id == launch['id'])) {
        await _saveSelection(launch, photos);
      }
    } finally {
      await _storage.delete(key: _launchKey);
    }
  }

  Future<List<PickedDraftPhotos>> forDraft(PhotoDraftTarget target) async {
    if (!Platform.isAndroid) return const [];
    await start();
    await _writing;
    return _results.where((result) => result.target == target).toList();
  }

  Future<PickedDraftPhotos?> pick(
    PhotoDraftTarget target,
    int limit,
    Future<List<XFile>> Function() launchPicker,
  ) async {
    if (_picking) return null;
    _picking = true;
    final launch = <String, dynamic>{
      ..._targetToWire(target),
      'id': const Uuid().v4(),
      'fileIds': List.generate(limit, (_) => const Uuid().v4()),
    };
    try {
      await start();
      await _storage.write(key: _launchKey, value: jsonEncode(launch));
      try {
        return await _saveSelection(launch, await launchPicker());
      } finally {
        await _storage.delete(key: _launchKey);
      }
    } finally {
      _picking = false;
    }
  }

  Future<PickedDraftPhotos?> _saveSelection(
    Json launch,
    List<XFile> photos,
  ) async {
    final target = _targetFromWire(launch);
    final id = launch['id'];
    final fileIds = launch['fileIds'];
    if (target == null || id is! String || fileIds is! List || photos.isEmpty) {
      return null;
    }
    if (photos.length > fileIds.length) {
      throw GatewayError('一次最多发送 10 张图片');
    }
    final store = ComposerAttachmentStore.forDraft(
      target.gateway,
      target.profile,
      target.tab,
    );
    final staged = <ComposerAttachment>[];
    try {
      for (final (index, photo) in photos.indexed) {
        final copy = await store.import(
          photo,
          photo: await isComposerPhoto(photo),
          originalId: fileIds[index] as String?,
        );
        staged.add(copy.attachment);
      }
      final result = PickedDraftPhotos(id, target, staged);
      await _update(
        (existing) => [...existing.where((batch) => batch.id != id), result],
      );
      return result;
    } catch (_) {
      await store.remove(staged);
      rethrow;
    }
  }

  Future<void> acknowledge(Iterable<PickedDraftPhotos> attached) {
    final ids = attached.map((entry) => entry.id).toSet();
    if (ids.isEmpty) return Future<void>.value();
    return _update(
      (existing) => existing.where((entry) => !ids.contains(entry.id)).toList(),
    );
  }

  Future<void> _update(
    List<PickedDraftPhotos> Function(List<PickedDraftPhotos>) transform,
  ) {
    final write = _writing.then((_) async {
      final next = transform(_results);
      await _storage.write(
        key: _resultsKey,
        value: jsonEncode(next.map((entry) => entry.toWire()).toList()),
      );
      _results = next;
    });
    _writing = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }
}
