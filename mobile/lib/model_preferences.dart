import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'gateway.dart';
import 'models.dart';

typedef ModelPreference = ({bool favorite, String? effort, String? speed});
const ModelPreference noModelPreference = (
  favorite: false,
  effort: null,
  speed: null,
);

class ModelPreferences {
  ModelPreferences(Gateway gateway, String profile)
    : _key =
          'hermes.mobile.models.v1.${base64Url.encode(utf8.encode(jsonEncode([gateway.base.toString(), profile])))}';

  static const _vault = FlutterSecureStorage();
  static final _writes = <String, Future<void>>{};
  final String _key;

  static String keyFor(ModelChoice model) =>
      jsonEncode([model.provider, model.id]);

  Future<Map<String, ModelPreference>> _read() async {
    final raw = await _vault.read(key: _key);
    if (raw == null) return {};
    final data = jsonDecode(raw);
    if (data is! Json) return {};
    return {
      for (final entry in data.entries)
        if (entry.value case final Json row)
          entry.key: (
            favorite: row['favorite'] == true,
            effort: effortLabels.containsKey(row['effort'])
                ? row['effort'] as String
                : null,
            speed: speedLabels.containsKey(row['speed'])
                ? row['speed'] as String
                : null,
          ),
    };
  }

  Future<Map<String, ModelPreference>> read() async {
    await _writes[_key];
    return _read();
  }

  Future<ModelPreference> update(
    ModelChoice model,
    ModelPreference Function(ModelPreference) change,
  ) {
    final pending = (_writes[_key] ?? Future<void>.value()).then((_) async {
      final items = await _read();
      final id = keyFor(model);
      final next = change(items[id] ?? noModelPreference);
      if (next == noModelPreference) {
        items.remove(id);
      } else {
        items[id] = next;
      }
      await _vault.write(
        key: _key,
        value: jsonEncode({
          for (final item in items.entries)
            item.key: {
              'favorite': item.value.favorite,
              'effort': ?item.value.effort,
              'speed': ?item.value.speed,
            },
        }),
      );
      return next;
    });
    final settled = pending.then<void>((_) {}, onError: (Object _) {});
    _writes[_key] = settled;
    settled.whenComplete(() {
      if (identical(_writes[_key], settled)) _writes.remove(_key);
    });
    return pending;
  }
}
