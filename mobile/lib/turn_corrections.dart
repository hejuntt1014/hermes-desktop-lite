import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'gateway.dart';

typedef TurnCorrectionScope = ({String runtime, String epoch, int generation});
typedef ConfirmedCorrection = ({
  String id,
  int sequence,
  String text,
  String precedingReply,
});
typedef TurnCorrectionRecord = ({
  TurnCorrectionScope scope,
  List<ConfirmedCorrection> entries,
});

class TurnCorrections {
  TurnCorrections(Gateway gateway, String profile, String session)
    : _key =
          'hermes.mobile.corrections.v1.${base64Url.encode(utf8.encode(jsonEncode([gateway.base.toString(), profile, session])))}';

  final String _key;
  static const _storage = FlutterSecureStorage();
  static final _pending = <String, Future<void>>{};

  Future<TurnCorrectionRecord?> read() async {
    await _pending[_key];
    return _read();
  }

  Future<TurnCorrectionRecord?> _read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    final Object? wire;
    try {
      wire = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (wire
        case {
          'runtime': final String runtime,
          'epoch': final String epoch,
          'generation': final int generation,
          'entries': final List entries,
        }
        when runtime.isNotEmpty && epoch.isNotEmpty && generation >= 0) {
      return (
        scope: (runtime: runtime, epoch: epoch, generation: generation),
        entries: [
          for (final entry in entries)
            if (entry
                case {
                  'id': final String id,
                  'sequence': final int sequence,
                  'text': final String text,
                }
                when id.isNotEmpty && sequence >= 0 && text.isNotEmpty)
              (id: id, sequence: sequence, text: text, precedingReply: ''),
        ],
      );
    }
    return null;
  }

  Future<void> append(
    TurnCorrectionScope scope,
    ConfirmedCorrection correction,
  ) => _serialize(() async {
    final saved = await _read();
    final entries = [if (saved?.scope == scope) ...saved!.entries];
    if (entries.any((entry) => entry.id == correction.id)) return;
    entries.add(correction);
    await _storage.write(
      key: _key,
      value: jsonEncode({
        'runtime': scope.runtime,
        'epoch': scope.epoch,
        'generation': scope.generation,
        'entries': [
          for (final entry in entries)
            {'id': entry.id, 'sequence': entry.sequence, 'text': entry.text},
        ],
      }),
    );
  });

  Future<void> clear(TurnCorrectionScope scope) => _serialize(() async {
    final saved = await _read();
    if (saved?.scope == scope) await _storage.delete(key: _key);
  });

  Future<void> delete() => _serialize(() => _storage.delete(key: _key));

  Future<void> _serialize(Future<void> Function() action) {
    final write = (_pending[_key] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final settled = write.then<void>((_) {}, onError: (Object _) {});
    _pending[_key] = settled;
    settled.whenComplete(() {
      if (identical(_pending[_key], settled)) _pending.remove(_key);
    });
    return write;
  }
}
