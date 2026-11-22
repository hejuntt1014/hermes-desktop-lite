import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'gateway.dart';
import 'transcript_navigation.dart';

class MessageBookmark {
  const MessageBookmark({
    required this.profile,
    required this.session,
    required this.title,
    required this.excerpt,
    required this.address,
  });
  final String profile, session, title, excerpt;
  final MessageAddress address;

  bool addresses(String profile, String session, int row) =>
      this.profile == profile &&
      this.session == session &&
      address.rowId == row;

  Json toWire() => {
    'profile': profile,
    'session': session,
    'title': title,
    'excerpt': excerpt,
    ...address.toWire(),
  };

  static MessageBookmark? fromWire(Json row) {
    final address = MessageAddress.fromWire(row);
    final profile = row['profile'];
    final session = row['session'];
    if (address == null ||
        profile is! String ||
        session is! String ||
        session.isEmpty) {
      return null;
    }
    return MessageBookmark(
      profile: profile,
      session: session,
      title: row['title']?.toString() ?? '会话',
      excerpt: row['excerpt']?.toString() ?? '',
      address: address,
    );
  }
}

class MessageBookmarks {
  MessageBookmarks._(Gateway gateway)
    : _key =
          'hermes.mobile.message-bookmarks.v1.${base64Url.encode(utf8.encode(gateway.base.toString()))}';

  static const _vault = FlutterSecureStorage();
  static final _instances = Expando<MessageBookmarks>();

  static MessageBookmarks forGateway(Gateway gateway) =>
      _instances[gateway] ??= MessageBookmarks._(gateway);

  final String _key;
  Future<void> _pending = Future.value();

  Future<List<MessageBookmark>> read() async {
    await _pending;
    return _read();
  }

  Future<List<MessageBookmark>> _read() async {
    final raw = await _vault.read(key: _key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .whereType<Json>()
        .map(MessageBookmark.fromWire)
        .nonNulls
        .toList();
  }

  Future<bool> setSaved(MessageBookmark bookmark, {required bool saved}) {
    final result = _pending.then((_) async {
      final marks = await _read();
      final index = marks.indexWhere(
        (other) => other.addresses(
          bookmark.profile,
          bookmark.session,
          bookmark.address.rowId,
        ),
      );
      if ((index != -1) == saved) return saved;
      if (saved) {
        marks.insert(0, bookmark);
      } else {
        marks.removeAt(index);
      }
      await _vault.write(
        key: _key,
        value: jsonEncode(marks.map((mark) => mark.toWire()).toList()),
      );
      return saved;
    });
    _pending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

String bookmarkExcerpt(String text) {
  final singleLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final chars = singleLine.runes;
  return chars.length <= 170
      ? singleLine
      : '${String.fromCharCodes(chars.take(170))}…';
}
