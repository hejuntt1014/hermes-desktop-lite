import 'dart:collection';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'gateway.dart';
import 'history.dart';
import 'transcript_navigation.dart';

class ReadingPosition {
  const ReadingPosition(this.address, this.offset);
  final MessageAddress address;
  final double offset;

  Json toWire() => {...address.toWire(), 'offset_px': offset};

  static ReadingPosition? fromWire(Json wire) {
    final address = MessageAddress.fromWire(wire);
    final offset = wire['offset_px'];
    if (address == null || offset is! num || !offset.isFinite || offset < 0) {
      return null;
    }
    return ReadingPosition(address, offset.toDouble());
  }
}

class ReadingPositions {
  static const _vault = FlutterSecureStorage();
  static final _pending = <String, Future<void>>{};

  ReadingPositions(Gateway gateway, String profile, String session)
    : _key =
          'hermes.mobile.reading.v1.${base64Url.encode(utf8.encode(jsonEncode([gateway.base.toString(), profile, session])))}';

  final String _key;

  Future<ReadingPosition?> read() async {
    await _pending[_key];
    final raw = await _vault.read(key: _key);
    if (raw == null) return null;
    final wire = jsonDecode(raw);
    return wire is Json ? ReadingPosition.fromWire(wire) : null;
  }

  Future<void> write(ReadingPosition? reading) {
    final previous = _pending[_key] ?? Future<void>.value();
    final write = previous.then(
      (_) => reading == null
          ? _vault.delete(key: _key)
          : _vault.write(key: _key, value: jsonEncode(reading.toWire())),
    );
    final settled = write.then<void>((_) {}, onError: (Object _) {});
    _pending[_key] = settled;
    settled.whenComplete(() {
      if (identical(_pending[_key], settled)) _pending.remove(_key);
    });
    return write;
  }
}

class ReadingWindow {
  ReadingWindow(TranscriptWindow page, this.center)
    : oldest = page,
      latest = page,
      _records = [...page.rows];

  ReadingWindow.detached(ReadingWindow source)
    : oldest = source.oldest,
      latest = source.latest,
      _records = [...source.records],
      center = source.center;

  TranscriptWindow oldest, latest;
  final List<Json> _records;
  late final List<Json> records = UnmodifiableListView(_records);
  int center;
  int _revision = 0;
  int get revision => _revision;

  void observeTail(HistoryPage page) {
    if (latest.hasNewer ||
        latest.session != page.sessionId ||
        latest.rows.isEmpty) {
      return;
    }
    if (page.after(latest.rows.last).isEmpty) return;

    latest = TranscriptWindow(
      latest.session,
      latest.rows,
      offset: latest.offset,
      latestFirst: latest.latestFirst,
      hasOlder: latest.hasOlder,
      hasNewer: true,
      total: latest.total,
    );
  }

  void extend(TranscriptWindow next, {required bool older}) {
    final current = older ? oldest : latest;
    if (identical(current, next)) return;
    final boundary = older ? current.rows.first : current.rows.last;
    final overlap = next.rows.indexWhere(
      (row) => sameHistoryRow(boundary, row),
    );
    if (next.session != current.session || overlap < 0) {
      throw GatewayError('会话历史已更新，请重新定位消息');
    }
    if (older) {
      oldest = next;
      _records.insertAll(0, next.rows.take(overlap));
    } else {
      latest = next;
      _records.addAll(next.rows.skip(overlap + 1));
    }
    _revision++;
  }

  bool trimAround(int rowId, {required int limit}) {
    if (_records.length <= limit) return false;
    final anchor = _records.indexWhere((row) => historyRowId(row) == rowId);
    if (anchor < 0) return false;

    final count = _records.length;
    final start = (anchor - limit ~/ 2).clamp(0, count - limit);
    final end = start + limit;
    final newOldest = _retainedEdge(oldest, start, end, older: true);
    final newLatest = _retainedEdge(latest, start, end, older: false);
    if (newOldest == null || newLatest == null) return false;
    _records.removeRange(end, count);
    _records.removeRange(0, start);
    oldest = newOldest;
    latest = newLatest;
    center = rowId;
    _revision++;
    return true;
  }

  TranscriptWindow? _retainedEdge(
    TranscriptWindow edge,
    int start,
    int end, {
    required bool older,
  }) {
    if (edge.rows.isEmpty) return null;
    final count = _records.length;
    // Keep enough neighboring records to re-anchor a moved pagination boundary.
    final first = older ? start : (end - edge.rows.length).clamp(start, end - 1);
    final last = older ? (start + edge.rows.length).clamp(start + 1, end) : end;
    final previousBoundary = older ? 0 : count - 1;
    final previousPosition = edge.positionOf(older ? 0 : edge.rows.length - 1);
    final offset = edge.latestFirst
        ? previousPosition + previousBoundary - (last - 1)
        : previousPosition + first - previousBoundary;
    if (offset < 0) return null;
    return TranscriptWindow(
      edge.session,
      _records.sublist(first, last),
      offset: offset,
      latestFirst: edge.latestFirst,
      hasOlder: oldest.hasOlder || first > 0,
      hasNewer: latest.hasNewer || last < count,
      total: edge.total,
    );
  }
}
