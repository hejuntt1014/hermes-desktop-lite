part of 'chat.dart';

extension _ChatClipboard on _ChatPageState {
  bool get canPasteImages =>
      widget.keyboardActive &&
      composerStore != null &&
      !busy &&
      !composerBusy &&
      !readOnly;

  Future<void> pasteComposerClipboard({
    bool showEmpty = false,
    VoidCallback? pasteText,
  }) async {
    final before = draft.value;
    final empty = await _pasteImages(readClipboardImages, showEmpty: showEmpty);
    if (empty &&
        mounted &&
        widget.keyboardActive &&
        draftFocus.hasFocus &&
        draft.value == before) {
      pasteText?.call();
    }
  }

  void keyboardPaste() {
    void pasteText() {
      final focus = draftFocus.context;
      if (focus != null) {
        Actions.maybeInvoke(
          focus,
          const PasteTextIntent(SelectionChangedCause.keyboard),
        );
      }
    }

    unawaited(pasteComposerClipboard(pasteText: pasteText));
  }

  Widget composerContextMenu(BuildContext context, EditableTextState editable) {
    if (!canPasteImages) {
      return AdaptiveTextSelectionToolbar.editableText(
        editableTextState: editable,
      );
    }
    final items = [...editable.contextMenuButtonItems];
    final index = items.indexWhere(
      (item) => item.type == ContextMenuButtonType.paste,
    );
    final paste = ContextMenuButtonItem(
      type: ContextMenuButtonType.paste,
      onPressed: () {
        editable.hideToolbar();
        unawaited(
          pasteComposerClipboard(
            pasteText: () {
              if (editable.mounted) {
                editable.pasteText(SelectionChangedCause.toolbar);
              }
            },
          ),
        );
      },
    );
    if (index >= 0) {
      items[index] = paste;
    } else {
      final selectAll = items.indexWhere(
        (item) => item.type == ContextMenuButtonType.selectAll,
      );
      items.insert(selectAll < 0 ? items.length : selectAll, paste);
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editable.contextMenuAnchors,
      buttonItems: items,
    );
  }

  void insertKeyboardImage(KeyboardInsertedContent input) {
    unawaited(
      _pasteImages((directory, limit) async {
        if (limit < 1) throw GatewayError('一次最多发送 10 张图片');
        final bytes = input.data;
        if (bytes == null || bytes.isEmpty) throw GatewayError('无法读取剪贴板图片');
        final file = File('${directory.path}/clipboard-1');
        await file.writeAsBytes(bytes);
        return [await preparePastedImage(file, 'clipboard-1')];
      }),
    );
  }

  Future<bool> _pasteImages(
    Future<List<XFile>> Function(Directory, int) read, {
    bool showEmpty = false,
  }) async {
    if (!canPasteImages) return false;
    updateSlash(() {
      pastingImages = true;
      composerError = null;
    });
    Directory? staging;
    try {
      staging = await (await getTemporaryDirectory()).createTemp(
        'hermes-clipboard-',
      );
      if (!mounted || !widget.keyboardActive) return false;
      final photos = await read(staging, composerPhotoLimit - pictures.length);
      if (!mounted || !widget.keyboardActive || readOnly) return false;
      if (photos.isEmpty) {
        if (showEmpty) updateSlash(() => composerError = '剪贴板中没有图片');
        return true;
      }
      await addComposerInputs(const [], photos);
      return false;
    } catch (error) {
      if (mounted && widget.keyboardActive) {
        updateSlash(() {
          composerError = error is GatewayError ? error.message : '无法读取剪贴板图片';
        });
      }
      return false;
    } finally {
      await staging?.delete(recursive: true).catchError((Object _) => staging!);
      if (mounted) updateSlash(() => pastingImages = false);
    }
  }
}
