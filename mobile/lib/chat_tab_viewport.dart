import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Fills a bounded conversation pane while keeping inactive tabs mounted.
class ChatTabViewport extends MultiChildRenderObjectWidget {
  const ChatTabViewport({
    super.key,
    required this.active,
    required super.children,
  });

  final int? active;

  @override
  RenderChatTabViewport createRenderObject(BuildContext context) =>
      RenderChatTabViewport(active);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderChatTabViewport renderObject,
  ) {
    renderObject.index = active;
  }
}

class RenderChatTabViewport extends RenderIndexedStack {
  RenderChatTabViewport(int? index)
    : super(index: index, fit: StackFit.expand, alignment: Alignment.topLeft);

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    size = constraints.biggest;
    final visibleIndex = index;
    if (visibleIndex == null) return;
    RenderBox? child = firstChild;
    for (var i = 0; i < visibleIndex && child != null; i++) {
      child = childAfter(child);
    }
    child?.layout(BoxConstraints.tight(size));
  }
}
