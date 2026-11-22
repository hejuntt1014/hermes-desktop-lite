import 'dart:async';
import 'dart:convert';

import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import 'markdown_blocks.dart';
import 'workspace.dart';

final _nonSlug = RegExp(r'[^\p{L}\p{N}\p{M}_\- ]+', unicode: true);
final _separators = RegExp(r'[ -]+');
final _edgeSeparators = RegExp(r'^-+|-+$');

String _slug(String text) => unicode
    .nfc(text)
    .toLowerCase()
    .trim()
    .replaceAll(_nonSlug, '')
    .replaceAll(_separators, '-')
    .replaceAll(_edgeSeparators, '');

class DocumentHeading {
  const DocumentHeading._(this.title, this.level, this._base, this._context);

  final String title;
  final int level;
  final String _base;
  final BuildContext _context;
}

typedef DocumentLink = ({String label, String? path, String? fragment});

class DocumentOutline extends ChangeNotifier {
  final _attached = <BuildContext, DocumentHeading>{};
  bool _published = false;
  bool _scheduled = false;
  bool _disposed = false;
  String? _initialFragment;
  String? _linkSource;
  List<DocumentLink> _links = const [];

  bool get hasHeadings => _attached.isNotEmpty;

  List<DocumentLink> linksFor(String source, String? Function(Uri)? resolve) {
    if (source == _linkSource) return _links;
    final links = <(String?, String?), DocumentLink>{};

    void addLink(md.Element element) {
      final image = element.tag == 'img';
      final uri = Uri.tryParse(
        element.attributes[image ? 'src' : 'href'] ?? '',
      );
      if (uri == null) return;
      final fragment = workspaceDocumentFragment(uri);
      final isHeading =
          !image &&
          !uri.hasAuthority &&
          !uri.hasScheme &&
          uri.path.isEmpty &&
          fragment != null;
      String? path;
      if (!isHeading) {
        try {
          path = resolve?.call(uri);
        } on FormatException {
          return;
        } on ArgumentError {
          return;
        }
        if (path == null) return;
      }
      final label =
          (image ? element.attributes['alt'] ?? '' : element.textContent)
              .trim();
      links.putIfAbsent(
        (path, fragment),
        () => (
          label: label.isNotEmpty
              ? label
              : path == null
              ? fragment!
              : workspaceName(path),
          path: path,
          fragment: fragment,
        ),
      );
    }

    void visit(md.Node node) {
      if (node is! md.Element) return;
      if (node.tag == 'a' || node.tag == 'img') addLink(node);
      for (final child in node.children ?? const <md.Node>[]) {
        visit(child);
      }
    }

    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      inlineSyntaxes: messageMarkdownInlineSyntaxes,
      encodeHtml: false,
    );
    for (final node in document.parseLines(
      const LineSplitter().convert(source),
    )) {
      visit(node);
    }
    _linkSource = source;
    return _links = List.unmodifiable(links.values);
  }

  List<DocumentHeading> get headings {
    final positions = <(DocumentHeading, double)>[];
    for (final heading in _attached.values) {
      final anchor = heading._context;
      if (!anchor.mounted) continue;
      final render = anchor.findRenderObject();
      if (render is RenderBox && render.attached && render.hasSize) {
        final top = render.localToGlobal(Offset.zero).dy;
        if (top.isFinite) positions.add((heading, top));
      }
    }
    positions.sort((a, b) => a.$2.compareTo(b.$2));
    return positions.map((entry) => entry.$1).toList(growable: false);
  }

  void _attach(
    BuildContext context,
    String? explicitId,
    String title,
    int level,
  ) {
    if (_disposed) return;
    final base = explicitId == null ? _slug(title) : unicode.nfc(explicitId);
    final prior = _attached[context];
    if (prior?._base == base &&
        prior?.title == title &&
        prior?.level == level) {
      return;
    }
    _attached[context] = DocumentHeading._(title, level, base, context);
    _publish();
  }

  void _detach(BuildContext context) {
    _attached.remove(context);
    _publish();
  }

  void _publish() {
    if (_disposed || _scheduled || hasHeadings == _published) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed || _published == hasHeadings) return;
      _published = hasHeadings;
      notifyListeners();
    });
  }

  Future<void> reveal(DocumentHeading heading, {bool animate = true}) async {
    final anchor = heading._context;
    if (!anchor.mounted || !identical(_attached[anchor], heading)) return;
    await Scrollable.ensureVisible(
      anchor,
      alignment: .04,
      duration: animate && !MediaQuery.disableAnimationsOf(anchor)
          ? const Duration(milliseconds: 210)
          : Duration.zero,
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> jump(String fragment, {bool animate = true}) async {
    final anchors = <String, DocumentHeading>{};
    final counts = <String, int>{};
    for (final heading in headings) {
      final base = heading._base;
      if (base.isEmpty) continue;
      var next = counts[base] ?? 0;
      String id;
      do {
        id = next == 0 ? base : '$base-$next';
        next++;
      } while (anchors.containsKey(id));
      counts[base] = next;
      anchors[id] = heading;
    }
    final target = anchors[unicode.nfc(fragment)] ?? anchors[_slug(fragment)];
    if (target != null) {
      await reveal(target, animate: animate);
    }
  }

  void openFragment(String fragment) {
    if (_initialFragment == fragment) return;
    _initialFragment = fragment;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && _initialFragment == fragment) {
        unawaited(jump(fragment, animate: false));
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _attached.clear();
    super.dispose();
  }
}

class DocumentHeadingAnchor extends StatefulWidget {
  const DocumentHeadingAnchor({
    super.key,
    required this.outline,
    this.explicitId,
    required this.title,
    required this.level,
    required this.child,
  });

  final DocumentOutline outline;
  final String title;
  final String? explicitId;
  final int level;
  final Widget child;

  @override
  State<DocumentHeadingAnchor> createState() => _DocumentHeadingAnchorState();
}

class _DocumentHeadingAnchorState extends State<DocumentHeadingAnchor> {
  void _attach() => widget.outline._attach(
    context,
    widget.explicitId,
    widget.title,
    widget.level,
  );

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(covariant DocumentHeadingAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.outline != widget.outline) oldWidget.outline._detach(context);
    _attach();
  }

  @override
  void dispose() {
    widget.outline._detach(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Semantics(header: true, child: widget.child);
}
