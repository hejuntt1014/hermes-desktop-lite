import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'gateway.dart';

class SavedGateway {
  const SavedGateway(this.address, this.token, this.session, {bool? tokenAuth})
    : _tokenAuth = tokenAuth;
  final String address, token;
  final Json? session;
  final bool? _tokenAuth;
  bool get usesToken => _tokenAuth == true || token.isNotEmpty;
  bool get hasCredentials => usesToken ? token.isNotEmpty : session != null;
  Json toJson() => {
    'address': address,
    'token': token,
    'session': session,
    if (usesToken) 'token_auth': true,
  };
}

class GatewayBook {
  final _vault = const FlutterSecureStorage();
  static const _key = 'hermes.mobile.gateways.v1';
  List<SavedGateway> entries = [];
  Future<void> _pending = Future.value();

  Future<void> load() async {
    final raw = await _vault.read(key: _key);
    if (raw == null) return;
    entries = _unique(
      (jsonDecode(raw) as List).whereType<Json>().map(
        (item) => SavedGateway(
          item['address'] as String,
          item['token'] as String,
          item['session'] as Json?,
          tokenAuth: item['token_auth'] == true,
        ),
      ),
    );
  }

  static String _addressKey(String value) {
    try {
      return Gateway.parseAddress(value).toString();
    } on GatewayError {
      return value;
    }
  }

  static List<SavedGateway> _unique(Iterable<SavedGateway> items) {
    final keys = <String>{};
    final saved = <SavedGateway>[];
    for (final item in items) {
      final key = _addressKey(item.address);
      if (!keys.add(key)) continue;
      saved.add(
        key == item.address
            ? item
            : SavedGateway(
                key,
                item.token,
                item.session,
                tokenAuth: item.usesToken,
              ),
      );
    }
    return saved;
  }

  Future<void> _update(List<SavedGateway> Function() change) {
    final write = _pending.then((_) async {
      final next = _unique(change());
      await _vault.write(
        key: _key,
        value: jsonEncode(next.map((s) => s.toJson()).toList()),
      );
      entries = next;
    });
    _pending = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  Future<void> remember(SavedGateway entry) =>
      _update(() => [entry, ...entries]);

  Future<void> refresh(SavedGateway previous, SavedGateway entry) => _update(
    () => [
      for (final saved in entries)
        if (identical(saved, previous)) entry else saved,
    ],
  );

  Future<void> forget(String address) {
    final key = _addressKey(address);
    return _update(
      () => entries.where((s) => _addressKey(s.address) != key).toList(),
    );
  }

  Future<void> signOut(String address) {
    final key = _addressKey(address);
    return _update(
      () => [
        for (final saved in entries)
          if (_addressKey(saved.address) == key)
            SavedGateway(key, '', null, tokenAuth: saved.usesToken)
          else
            saved,
      ],
    );
  }
}
