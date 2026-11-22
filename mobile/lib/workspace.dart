import 'dart:convert';
import 'dart:isolate';

import 'gateway.dart';

class WorkspaceBrowserPosition {
  const WorkspaceBrowserPosition({
    required this.session,
    required this.root,
    required this.trail,
    required this.query,
    required this.offset,
    this.file,
    this.fragment,
  });

  final String? session;
  final String root, query;
  final List<String> trail;
  final String? file, fragment;
  final double offset;

  Json toWire() => {
    'session': ?session,
    'root': root,
    'trail': trail,
    'query': query,
    'offset': offset,
    'file': ?file,
    'fragment': ?fragment,
  };

  static WorkspaceBrowserPosition? fromWire(Object? value) {
    if (value is! Json) return null;
    final session = value['session'];
    final root = value['root'];
    final trail = value['trail'];
    if (root is! String ||
        root.isEmpty ||
        trail is! List ||
        trail.isEmpty ||
        trail.any((entry) => entry is! String || entry.isEmpty)) {
      return null;
    }
    final query = value['query'];
    final offset = value['offset'];
    final file = value['file'];
    final fragment = value['fragment'];
    return WorkspaceBrowserPosition(
      session: session is String ? session : null,
      root: root,
      trail: trail.cast<String>(),
      query: query is String ? query : '',
      offset: offset is num && offset.isFinite && offset >= 0
          ? offset.toDouble()
          : 0,
      file: file is String && file.isNotEmpty ? file : null,
      fragment: fragment is String ? fragment : null,
    );
  }
}

class WorkspaceScope {
  const WorkspaceScope(this.gateway, this.profile, {this.session, this.cwd});

  final Gateway gateway;
  final String profile;
  final String? session, cwd;

  Future<Json> get(
    String route, [
    Map<String, String> args = const {},
    bool sessionScoped = false,
    FileTransferControl? control,
  ]) {
    final query = {
      ...args,
      'profile': profile,
      if (sessionScoped && session != null) 'session_id': session!,
    };
    return control == null
        ? gateway.api(route, query: query)
        : gateway.readConversationPage(route, query: query, control: control);
  }

  Future<String> root() async {
    if (cwd?.isNotEmpty == true) return cwd!;
    final reply = await get('api/fs/default-cwd');
    final path = reply['cwd'];
    if (path is! String || path.isEmpty) {
      throw GatewayError('网关未提供工作区目录');
    }
    return path;
  }

  Future<List<WorkspaceEntry>> list(String directory) async {
    final data = await get('api/fs/list', {'path': directory});
    final entries = data['entries'];
    final failure = data['error']?.toString();
    if (failure?.isNotEmpty == true || entries is! List) {
      throw GatewayError(
        '无法读取此目录',
        const {'ENOENT', 'ENOTDIR'}.contains(failure) ? 404 : null,
      );
    }
    return entries
        .whereType<Json>()
        .map(WorkspaceEntry.fromWire)
        .where((entry) => entry.name.isNotEmpty && entry.path.isNotEmpty)
        .toList()
      ..sort(
        (a, b) => a.directory == b.directory
            ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
            : a.directory
            ? -1
            : 1,
      );
  }

  Future<WorkspaceText> readText(String path) async {
    final data = await get('api/fs/read-text', {'path': path}, true);
    if (data['binary'] == true) return const WorkspaceText(binary: true);
    final text = data['text'];
    if (text is! String) throw GatewayError('网关未返回文件内容');
    const limit = 192 * 1024;
    final bytes = utf8.encode(text);
    return WorkspaceText(
      text: bytes.length > limit
          ? utf8.decode(bytes.sublist(0, limit), allowMalformed: true)
          : text,
      truncated: data['truncated'] == true || bytes.length > limit,
      markdown:
          data['language'] == 'markdown' ||
          RegExp(
            r'\.(md|mdx|markdown|mdown|mkd)$',
            caseSensitive: false,
          ).hasMatch(path),
    );
  }
}

class WorkspaceEntry {
  const WorkspaceEntry(this.name, this.path, {this.directory = false});

  factory WorkspaceEntry.fromWire(Json data) => WorkspaceEntry(
    data['name'] as String? ?? '',
    data['path'] as String? ?? '',
    directory: data['isDirectory'] == true,
  );

  final String name, path;
  final bool directory;
}

class WorkspaceText {
  const WorkspaceText({
    this.text = '',
    this.binary = false,
    this.truncated = false,
    this.markdown = false,
  });

  final String text;
  final bool binary, truncated, markdown;
}

String? workspaceDocumentPath(Uri uri, {String? baseDirectory}) {
  final localFile =
      uri.scheme == 'file' && (uri.host.isEmpty || uri.host == 'localhost');
  if ((uri.hasAuthority || uri.hasScheme) && !localFile || uri.path.isEmpty) {
    return null;
  }
  var path = Uri.decodeComponent(uri.path);
  if (uri.scheme == 'file' && RegExp(r'^/[a-zA-Z]:/').hasMatch(path)) {
    path = path.substring(1);
  }
  if (path.contains(RegExp(r'[\x00-\x1f]'))) return null;
  return workspaceFilePath(path, baseDirectory);
}

String? workspaceDocumentFragment(Uri uri) {
  final fragment = uri.fragment;
  if (fragment.isEmpty) return null;
  try {
    return Uri.decodeComponent(fragment);
  } on FormatException {
    return fragment;
  } on ArgumentError {
    return fragment;
  }
}

bool workspaceFileHasRoot(String path) =>
    path.startsWith('/') ||
    path.startsWith('~/') ||
    path.startsWith('\\\\') ||
    path.startsWith('file://') ||
    path.startsWith('data:image/') ||
    RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(path);

String workspaceFilePath(String path, String? baseDirectory) {
  if (workspaceFileHasRoot(path) ||
      baseDirectory == null ||
      baseDirectory.isEmpty) {
    return path;
  }
  final separator = baseDirectory.contains('\\') && !baseDirectory.contains('/')
      ? '\\'
      : '/';
  final dot = separator == '\\'
      ? RegExp(r'^(?:\.[/\\])+')
      : RegExp(r'^(?:\./)+');
  final relative = path.replaceFirst(dot, '');
  return baseDirectory.endsWith(separator)
      ? '$baseDirectory$relative'
      : '$baseDirectory$separator$relative';
}

String workspaceName(String path) {
  final stripped = path.replaceFirst(RegExp(r'[/\\]+$'), '');
  return stripped.isEmpty ? path : stripped.split(RegExp(r'[/\\]')).last;
}

bool workspaceImage(String path) =>
    path.startsWith('data:image/') ||
    RegExp(
      r'\.(png|jpe?g|webp|gif|bmp|ico|tiff?)$',
      caseSensitive: false,
    ).hasMatch(path);

enum ReviewMode {
  working('未提交', 'uncommitted'),
  branch('当前分支', 'branch'),
  previous('对比上一版本', 'lastTurn');

  const ReviewMode(this.label, this.wire);
  final String label, wire;
}

class WorkspaceReviewPosition {
  const WorkspaceReviewPosition({
    required this.session,
    required this.directory,
    required this.repository,
    required this.mode,
    required this.query,
    this.file,
  });

  final String? session;
  final String directory, repository, query;
  final ReviewMode mode;
  final String? file;

  Json toWire() => {
    'session': ?session,
    'directory': directory,
    'repository': repository,
    'mode': mode.name,
    'query': query,
    'file': ?file,
  };

  static WorkspaceReviewPosition? fromWire(Object? value) {
    if (value is! Json) return null;
    final directory = value['directory'];
    final repository = value['repository'];
    final mode = ReviewMode.values
        .where((mode) => mode.name == value['mode'])
        .firstOrNull;
    if (directory is! String ||
        directory.isEmpty ||
        repository is! String ||
        repository.isEmpty ||
        mode == null) {
      return null;
    }
    final session = value['session'];
    final query = value['query'];
    final file = value['file'];
    return WorkspaceReviewPosition(
      session: session is String ? session : null,
      directory: directory,
      repository: repository,
      mode: mode,
      query: query is String ? query : '',
      file: file is String && file.isNotEmpty ? file : null,
    );
  }
}

class ChangedFile {
  ChangedFile.fromWire(Json data)
    : path = data['path'] as String? ?? '',
      status = data['status'] as String? ?? '',
      added = (data['added'] as num?)?.toInt() ?? 0,
      removed = (data['removed'] as num?)?.toInt() ?? 0,
      staged = data['staged'] == true;

  final String path, status;
  final int added, removed;
  final bool staged;
}

class ReviewListing {
  const ReviewListing(this.mode, this.root, this.files, {this.base});

  final ReviewMode mode;
  final String? root, base;
  final List<ChangedFile> files;

  static Future<ReviewListing> load(
    WorkspaceScope scope,
    ReviewMode mode, {
    String? directory,
  }) async {
    final cwd = directory ?? await scope.root();
    final repo = await scope.get('api/fs/git-root', {'path': cwd});
    final root = repo['root'];
    if (root is! String || root.isEmpty) return ReviewListing(mode, null, []);
    String? base;
    if (mode == ReviewMode.previous) {
      final revision = await scope.get('api/git/review/rev-parse', {
        'path': root,
        'ref': 'HEAD~1',
      });
      final sha = revision['sha'];
      if (sha == null || sha == '') return ReviewListing(mode, root, []);
      if (sha is! String ||
          !RegExp(r'^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$').hasMatch(sha)) {
        throw GatewayError('网关未返回有效的提交标识');
      }
      base = sha;
    }
    final data = await scope.get('api/git/review/list', {
      'path': root,
      'scope': mode.wire,
      'base': ?base,
    });
    final files = data['files'];
    if (files is! List) throw GatewayError('网关未返回有效的工作区变更');
    return ReviewListing(
      mode,
      root,
      files
          .whereType<Json>()
          .map(ChangedFile.fromWire)
          .where((file) => file.path.isNotEmpty)
          .toList(),
      base: (data['base'] as String?) ?? base,
    );
  }

  Future<ReviewDiff> diff(
    WorkspaceScope scope,
    ChangedFile file, {
    FileTransferControl? control,
  }) async {
    final working = mode == ReviewMode.working;
    final endpoint = working ? 'api/git/file-diff' : 'api/git/review/diff';
    final query = {
      'path': root!,
      'file': file.path,
      if (!working) ...{'scope': mode.wire, 'base': ?base},
    };
    final reply = control == null
        ? await scope.get(endpoint, query)
        : await scope.gateway.readConversationPage(
            endpoint,
            query: {...query, 'profile': scope.profile},
            control: control,
            backgroundDecode: true,
          );
    control?.throwIfCancelled();
    final raw = reply['diff'];
    if (raw is! String) throw GatewayError('网关未返回有效差异');
    return raw.length > 64 * 1024
        ? _parseLargeDiff(raw)
        : ReviewDiff.parse(raw);
  }
}

Future<ReviewDiff> _parseLargeDiff(String raw) =>
    Isolate.run(() => ReviewDiff.parse(raw));

enum DiffKind { header, plain, added, removed }

typedef DiffLine = ({int? oldLine, int? newLine, DiffKind kind, String text});

class ReviewDiff {
  ReviewDiff.parse(this.raw) {
    const limit = 20000;
    var shortened = false;
    int? oldLine, newLine;
    for (final text in LineSplitter.split(raw)) {
      if (lines.length == limit) {
        shortened = true;
        break;
      }
      final match = _hunk.firstMatch(text);
      final DiffKind kind;
      int? left, right;
      if (match != null) {
        oldLine = int.tryParse(match[1]!);
        newLine = int.tryParse(match[2]!);
        kind = DiffKind.header;
      } else if (text.startsWith('diff --git ')) {
        oldLine = null;
        newLine = null;
        kind = DiffKind.header;
      } else if (oldLine == null || newLine == null) {
        kind = DiffKind.header;
      } else if (text.startsWith('+')) {
        kind = DiffKind.added;
        right = newLine++;
      } else if (text.startsWith('-')) {
        kind = DiffKind.removed;
        left = oldLine++;
      } else {
        kind = DiffKind.plain;
        if (text.startsWith(' ')) {
          left = oldLine++;
          right = newLine++;
        }
      }
      lines.add((oldLine: left, newLine: right, kind: kind, text: text));
      var columns = 0;
      for (final rune in text.runes) {
        columns += rune == 9
            ? 4
            : rune < 128
            ? 1
            : 2;
      }
      if (columns > widest) widest = columns;
    }
    truncated = shortened;
  }

  static final _hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
  final String raw;
  final lines = <DiffLine>[];
  late final bool truncated;
  int widest = 0;
}
