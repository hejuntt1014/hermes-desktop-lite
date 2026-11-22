import 'mobile_locale.dart';
import 'mobile_themes.dart';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';

Map<String, md.LinkReference> markdownReferenceDefinitions(String text) {
  if (!text.contains(']:')) return const {};
  final document = messageMarkdownDocument();
  final lines = text.split('\n').map(md.Line.new).toList();
  md.BlockParser(lines, document).parseLines();
  return document.linkReferences;
}

md.Document messageMarkdownDocument([
  Map<String, md.LinkReference> references = const {},
]) => md.Document(
  extensionSet: md.ExtensionSet.gitHubFlavored,
  inlineSyntaxes: messageMarkdownInlineSyntaxes,
  encodeHtml: false,
)..linkReferences.addAll(references);

final messageMarkdownInlineSyntaxes = <md.InlineSyntax>[_CjkStrongSyntax()];

class _CjkStrongSyntax extends md.EmphasisSyntax {
  _CjkStrongSyntax() : super.asterisk();

  static const _eastAsianLetter =
      r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]';
  static final _eastAsianEnd = RegExp(_eastAsianLetter + r'$', unicode: true);
  static final _eastAsianStart = RegExp('^$_eastAsianLetter', unicode: true);
  static const _punctuation = '。！？…、，；：·「」『』《》〈〉【】〔〕（）“”‘’';
  static final _wordBoundary = md.InlineParser('a*a', md.Document());

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final source = parser.source;
    final start = match.start;
    final end = match.end;
    if (end - start >= 2 && start > 0 && end < source.length) {
      final before = source.substring(start < 2 ? 0 : start - 2, start);
      final after = source.substring(
        end,
        end + 2 > source.length ? source.length : end + 2,
      );
      if ((_punctuation.contains(before[before.length - 1]) &&
              _eastAsianStart.hasMatch(after)) ||
          (_punctuation.contains(after[0]) && _eastAsianEnd.hasMatch(before))) {
        final marker = md.Text(match[0]!);
        // Keep matching on the Markdown delimiter stack with a neutral flank.
        final run = md.DelimiterRun.tryParse(
          _wordBoundary,
          1,
          2,
          syntax: this,
          node: marker,
          allowIntraWord: true,
          tags: tags!,
        );
        if (run != null) {
          parser.pushDelimiter(run);
          parser.addNode(marker);
          return true;
        }
      }
    }
    return super.onMatch(parser, match);
  }
}

// The renderer parses each text section separately around attachment widgets.
// Seed its parser before it expands inline links for that section.
class MessageReferenceSyntax extends md.EmptyBlockSyntax {
  const MessageReferenceSyntax(this.references);

  final Map<String, md.LinkReference> references;

  @override
  md.Node? parse(md.BlockParser parser) {
    if (identical(parser.current, parser.lines.first)) {
      parser.document.linkReferences.addAll(references);
    }
    return super.parse(parser);
  }
}

class MarkdownCodeBuilder extends MarkdownElementBuilder {
  MarkdownCodeBuilder(this.renderProse, {this.streaming = false});
  final Widget Function(String) renderProse;
  final bool streaming;
  int _index = 0;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.children
        ?.whereType<md.Element>()
        .where((node) => node.tag == 'code')
        .firstOrNull;
    if (code == null) return null;
    final raw = code.textContent;
    final text = raw.endsWith('\n') ? raw.substring(0, raw.length - 1) : raw;
    final language = (code.attributes['class'] ?? '')
        .replaceFirst('language-', '')
        .trim();
    final markdown = const {'md', 'markdown'}.contains(language.toLowerCase());
    final preview = markdown && _hasProseMarkup(text) ? renderProse : null;
    return CodeFence(
      key: streaming ? ValueKey(_index++) : ValueKey((language, text)),
      source: text,
      language: language,
      renderProse: preview,
    );
  }
}

bool _hasProseMarkup(String text) {
  final document = messageMarkdownDocument();
  return document.parseLines(text.split('\n')).any(_markupNode);
}

bool _markupNode(md.Node node) =>
    node is md.Element &&
    (const {
          'h1',
          'h2',
          'h3',
          'h4',
          'h5',
          'h6',
          'ol',
          'ul',
          'table',
          'blockquote',
          'strong',
          'em',
          'a',
          'img',
        }.contains(node.tag) ||
        (node.children?.any(_markupNode) ?? false));

class CodeFence extends StatefulWidget {
  const CodeFence({
    super.key,
    required this.source,
    required this.language,
    this.renderProse,
  });

  final String source, language;
  final Widget Function(String)? renderProse;

  @override
  State<CodeFence> createState() => _CodeFenceState();
}

class _CodeFenceState extends State<CodeFence> {
  static const _compactLines = 6;
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  late bool _preview = widget.renderProse != null;
  bool _expanded = false;
  bool _wrapped = false;

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.source));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('已复制代码')),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _code(BuildContext context, List<String> lines, TextStyle? style) {
    final output = (_expanded ? lines : lines.take(_compactLines)).join('\n');
    final text = SelectableText(
      output,
      style: style,
      textDirection: TextDirection.ltr,
    );
    final formatted = _wrapped
        ? Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: text,
          )
        : Scrollbar(
            controller: _horizontal,
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: text,
            ),
          );
    if (!_expanded) return formatted;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: (MediaQuery.sizeOf(context).height * .46).clamp(180, 520),
      ),
      child: Scrollbar(
        controller: _vertical,
        child: SingleChildScrollView(controller: _vertical, child: formatted),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final lines = widget.source.split('\n');
    final caption = widget.language.isEmpty ? context.tr('代码') : widget.language;
    final codeStyle = theme.textTheme.bodySmall
        ?.merge(CustomThemeTokens.codeStyle(context))
        .copyWith(color: colors.onSurface, height: 1.55, letterSpacing: 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              if (widget.renderProse != null)
                TextButton(
                  onPressed: () => setState(() => _preview = !_preview),
                  child: Text(_preview ? context.tr('源码') : context.tr('预览')),
                ),
              if (!_preview)
                IconButton(
                  tooltip: _wrapped
                      ? context.tr('关闭代码换行')
                      : context.tr('代码自动换行'),
                  onPressed: () => setState(() => _wrapped = !_wrapped),
                  icon: Icon(
                    _wrapped
                        ? Icons.align_horizontal_left_rounded
                        : Icons.wrap_text_rounded,
                    size: 19,
                  ),
                ),
              if (!_preview && lines.length > _compactLines)
                Semantics(
                  expanded: _expanded,
                  child: IconButton(
                    tooltip: _expanded
                        ? context.tr('收起代码块')
                        : context.tr('展开代码块'),
                    onPressed: () => setState(() => _expanded = !_expanded),
                    icon: Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 19,
                    ),
                  ),
                ),
              IconButton(
                tooltip: context.tr('复制代码'),
                onPressed: _copy,
                icon: const Icon(Icons.copy_rounded, size: 17),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.outlineVariant),
        if (_preview)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: widget.renderProse!(widget.source),
          )
        else
          _code(context, lines, codeStyle),
      ],
    );
  }
}

class ReadableTableColumnWidth extends IntrinsicColumnWidth {
  const ReadableTableColumnWidth();

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      super.minIntrinsicWidth(cells, containerWidth).clamp(52, 220);

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      super.maxIntrinsicWidth(cells, containerWidth).clamp(52, 220);
}
