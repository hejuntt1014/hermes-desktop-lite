import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'gateway.dart';
import 'mobile_locale.dart';
import 'workspace.dart';

typedef ReferenceScope = ({
  String profile,
  String? runtime,
  String? cwd,
  int connection,
  bool canonical,
});

typedef _ReferenceToken = ({String word, int start, int end});
typedef _ReferenceLookup = ({ReferenceScope scope, String word});

enum ReferenceKind {
  file('@file:', '文件', Icons.description_outlined),
  folder('@folder:', '文件夹', Icons.folder_outlined);

  const ReferenceKind(this.prefix, this.label, this.icon);
  final String prefix, label;
  final IconData icon;
}

class _ReferenceChoice {
  const _ReferenceChoice(this.kind, this.token, {this.path});
  final ReferenceKind kind;
  final String token;
  final String? path;
}

class ComposerReferences extends ChangeNotifier {
  ComposerReferences(this.gateway, this.draft, this.focus) {
    draft.addListener(_refresh);
    focus.addListener(_refresh);
  }

  final Gateway gateway;
  final TextEditingController draft;
  final FocusNode focus;
  final scroll = ScrollController();
  final _cache =
      <_ReferenceLookup, ({DateTime expiry, List<_ReferenceChoice> rows})>{};
  ReferenceScope? _scope;
  _ReferenceLookup? _lookup;
  _ReferenceToken? _token, _dismissed;
  Timer? _delay;
  List<_ReferenceChoice> _rows = const [];
  int _selected = 0;
  bool _loading = false, _failed = false, _disposed = false;

  bool get visible =>
      focus.hasFocus &&
      _token != null &&
      _token != _dismissed &&
      _lookup?.scope == _scope;
  bool get hasChoices => visible && _rows.isNotEmpty;

  void updateScope(ReferenceScope? scope) {
    if (_scope == scope) return;
    if (_scope?.connection != scope?.connection) _cache.clear();
    _scope = scope;
    scheduleMicrotask(_refresh);
  }

  void _refresh() {
    if (_disposed) return;
    final scope = _scope;
    final token = focus.hasFocus && scope != null
        ? _referenceToken(draft.value)
        : null;
    if (token == null || scope == null) {
      _delay?.cancel();
      if (_token == null) return;
      _token = _lookup = null;
      _dismissed = null;
      _rows = const [];
      notifyListeners();
      return;
    }
    final lookup = (scope: scope, word: token.word);
    if (_token == token && _lookup == lookup) return;
    _token = token;
    _lookup = lookup;
    _dismissed = null;
    _delay?.cancel();
    _selected = 0;
    if (scroll.hasClients) scroll.jumpTo(0);
    _rows = _prefixes(token.word);
    _failed = false;
    _loading = false;
    final cached = _cache[lookup];
    if (cached != null && DateTime.now().isBefore(cached.expiry)) {
      if (cached.rows.isNotEmpty) _rows = cached.rows;
    } else if (token.word != '@') {
      _loading = true;
      _delay = Timer(const Duration(milliseconds: 110), () => _read(lookup));
    }
    notifyListeners();
  }

  Future<void> _read(_ReferenceLookup lookup) async {
    final scope = lookup.scope;
    bool current() => !_disposed && _lookup == lookup && _scope == scope;
    if (!current()) return;
    try {
      final rows = scope.canonical && scope.runtime == null
          ? await _readDraft(lookup)
          : await _readSession(lookup);
      if (!current()) return;
      _cache.remove(lookup);
      _cache[lookup] = (
        expiry: DateTime.now().add(const Duration(seconds: 20)),
        rows: rows,
      );
      if (_cache.length > 20) _cache.remove(_cache.keys.first);
      if (rows.isNotEmpty) {
        _rows = rows;
        _selected = 0;
      }
    } catch (_) {
      if (current()) _failed = true;
    } finally {
      if (current()) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<List<_ReferenceChoice>> _readSession(_ReferenceLookup lookup) async {
    final (scope: scope, word: raw) = lookup;
    final word = raw == '@file' || raw == '@folder' ? '$raw:' : raw;
    final result = await gateway.call('complete.path', {
      'word': word,
      'profile': scope.profile,
      'session_id': ?scope.runtime,
      'cwd': ?scope.cwd,
    }, timeout: const Duration(seconds: 8));
    final items = result['items'];
    if (items is! List) throw GatewayError('无法补全工作区路径');
    final found = <String, _ReferenceChoice>{};
    for (final row in items.whereType<Json>().take(60)) {
      if (row['text'] case final String text) {
        for (final kind in ReferenceKind.values) {
          if (!text.startsWith(kind.prefix)) continue;
          if (_pathChoice(kind, text.substring(kind.prefix.length))
              case final choice?) {
            found[choice.token] = choice;
          }
        }
      }
    }
    return found.values.toList();
  }

  Future<List<_ReferenceChoice>> _readDraft(_ReferenceLookup lookup) async {
    final query = lookup.word.substring(1);
    ReferenceKind? only;
    var path = query;
    for (final kind in ReferenceKind.values) {
      final prefix = kind.prefix.substring(1);
      if (query.startsWith(prefix) ||
          query == prefix.substring(0, prefix.length - 1)) {
        only = kind;
        path = query.startsWith(prefix) ? query.substring(prefix.length) : '';
        break;
      }
    }
    if (path.startsWith('/') ||
        path.contains('\\') ||
        path.contains(':') ||
        path.split('/').contains('..')) {
      return const [];
    }
    final slash = path.lastIndexOf('/');
    final directory = slash < 0 ? '' : path.substring(0, slash);
    final stub = path.substring(slash + 1).toLowerCase();
    final scope = WorkspaceScope(
      gateway,
      lookup.scope.profile,
      cwd: lookup.scope.cwd,
    );
    final root = await scope.root();
    final target = directory.isEmpty
        ? root
        : workspaceDocumentPath(Uri(path: directory), baseDirectory: root)!;
    final entries = await scope.list(target);
    return [
      for (final entry in entries)
        if (!entry.name.startsWith('.') &&
            entry.name.toLowerCase().startsWith(stub) &&
            (only == null || entry.directory == (only == ReferenceKind.folder)))
          ?_pathChoice(
            entry.directory ? ReferenceKind.folder : ReferenceKind.file,
            directory.isEmpty ? entry.name : '$directory/${entry.name}',
          ),
    ].take(30).toList();
  }

  void insertPrefix(ReferenceKind kind) {
    final value = draft.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final before = value.text.substring(0, selection.start);
    final gap = before.isNotEmpty && !_startSeparator(before[before.length - 1])
        ? ' '
        : '';
    _insert(value, selection, '$gap${kind.prefix}');
    focus.requestFocus();
  }

  bool appendEntry(WorkspaceEntry entry) {
    final choice = _pathChoice(
      entry.directory ? ReferenceKind.folder : ReferenceKind.file,
      entry.path,
    );
    if (choice == null) return false;
    final text = draft.text;
    if (!text.split('\n').any((line) => line.trimRight() == choice.token)) {
      final separator = text.isEmpty || text.endsWith('\n') ? '' : '\n';
      final end = TextRange.collapsed(text.length);
      _insert(draft.value, end, '$separator${choice.token}\n');
    }
    return true;
  }

  void choose([String? selectedToken]) {
    if (!hasChoices || _referenceToken(draft.value) != _token) return;
    final token = _token!;
    final index = selectedToken == null
        ? _selected
        : _rows.indexWhere((choice) => choice.token == selectedToken);
    if (index < 0) return;
    final choice = _rows[index];
    final value = draft.value;
    final followingSpace =
        token.end < value.text.length && _space.hasMatch(value.text[token.end]);
    final suffix = choice.path == null || followingSpace ? '' : ' ';
    _insert(
      value,
      TextRange(start: token.start, end: token.end),
      '${choice.token}$suffix',
    );
    if (choice.path != null) dismiss();
    focus.requestFocus();
  }

  void _insert(TextEditingValue value, TextRange range, String replacement) {
    draft.value = value
        .replaced(range, replacement)
        .copyWith(
          selection: TextSelection.collapsed(
            offset: range.start + replacement.length,
          ),
          composing: TextRange.empty,
        );
  }

  void move({required bool previous}) {
    if (!hasChoices) return;
    _selected = (_selected + (previous ? -1 : 1)) % _rows.length;
    if (scroll.hasClients) {
      final position = scroll.position;
      final top = _selected * _rowHeight;
      if (top < position.pixels ||
          top + _rowHeight > position.pixels + position.viewportDimension) {
        scroll.jumpTo(top.clamp(0, position.maxScrollExtent).toDouble());
      }
    }
    notifyListeners();
  }

  void dismiss() {
    _dismissed = _token;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _delay?.cancel();
    draft.removeListener(_refresh);
    focus.removeListener(_refresh);
    scroll.dispose();
    super.dispose();
  }
}

final _space = RegExp(r'\s');
final _controls = RegExp(r'[\x00-\x1f\x7f]');
final _referenceNeedsQuotes = RegExp(
  r'''[\s()\[\]{}<>"'`]|(?:[:,.;!?]|:\d+(?:-\d+)?)$''',
);
const _quotes = ['"', "'", '`'];
const _rowHeight = 48.0;

bool _startSeparator(String char) =>
    _space.hasMatch(char) || '([（【'.contains(char);

_ReferenceToken? _referenceToken(TextEditingValue value) {
  if (!value.selection.isValid || !value.selection.isCollapsed) return null;
  final text = value.text;
  final cursor = value.selection.extentOffset;
  if (cursor <= 0 || cursor > text.length) return null;
  final composing = value.isComposingRangeValid && !value.composing.isCollapsed;
  final line = (text.lastIndexOf('\n', cursor - 1) + 1).clamp(
    cursor > 768 ? cursor - 768 : 0,
    cursor,
  );
  final nextLine = text.indexOf('\n', cursor);
  final after = text.substring(cursor, nextLine < 0 ? text.length : nextLine);
  for (
    var start = text.lastIndexOf('@', cursor - 1);
    start >= line;
    start = start > 0 ? text.lastIndexOf('@', start - 1) : -1
  ) {
    if (start > 0 && !_startSeparator(text[start - 1])) continue;
    // Some keyboards leave the path fragment under composition until a space
    // is entered. Offer choices without interrupting that composition.
    if (composing &&
        (value.composing.start < start || value.composing.end != cursor)) {
      continue;
    }
    final word = text.substring(start, cursor);
    if (utf8.encode(word).length > 768) break;
    final quoted = ReferenceKind.values
        .where(
          (kind) =>
              word.startsWith(kind.prefix) &&
              word.length > kind.prefix.length &&
              _quotes.contains(word[kind.prefix.length]),
        )
        .firstOrNull;
    if (quoted != null) {
      final quote = word[quoted.prefix.length];
      final partial = word.substring(quoted.prefix.length + 1);
      if (partial.contains(quote) || _controls.hasMatch(partial)) continue;
      final close = after.indexOf(quote);
      return (
        word: '${quoted.prefix}$partial',
        start: start,
        end: cursor + (close < 0 ? 0 : close + 1),
      );
    }
    final tail = word.substring(1);
    if (_space.hasMatch(tail) ||
        _controls.hasMatch(tail) ||
        tail.contains('@') ||
        _quotes.any(tail.contains)) {
      continue;
    }
    final finish = after.indexOf(RegExp(r'[\s)\]）】]'));
    return (
      word: word,
      start: start,
      end: cursor + (finish < 0 ? after.length : finish),
    );
  }
  return null;
}

List<_ReferenceChoice> _prefixes(String word) => [
  for (final kind in ReferenceKind.values)
    if (kind.prefix != word && kind.prefix.startsWith(word))
      _ReferenceChoice(kind, kind.prefix),
];

_ReferenceChoice? _pathChoice(ReferenceKind kind, String path) {
  if (path.isEmpty || path.length > 4096 || _controls.hasMatch(path)) {
    return null;
  }
  final quote = _referenceNeedsQuotes.hasMatch(path)
      ? _quotes.where((quote) => !path.contains(quote)).firstOrNull
      : '';
  return quote == null
      ? null
      : _ReferenceChoice(kind, '${kind.prefix}$quote$path$quote', path: path);
}

class ReferenceSuggestions extends StatelessWidget {
  const ReferenceSuggestions({super.key, required this.references});
  final ComposerReferences references;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: references,
    builder: (context, _) {
      if (!references.visible) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 3, 18, 0),
        child: Material(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 3, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.tr('工作区引用'),
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    if (references._loading)
                      const SizedBox.square(
                        dimension: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    IconButton(
                      tooltip: context.tr('关闭'),
                      onPressed: references.dismiss,
                      icon: const Icon(Icons.close_rounded, size: 17),
                    ),
                  ],
                ),
              ),
              if (references._rows.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight:
                        MediaQuery.sizeOf(context).height -
                                MediaQuery.viewInsetsOf(context).bottom <
                            340
                        ? _rowHeight
                        : 3 * _rowHeight,
                  ),
                  child: ListView.builder(
                    controller: references.scroll,
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.manual,
                    itemExtent: _rowHeight,
                    itemCount: references._rows.length,
                    itemBuilder: (context, index) {
                      final choice = references._rows[index];
                      return ListTile(
                        selected: references._selected == index,
                        selectedTileColor: colors.secondaryContainer.withValues(
                          alpha: .58,
                        ),
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: Icon(choice.kind.icon, size: 18),
                        title: Text(
                          choice.path ?? context.tr(choice.kind.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: choice.path == null
                            ? Text(
                                choice.token,
                                style: theme.textTheme.labelSmall,
                              )
                            : null,
                        onTap: () => references.choose(choice.token),
                      );
                    },
                  ),
                )
              else if (!references._loading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 11),
                  child: Text(
                    context.tr(references._failed ? '无法补全工作区路径' : '没有匹配的工作区路径'),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
