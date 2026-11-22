import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'gateway.dart';
import 'image_format.dart';

const composerPhotoLimit = 10;

Future<bool> isComposerPhoto(XFile file) async {
  final size = await file.length();
  if (size == 0) return false;
  final header = await file.openRead(0, size < 12 ? size : 12).fold<List<int>>(
    [],
    (bytes, chunk) {
      bytes.addAll(chunk);
      return bytes;
    },
  );
  return detectImageMime(header) != null;
}

final _uuid = RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$');

class ComposerAttachment {
  const ComposerAttachment._(this.id, this.name, this.photo);

  final String id, name;
  final bool photo;

  Json toWire() => {'id': id, 'name': name, if (photo) 'photo': true};

  static ComposerAttachment? fromWire(Json wire) {
    final id = wire['id'];
    final name = wire['name'];
    if (id is! String ||
        !_uuid.hasMatch(id) ||
        name is! String ||
        name.isEmpty) {
      return null;
    }
    return ComposerAttachment._(id, name, wire['photo'] == true);
  }
}

class ComposerFile extends XFile {
  ComposerFile(super.path, this.attachment);

  final ComposerAttachment attachment;

  @override
  String get name => attachment.name;
}

class ComposerAttachmentStore {
  ComposerAttachmentStore(Gateway gateway, String profile, String tab)
    : this.forDraft(gateway.base.toString(), profile, tab);

  ComposerAttachmentStore.forDraft(String gateway, String profile, String tab)
    : _scope = sha256
          .convert(utf8.encode(jsonEncode([gateway, profile, tab])))
          .toString();

  final String _scope;
  late final Future<Directory> _folder = getApplicationSupportDirectory().then(
    (root) => Directory('${root.path}/composer-attachments/$_scope'),
  );

  Future<ComposerFile> source(ComposerAttachment attachment) async =>
      ComposerFile('${(await _folder).path}/${attachment.id}', attachment);

  Future<ComposerFile> import(
    XFile input, {
    required bool photo,
    String? originalId,
  }) async {
    final reference = ComposerAttachment._(
      originalId != null && _uuid.hasMatch(originalId)
          ? originalId
          : const Uuid().v4(),
      attachmentName(input),
      photo,
    );
    final folder = await _folder;
    await folder.create(recursive: true);
    final file = await source(reference);
    final partial = File('${file.path}.part');
    try {
      await input.saveTo(partial.path);
      await partial.rename(file.path);
      return file;
    } finally {
      if (await partial.exists()) {
        await partial.delete().catchError((Object _) => partial);
      }
    }
  }

  Future<void> remove(Iterable<ComposerAttachment> attachments) async {
    if (attachments.isEmpty) return;
    final folder = await _folder;
    for (final attachment in attachments) {
      final file = File('${folder.path}/${attachment.id}');
      if (await file.exists()) {
        await file.delete().catchError((Object _) => file);
      }
    }
  }
}
