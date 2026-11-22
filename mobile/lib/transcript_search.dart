import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:markdown/markdown.dart' as md;

import 'attachment_view.dart';
import 'gateway.dart';
import 'history.dart';
import 'markdown_blocks.dart';
import 'transcript_navigation.dart';

class TranscriptMatch {
  const TranscriptMatch(
    this.address,
    this.preview,
    this.user, {
    required this.multiple,
  });
  final MessageAddress address;
  final TranscriptMatchExcerpt preview;
  final bool user;
  final bool multiple;
}

typedef _RecentTranscript = ({Json? boundary, List<TranscriptRecord>? rows});

class TranscriptSearch extends ChangeNotifier {
  TranscriptSearch(this.navigation);
  static const _resultPageSize = 40;
  static const _recentRowLimit = 320;

  final TranscriptNavigation navigation;
  final matches = <TranscriptMatch>[];
  final _pendingMatches = <TranscriptMatch>[];
  final _matchedIds = <int>{};
  _RecentTranscript? _recent;
  int _recentMatches = 0;
  int scanned = 0;
  int get recentMatches => _recentMatches;
  String query = '';
  String? error;
  int? selectedMatch;
  double scrollOffset = 0;
  bool _running = false, _complete = false;
  bool _paused = false, _restartOnRetry = false;
  int _limit = _resultPageSize;
  Object? _viewer;
  bool get hasMore =>
      query.isNotEmpty &&
      error == null &&
      (!_complete || _pendingMatches.isNotEmpty);
  int get olderMatches => matches.length - recentMatches;
  bool get paused => _paused && hasMore;
  bool get searching =>
      _viewer != null &&
      !_paused &&
      query.isNotEmpty &&
      error == null &&
      (_recent != null || hasMore && olderMatches < _limit);
  bool get canLoadMore =>
      _viewer != null &&
      !_paused &&
      !_running &&
      hasMore &&
      olderMatches >= _limit;
  int _revision = 0;
  Timer? _debounce;
  TranscriptScan? _cursor;
  FileTransferControl? _reading;

  void show(Object viewer) {
    _viewer = viewer;
    unawaited(_run(_revision));
  }

  void hide(Object viewer) {
    if (!identical(_viewer, viewer)) return;
    _viewer = null;
    _debounce?.cancel();
    _reading?.cancel();
  }

  void setQuery(String value) {
    reset(value.trim());
    if (_viewer != null && query.isNotEmpty) {
      final revision = _revision;
      _debounce = Timer(
        const Duration(milliseconds: 220),
        () => _run(revision),
      );
    }
  }

  void reset(String value) {
    _revision++;
    _debounce?.cancel();
    _reading?.cancel();
    _reading = null;
    _cursor = null;
    query = value;
    matches.clear();
    _pendingMatches.clear();
    _recent = null;
    _matchedIds.clear();
    _recentMatches = 0;
    scanned = 0;
    _limit = _resultPageSize;
    selectedMatch = null;
    scrollOffset = 0;
    error = null;
    _running = false;
    _complete = false;
    _paused = false;
    _restartOnRetry = false;
    notifyListeners();
  }

  void loadMore() {
    if (!canLoadMore) return;
    _limit += _resultPageSize;
    unawaited(_run(_revision));
  }

  void pause() {
    if (!searching) return;
    _paused = true;
    _debounce?.cancel();
    _reading?.cancel();
    notifyListeners();
  }

  void resume() {
    if (!paused) return;
    _paused = false;
    if (olderMatches >= _limit) _limit += _resultPageSize;
    notifyListeners();
    unawaited(_run(_revision));
  }

  void retry() {
    if (_restartOnRetry) {
      setQuery(query);
      return;
    }
    error = null;
    _paused = false;
    notifyListeners();
    unawaited(_run(_revision));
  }

  void acceptLatest(HistoryPage page, Json? previous) {
    if (page.sessionId != navigation.session ||
        query.isEmpty ||
        sameHistoryTail(previous, page.rows.lastOrNull)) {
      return;
    }
    final anchor = previous == null
        ? -1
        : page.rows.lastIndexWhere((row) => sameHistoryRow(previous, row));
    final missingAnchor = previous != null && anchor < 0;
    if (previous != null &&
            (missingAnchor
                ? page.after(previous).isEmpty
                : !sameHistoryTail(previous, page.rows[anchor])) ||
        previous == null && page.nextOffset != null) {
      setQuery(query);
      return;
    }
    if (!_running && _cursor == null && !_complete && matches.isEmpty) return;
    final pending = _recent;
    final boundary = pending == null ? previous : pending.boundary;
    if (missingAnchor || pending != null && pending.rows == null) {
      _recent = (boundary: boundary, rows: null);
    } else {
      final rows = pending?.rows ?? <TranscriptRecord>[];
      for (var i = anchor + 1; i < page.rows.length; i++) {
        if (_searchableRow(page.rows[i])) {
          rows.add((row: page.rows[i], tailOffset: page.rows.length - 1 - i));
        }
      }
      if (rows.isEmpty) return;
      _recent = (
        boundary: boundary,
        rows: rows.length > _recentRowLimit ? null : rows,
      );
    }
    unawaited(_run(_revision));
  }

  Future<List<TranscriptMatch>?> _scanRecent(
    Json? boundary,
    String query,
    FileTransferControl control,
  ) async {
    final anchor = boundary == null ? null : historyRowId(boundary);
    if (anchor == null) return null;
    final matches = <TranscriptMatch>[];
    final batch = <TranscriptRecord>[];
    await for (final item in navigation.scan(control: control)) {
      final id = historyRowId(item.row);
      if (id == anchor) {
        if (!sameHistoryTail(boundary, item.row)) return null;
        if (batch.isNotEmpty) {
          matches.addAll(await searchTranscriptBatch(batch, query));
        }
        control.throwIfCancelled();
        return matches;
      }
      // As in HistoryPage.after, persisted IDs increase within the profile.
      if (id != null && id < anchor) return null;
      if (!_searchableRow(item.row)) continue;
      batch.add(item);
      if (batch.length == 100) {
        matches.addAll(await searchTranscriptBatch(batch, query));
        control.throwIfCancelled();
        batch.clear();
      }
    }
    return null;
  }

  void _publishPending() {
    final take = (_limit - olderMatches).clamp(0, _pendingMatches.length);
    if (take == 0) return;
    matches.addAll(_pendingMatches.take(take));
    _pendingMatches.removeRange(0, take);
    notifyListeners();
  }

  Future<void> _run(int revision) async {
    if (!searching || _running || revision != _revision) return;
    final requestedQuery = query;
    final control = _reading = FileTransferControl();
    _running = true;
    notifyListeners();
    try {
      _publishPending();
      while (revision == _revision && searching && !control.cancelled) {
        if (_recent case final recent?) {
          _recent = null;
          final List<TranscriptMatch>? found;
          try {
            final batch = recent.rows;
            found = batch == null
                ? await _scanRecent(recent.boundary, requestedQuery, control)
                : await searchTranscriptBatch(
                    batch.reversed.toList(),
                    requestedQuery,
                  );
          } catch (_) {
            if (revision == _revision) {
              // Include arrivals queued while this read was interrupted.
              _recent = (boundary: recent.boundary, rows: null);
            }
            rethrow;
          }
          if (revision != _revision) return;
          if (found == null) {
            setQuery(query);
            return;
          }
          final added = found
              .where((hit) => _matchedIds.add(hit.address.rowId))
              .toList();
          if (added.isNotEmpty) {
            matches.insertAll(0, added);
            _recentMatches += added.length;
            if (selectedMatch case final index?) {
              selectedMatch = index + added.length;
            }
            notifyListeners();
          }
          continue;
        }
        final cursor = _cursor ??= TranscriptScan(navigation);
        final batch = <TranscriptRecord>[];
        final previousProgress = scanned ~/ 1000;
        Object? readFailure;
        try {
          for (var count = 0; count < 100 && !control.cancelled; count++) {
            final item = await cursor.next(control: control);
            if (revision != _revision) return;
            if (item == null) {
              _complete = true;
              _cursor = null;
              break;
            }
            scanned++;
            if (_searchableRow(item.row)) batch.add(item);
          }
        } on FileTransferCancelled {
          if (revision != _revision) return;
        } catch (failure) {
          readFailure = failure;
        }
        if (scanned ~/ 1000 != previousProgress) notifyListeners();
        if (batch.isNotEmpty) {
          final found = await searchTranscriptBatch(batch, requestedQuery);
          if (revision != _revision) return;
          _pendingMatches.addAll(
            found.where((hit) => _matchedIds.add(hit.address.rowId)),
          );
          _publishPending();
        }
        if (readFailure != null) throw readFailure;
      }
    } on FileTransferCancelled {
      // The next time the finder is visible, resume from the same boundary.
    } catch (failure) {
      if (revision == _revision) {
        _restartOnRetry = failure is TranscriptHistoryChanged;
        error = failure.toString();
      }
    } finally {
      if (identical(_reading, control)) _reading = null;
      if (revision == _revision) {
        _running = false;
        notifyListeners();
        if (control.cancelled && searching) unawaited(_run(revision));
      }
    }
  }

  @override
  void dispose() {
    _viewer = null;
    _debounce?.cancel();
    _revision++;
    _reading?.cancel();
    super.dispose();
  }
}

bool _searchableRow(Json row) =>
    row['display_kind'] != 'hidden' &&
    (row['role'] == 'user' || row['role'] == 'assistant');

final _markdownSyntax = RegExp(r'[\r\n\t`*_~\[\]()<>#&!|\\=:+.\-]');
final _searchWhitespace = RegExp(r'\s+');
final _searchPathSeparator = RegExp(r'[/\\]');

String _searchMarkdownText(String text) {
  const separated = {
    'p',
    'li',
    'td',
    'th',
    'tr',
    'blockquote',
    'pre',
    'br',
    'hr',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
  };
  final textBuffer = StringBuffer();
  void visit(md.Node node) {
    if (node is! md.Element) {
      textBuffer.write(node.textContent);
      return;
    }
    final boundary = separated.contains(node.tag);
    if (boundary) textBuffer.write(' ');
    if (node.tag == 'img') {
      textBuffer.write(node.attributes['alt'] ?? '');
    } else {
      node.children?.forEach(visit);
    }
    if (boundary) textBuffer.write(' ');
  }

  messageMarkdownDocument().parseLines(text.split('\n')).forEach(visit);
  return textBuffer.toString();
}

String _searchableText(Json row) {
  final text = transcriptText(row);
  final visible = row['role'] == 'user'
      ? text
            .split('\n')
            .where((line) => !line.startsWith('@image:'))
            .map((line) {
              final attachment = attachedPath(line);
              return attachment == null
                  ? line
                  : attachment.split(_searchPathSeparator).last;
            })
            .join(' ')
      : !_markdownSyntax.hasMatch(text)
      ? text
      : _searchMarkdownText(text);
  return visible.replaceAll(_searchWhitespace, ' ').trim();
}

RegExp _searchPattern(String text) => RegExp(
  RegExp.escape(text.trim().replaceAll(_searchWhitespace, ' ')),
  caseSensitive: false,
  unicode: true,
);

TranscriptMatchExcerpt _matchExcerpt(String plain, RegExpMatch hit) {
  var start = hit.start > 48 ? hit.start - 48 : 0;
  var end = hit.end + 72 < plain.length ? hit.end + 72 : plain.length;
  if (start > 0 &&
      plain.codeUnitAt(start) >= 0xdc00 &&
      plain.codeUnitAt(start) <= 0xdfff) {
    start--;
  }
  if (end < plain.length &&
      plain.codeUnitAt(end) >= 0xdc00 &&
      plain.codeUnitAt(end) <= 0xdfff) {
    end++;
  }
  final prefix = start == 0 ? '' : '…';
  final suffix = end == plain.length ? '' : '…';
  return (
    text: '$prefix${plain.substring(start, end)}$suffix',
    start: hit.start - start + prefix.length,
    end: hit.end - start + prefix.length,
  );
}

class TranscriptOccurrenceCursor {
  TranscriptOccurrenceCursor._(this._text, String query)
    : _matches = _searchPattern(query).allMatches(_text).iterator;

  static Future<TranscriptOccurrenceCursor> read(Json row, String query) async {
    final text = await Isolate.run(() => _searchableText(row));
    return TranscriptOccurrenceCursor._(text, query);
  }

  final String _text;
  final Iterator<RegExpMatch> _matches;
  late bool _hasMore = _matches.moveNext();
  bool get hasMore => _hasMore;

  List<TranscriptMatchExcerpt> nextPage() {
    const pageSize = 40;
    final excerpts = <TranscriptMatchExcerpt>[];
    while (hasMore && excerpts.length < pageSize) {
      excerpts.add(_matchExcerpt(_text, _matches.current));
      _hasMore = _matches.moveNext();
    }
    return excerpts;
  }
}

List<TranscriptMatch> matchTranscript(
  List<TranscriptRecord> batch,
  String query,
) {
  if (query.trim().isEmpty) return [];
  final pattern = _searchPattern(query);
  final matches = <TranscriptMatch>[];
  for (final item in batch) {
    final id = historyRowId(item.row);
    if (id == null) continue;
    final plain = _searchableText(item.row);
    if (plain.isEmpty) continue;
    final hits = pattern.allMatches(plain).iterator;
    if (!hits.moveNext()) continue;
    final excerpt = _matchExcerpt(plain, hits.current);
    final user = item.row['role'] == 'user';
    matches.add(
      TranscriptMatch(
        MessageAddress(
          id,
          promptId: user ? id : null,
          tailOffset: item.tailOffset,
        ),
        excerpt,
        user,
        multiple: hits.moveNext(),
      ),
    );
  }
  return matches;
}

Future<List<TranscriptMatch>> searchTranscriptBatch(
  List<({Json row, int tailOffset})> batch,
  String query,
) => Isolate.run(() => matchTranscript(batch, query));
