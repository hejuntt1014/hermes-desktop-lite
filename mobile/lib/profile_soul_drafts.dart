import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'gateway.dart';
import 'profiles.dart';

typedef ProfileSoulDraft = ({
  SoulSnapshot baseline,
  String text,
  bool conflict,
});

class ProfileSoulDraftStore {
  factory ProfileSoulDraftStore(Gateway gateway, String profile) {
    final scope = jsonEncode([gateway.base.toString(), profile]);
    final key =
        'hermes.mobile.soul-draft.v1.${sha256.convert(utf8.encode(scope))}';
    return _scopes.putIfAbsent(key, () => ProfileSoulDraftStore._(key));
  }

  ProfileSoulDraftStore._(this._key);

  static const _storage = FlutterSecureStorage();
  static final _scopes = <String, ProfileSoulDraftStore>{};
  final String _key;
  ProfileSoulDraft? _draft;
  bool _loaded = false, _dirty = false;
  Future<void> _pending = Future.value();

  ProfileSoulDraft? get draft => _draft;

  Future<ProfileSoulDraft?> read() async {
    if (_loaded) return _draft;
    final raw = await _storage.read(key: _key);
    if (_loaded) return _draft;
    final data = raw == null ? null : jsonDecode(raw);
    if (data is Json) {
      final original = data['original'];
      final exists = data['exists'];
      final text = data['text'];
      if (original is String && exists is bool && text is String) {
        _draft = (
          baseline: (content: original, exists: exists),
          text: text,
          conflict: data['conflict'] == true,
        );
      }
    }
    _loaded = true;
    return _draft;
  }

  void stage(ProfileSoulDraft? draft) {
    if (_draft == draft) return;
    _draft = draft;
    _loaded = true;
    _dirty = true;
  }

  Future<void> flush() {
    if (!_dirty) return _pending;
    _dirty = false;
    final value = _draft;
    final write = _pending.then((_) async {
      if (value == null) {
        await _storage.delete(key: _key);
      } else {
        await _storage.write(
          key: _key,
          value: jsonEncode({
            'original': value.baseline.content,
            'exists': value.baseline.exists,
            'text': value.text,
            'conflict': value.conflict,
          }),
        );
      }
    });
    _pending = write.then<void>(
      (_) {},
      onError: (Object _) {
        if (_draft == value) _dirty = true;
      },
    );
    return write;
  }
}
