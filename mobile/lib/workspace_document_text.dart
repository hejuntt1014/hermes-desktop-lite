import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, RenderParagraph;
import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'mobile_themes.dart';

class WorkspaceDocumentText extends StatefulWidget {
  const WorkspaceDocumentText({
    super.key,
    required this.text,
    required this.storageKey,
    required this.finding,
    required this.onCloseFind,
  });

  final String text;
  final PageStorageKey<Object> storageKey;
  final bool finding;
  final VoidCallback onCloseFind;

  @override
  State<WorkspaceDocumentText> createState() => _WorkspaceDocumentTextState();
}

class _WorkspaceDocumentTextState extends State<WorkspaceDocumentText> {
  final field = TextEditingController();
  final scroll = ScrollController();
  final paragraphKey = GlobalKey();
  List<TextRange> matches = const [];
  int selected = 0;

  TextRange? get match => matches.isEmpty ? null : matches[selected];

  @override
  void didUpdateWidget(covariant WorkspaceDocumentText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) updateMatches(field.text);
    if (!oldWidget.finding && widget.finding) revealMatch();
  }

  @override
  void dispose() {
    field.dispose();
    scroll.dispose();
    super.dispose();
  }

  void updateMatches(String query) {
    final next = query.isEmpty
        ? const <TextRange>[]
        : RegExp(RegExp.escape(query), caseSensitive: false, unicode: true)
              .allMatches(widget.text)
              .map((match) => TextRange(start: match.start, end: match.end))
              .toList(growable: false);
    setState(() {
      matches = next;
      selected = 0;
    });
    revealMatch();
  }

  void step(int delta) {
    if (matches.isEmpty) return;
    setState(() => selected = (selected + delta) % matches.length);
    revealMatch();
  }

  void revealMatch() {
    final target = match;
    if (target == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !widget.finding ||
          match != target ||
          !scroll.hasClients) {
        return;
      }
      final paragraph = paragraphKey.currentContext?.findRenderObject();
      if (paragraph is! RenderParagraph || !paragraph.hasSize) return;
      final viewport = RenderAbstractViewport.maybeOf(paragraph);
      final box = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: target.start, extentOffset: target.end),
          )
          .firstOrNull;
      if (viewport == null || box == null) return;
      final position = scroll.position;
      final offset = viewport
          .getOffsetToReveal(paragraph, .25, rect: box.toRect())
          .offset
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (MediaQuery.disableAnimationsOf(context)) {
        scroll.jumpTo(offset);
      } else {
        scroll.animateTo(
          offset,
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Widget toolbar(ColorScheme colors) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 10, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: field,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: updateMatches,
                onSubmitted: (_) => step(1),
                decoration: InputDecoration(
                  hintText: context.tr('在文件中查找'),
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                ),
              ),
            ),
            IconButton(
              tooltip: context.tr('关闭'),
              onPressed: widget.onCloseFind,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
          ],
        ),
        if (field.text.isNotEmpty)
          Row(
            children: [
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    matches.isEmpty
                        ? context.tr('没有找到匹配内容')
                        : context.strings.format('第 {value} 项，共 {count} 项匹配', {
                            'value': selected + 1,
                            'count': matches.length,
                          }),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
              ),
              IconButton(
                tooltip: context.tr('上一个匹配'),
                onPressed: matches.length > 1 ? () => step(-1) : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
              ),
              IconButton(
                tooltip: context.tr('下一个匹配'),
                onPressed: matches.length > 1 ? () => step(1) : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
            ],
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = widget.text;
    final hit = widget.finding ? match : null;
    final style = DefaultTextStyle.of(context).style
        .merge(CustomThemeTokens.codeStyle(context))
        .copyWith(color: colors.onSurface, fontSize: 13, height: 1.5);
    return Column(
      children: [
        if (widget.finding) toolbar(colors),
        Expanded(
          child: SelectionArea(
            child: Builder(
              builder: (selectable) => SingleChildScrollView(
                key: widget.storageKey,
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  child: RichText(
                    key: paragraphKey,
                    textScaler: MediaQuery.textScalerOf(selectable),
                    selectionRegistrar: SelectionContainer.maybeOf(selectable),
                    selectionColor:
                        DefaultSelectionStyle.of(selectable).selectionColor ??
                        DefaultSelectionStyle.defaultColor,
                    text: hit == null
                        ? TextSpan(text: text, style: style)
                        : TextSpan(
                            style: style,
                            children: [
                              TextSpan(text: text.substring(0, hit.start)),
                              TextSpan(
                                text: text.substring(hit.start, hit.end),
                                style: TextStyle(
                                  color: colors.onSecondaryContainer,
                                  backgroundColor: colors.secondaryContainer,
                                ),
                              ),
                              TextSpan(text: text.substring(hit.end)),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
