import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/gateway.dart';
import 'package:hermes_mobile/workspace.dart';
import 'package:hermes_mobile/workspace_view.dart';
import 'package:material_ui/material_ui.dart';

const sampleDiff =
    'diff --git a/docs/guide.md b/docs/guide.md\n'
    '--- a/docs/guide.md\n'
    '+++ b/docs/guide.md\n'
    '@@ -2,2 +8,2 @@\n'
    ' preserved\n'
    '-before\n'
    '+after\n'
    '\\ No newline at end of file\n';

class _WorkspaceGateway extends Gateway {
  _WorkspaceGateway() : super('https://localhost', '');
  final requests = <({String path, Map<String, String> query})>[];

  @override
  Future<Json> api(
    String path, {
    Map<String, String>? query,
    Json? body,
    String? method,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((path: path, query: query ?? {}));
    return switch (path) {
      'api/fs/default-cwd' => {'cwd': '/profile/default'},
      'api/fs/list' when query?['path'] == '/scratch/project' => {
        'entries': [
          {'name': 'notes.txt', 'path': '/scratch/project/notes.txt'},
          {
            'name': 'docs',
            'path': '/scratch/project/docs',
            'isDirectory': true,
          },
        ],
      },
      'api/fs/list' => {
        'entries': [
          {'name': 'guide.md', 'path': '/scratch/project/docs/guide.md'},
        ],
      },
      'api/fs/read-text' => {'text': '# Project guide', 'language': 'markdown'},
      'api/fs/git-root' => {'root': '/scratch/project'},
      'api/git/review/rev-parse' => {'sha': 'a' * 40},
      'api/git/review/list' => {
        'files': [
          {'path': 'docs/guide.md', 'status': 'M', 'added': 1, 'removed': 1},
        ],
        'base': ?query?['base'],
      },
      'api/git/file-diff' || 'api/git/review/diff' => {'diff': sampleDiff},
      _ => throw StateError(path),
    };
  }
}

void main() {
  test('review routes previous version through the resolved parent and preserves numbers', () async {
    final gateway = _WorkspaceGateway();
    addTearDown(gateway.close);
    final scope = WorkspaceScope(gateway, 'work', session: 'stored');
    final review = await ReviewListing.load(scope, ReviewMode.previous);
    final diff = await review.diff(scope, review.files.single);
    expect(gateway.requests.map((r) => r.path), [
      'api/fs/default-cwd',
      'api/fs/git-root',
      'api/git/review/rev-parse',
      'api/git/review/list',
      'api/git/review/diff',
    ]);
    expect(gateway.requests[2].query, {
      'path': '/scratch/project',
      'ref': 'HEAD~1',
      'profile': 'work',
    });
    expect(gateway.requests.last.query, {
      'path': '/scratch/project',
      'scope': 'lastTurn',
      'base': 'a' * 40,
      'file': 'docs/guide.md',
      'profile': 'work',
    });
    expect(diff.lines[4], (
      oldLine: 2,
      newLine: 8,
      kind: DiffKind.plain,
      text: ' preserved',
    ));
    expect(diff.lines[5].oldLine, 3);
    expect(diff.lines[6].newLine, 9);
    expect(diff.lines.last.newLine, isNull);
  });

  testWidgets(
    'workspace retains folders across tabs and previews session-scoped files',
    (tester) async {
      final gateway = _WorkspaceGateway();
      addTearDown(gateway.close);
      final scope = WorkspaceScope(
        gateway,
        'work',
        session: 'stored',
        cwd: '/scratch/project',
      );
      await tester.pumpWidget(MaterialApp(home: WorkspacePage(scope: scope)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('docs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('guide.md'));
      await tester.pumpAndSettle();
      expect(find.text('Project guide'), findsOneWidget);
      expect(gateway.requests.last.query, {
        'path': '/scratch/project/docs/guide.md',
        'session_id': 'stored',
        'profile': 'work',
      });
      await tester.tap(find.text('源文件'));
      await tester.pumpAndSettle();
      expect(find.text('# Project guide'), findsOneWidget);
      Navigator.of(tester.element(find.byType(AppBar).last)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('改动审查'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('guide.md'));
      await tester.pumpAndSettle();
      // Leading +/- signs are retained in the displayed unified diff.
      expect(find.text('+after'), findsOneWidget);
      expect(gateway.requests.last.path, 'api/git/file-diff');
      Navigator.of(tester.element(find.byType(AppBar).last)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('文件'));
      await tester.pumpAndSettle();
      expect(find.text('guide.md'), findsOneWidget);
      expect(find.text('notes.txt'), findsNothing);
      expect(
        gateway.requests.any((r) => r.path == 'api/fs/default-cwd'),
        isFalse,
      );
    },
  );
}
