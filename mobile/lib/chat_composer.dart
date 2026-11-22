part of 'chat.dart';

typedef _ComposerUpload = ({
  String filename,
  int index,
  int count,
  UploadProgress progress,
});

class _ComposerUploadStatus extends StatelessWidget {
  const _ComposerUploadStatus({
    required this.update,
    required this.cancelling,
    required this.onCancel,
  });

  final _ComposerUpload update;
  final bool cancelling;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = update.progress;
    final label = context.tr(
      cancelling
          ? '正在取消…'
          : switch (progress.phase) {
              UploadPhase.preparing => '正在准备附件',
              UploadPhase.sending => '正在上传附件',
              UploadPhase.confirming => '等待网关确认',
            },
    );
    final total = progress.total;
    final sent = progress.sent;
    final fraction = sent == null || total == null || total == 0
        ? null
        : (sent / total).clamp(0.0, 1.0).toDouble();
    final filename = update.count == 1
        ? update.filename
        : '${update.index}/${update.count} · ${update.filename}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(9, 5, 9, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.labelMedium)),
              if (sent != null && total != null)
                Text(
                  progress.phase == UploadPhase.confirming
                      ? formatTransferSize(total)
                      : '${formatTransferSize(sent)} / ${formatTransferSize(total)}',
                  style: theme.textTheme.labelSmall,
                ),
              IconButton(
                tooltip: context.tr('取消上传'),
                onPressed: cancelling ? null : onCancel,
                icon: const Icon(Icons.close_rounded, size: 19),
              ),
            ],
          ),
          Text(
            filename,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 5),
          LinearProgressIndicator(
            value: fraction,
            minHeight: 3,
            borderRadius: BorderRadius.circular(4),
            semanticsLabel: label,
          ),
        ],
      ),
    );
  }
}

bool _composing(TextEditingValue value) =>
    value.isComposingRangeValid && !value.composing.isCollapsed;

extension _ChatComposer on _ChatPageState {
  FileTransferControl? beginUpload(List<XFile> documents, List<XFile> photos) {
    final first = documents.firstOrNull ?? photos.firstOrNull;
    if (first == null) return null;
    final control = uploadControl = FileTransferControl();
    reportUpload(first, 1, documents.length + photos.length)(preparingUpload);
    return control;
  }

  void endUpload(FileTransferControl? control) {
    if (control == null || !mounted || !identical(uploadControl, control)) {
      return;
    }
    uploadControl = null;
    uploadProgress.value = null;
  }

  void cancelUpload() {
    final control = uploadControl;
    if (control == null || control.cancelled) return;
    updateSlash(control.cancel);
  }

  UploadProgressCallback reportUpload(
    XFile file,
    int index,
    int count, {
    bool Function()? current,
  }) {
    final filename = attachmentName(file);
    return (progress) {
      if (mounted &&
          uploadControl?.cancelled != true &&
          (current?.call() ?? true)) {
        uploadProgress.value = (
          filename: filename,
          index: index,
          count: count,
          progress: progress,
        );
      }
    };
  }

  Future<void> addDroppedFiles(List<XFile> selected) async {
    if (selected.isEmpty) return;
    try {
      await addComposerFiles(selected);
    } catch (error) {
      if (mounted)
        updateSlash(
          () => composerError = error is GatewayError
              ? error.message
              : '无法保存草稿附件',
        );
    }
  }

  Future<void> addComposerFiles(List<XFile> selected) async {
    final documents = <XFile>[];
    final photos = <XFile>[];
    final paths = <String>{};
    for (final file in selected) {
      if (file.path.isNotEmpty && !paths.add(file.path)) continue;
      final image = await isComposerPhoto(file);
      if (!mounted) return;
      (image ? photos : documents).add(file);
    }
    if (documents.isNotEmpty || photos.isNotEmpty) {
      await addComposerInputs(documents, photos);
    }
  }

  Future<void> pickComposerFiles() async {
    updateSlash(() => pickingAttachments = true);
    try {
      final selected = await openFiles();
      if (mounted) await addComposerFiles(selected);
    } finally {
      if (mounted) updateSlash(() => pickingAttachments = false);
    }
  }

  KeyEventResult handleComposerKey(FocusNode node, KeyEvent event) {
    if (!widget.keyboardActive || _composing(draft.value)) {
      return KeyEventResult.ignored;
    }
    final hasChoices = references.hasChoices;
    final actions = <ShortcutActivator, VoidCallback>{
      ...MobileShortcut.bind({
        MobileShortcut.send: send,
        MobileShortcut.composerEnter: hasChoices ? references.choose : send,
        MobileShortcut.composerNewline: insertDraftNewline,
        if (references.visible) MobileShortcut.dismiss: references.dismiss,
        if (canPasteImages) MobileShortcut.composerPaste: keyboardPaste,
        if (hasChoices) ...{
          MobileShortcut.nextChoice: () => references.move(previous: false),
          MobileShortcut.previousChoice: () => references.move(previous: true),
        },
      }),
      if (hasChoices)
        const SingleActivator(LogicalKeyboardKey.tab, includeRepeats: false):
            references.choose,
      if (canPasteImages)
        const SingleActivator(LogicalKeyboardKey.paste, includeRepeats: false):
            keyboardPaste,
    };
    final keyboard = HardwareKeyboard.instance;
    for (final action in actions.entries) {
      if (action.key.accepts(event, keyboard)) {
        action.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  bool get canRemoveDraftAttachments => !busy && !composerBusy && !copyingDraft;

  Future<void> openComposerPicture(XFile current) async {
    draftFocus.unfocus();
    await openImageGallery(
      context,
      scope: WorkspaceScope(widget.gateway, widget.profile),
      images: pictures.map(GalleryImage.local),
      selected: GalleryImage.local(current),
    );
    if (mounted) restoreChatKeyboard();
  }

  Future<void> openComposerFile(XFile file, BuildContext anchor) async {
    final origin = fileShareOrigin(anchor);
    draftFocus.unfocus();
    final action = await showModalBottomSheet<_DraftFileAction>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  file.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: Text(sheet.tr('保存')),
                onTap: () => Navigator.pop(sheet, _DraftFileAction.save),
              ),
              ListTile(
                leading: const Icon(Icons.ios_share_outlined),
                title: Text(sheet.tr('分享文件')),
                onTap: () => Navigator.pop(sheet, _DraftFileAction.share),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    try {
      if (action == null || !files.contains(file)) return;
      final exported = await exportLocalAttachment(
        file,
        fallbackName: context.tr('附件'),
        stillOpen: () => mounted && widget.keyboardActive,
        shareOrigin: action == _DraftFileAction.share ? origin : null,
      );
      if (mounted && exported && action == _DraftFileAction.save) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('文件已保存'))));
      }
    } catch (failure) {
      if (mounted) {
        final message = failure is GatewayError ? failure.message : '无法读取草稿附件';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr(message))));
      }
    } finally {
      if (mounted) restoreChatKeyboard();
    }
  }

  Widget buildComposerPictures() => SizedBox(
    height: 99,
    child: ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 5),
      primary: false,
      scrollDirection: Axis.horizontal,
      itemCount: pictures.length,
      separatorBuilder: (_, _) => const SizedBox(width: 7),
      itemBuilder: (context, index) {
        final image = pictures[index];
        final enabled = canRemoveDraftAttachments;
        final preview = enabled ? () => openComposerPicture(image) : null;
        return SizedBox(
          key: ValueKey(image.path),
          width: 98,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Semantics(
                  button: true,
                  enabled: enabled,
                  label: context.strings.format('查看原图 · {alt}', {
                    'alt': image.name,
                  }),
                  onTap: preview,
                  child: GestureDetector(
                    excludeFromSemantics: true,
                    onTap: preview,
                    child: Image.file(
                      File(image.path),
                      excludeFromSemantics: true,
                      fit: BoxFit.cover,
                      cacheWidth: 256,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.image_outlined),
                    ),
                  ),
                ),
              ),
              PositionedDirectional(
                top: 3,
                end: 3,
                child: IconButton.filled(
                  tooltip: context.tr('移除图片'),
                  onPressed: enabled
                      ? () => removeSelectedComposerFile(image, photo: true)
                      : null,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(32, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: EdgeInsets.zero,
                  ),
                  icon: const Icon(Icons.close, size: 17),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
  List<ComposerAttachment> composerReferences(
    List<XFile> documents,
    List<XFile> photos,
  ) => [
    for (final file in documents.whereType<ComposerFile>()) file.attachment,
    for (final image in photos.whereType<ComposerFile>()) image.attachment,
  ];

  List<String> composerInputIds(List<XFile> documents, List<XFile> photos) => [
    for (final file in [...documents, ...photos])
      file is ComposerFile ? file.attachment.id : '',
  ];

  PhotoDraftTarget? get photoDraftTarget {
    final tab = widget.composerTab;
    if (!Platform.isAndroid ||
        tab == null ||
        widget.onDraftAttachments == null) {
      return null;
    }
    return (
      gateway: widget.gateway.base.toString(),
      profile: widget.profile,
      tab: tab.id,
    );
  }

  Future<void> pickComposerPhotos({required bool camera}) async {
    final available = composerPhotoLimit - pictures.length;
    if (available <= 0) throw GatewayError('一次最多发送 10 张图片');
    final picker = ImagePicker();
    final source = camera ? ImageSource.camera : ImageSource.gallery;
    final limit = camera ? 1 : available;
    Future<List<XFile>> select() async {
      try {
        return limit == 1
            ? [
                ?await picker.pickImage(
                  source: source,
                  requestFullMetadata: false,
                ),
              ]
            : await picker.pickMultiImage(
                limit: limit,
                requestFullMetadata: false,
              );
      } on PlatformException {
        throw GatewayError(camera ? '无法打开相机' : '无法打开相册');
      }
    }

    updateSlash(() => pickingAttachments = true);
    try {
      if (photoDraftTarget case final target?) {
        final store = composerStore!;
        final persist = widget.onDraftAttachments!;
        await widget.onFlushDraft?.call();
        if (!mounted) return;
        final batch = await AndroidDraftPhotos.shared.pick(
          target,
          limit,
          select,
        );
        if (batch == null || !mounted) return;
        await writeComposer(() async {
          final existing = composerReferences(files, pictures);
          final ids = existing.map((entry) => entry.id).toSet();
          final additions = batch.attachments
              .where((entry) => ids.add(entry.id))
              .toList();
          final photoCount = additions.where((entry) => entry.photo).length;
          if (pictures.length + photoCount > composerPhotoLimit) {
            throw GatewayError('一次最多发送 10 张图片');
          }
          final copies = await Future.wait(additions.map(store.source));
          if (!mounted || !await persist([...existing, ...additions])) return;
          if (mounted) {
            updateSlash(() {
              for (final input in copies) {
                (input.attachment.photo ? pictures : files).add(input);
              }
            });
          }
          await AndroidDraftPhotos.shared
              .acknowledge([batch])
              .catchError((Object _) {});
        });
      } else {
        final selected = await select();
        if (!mounted || selected.isEmpty) return;
        await addComposerFiles(selected);
      }
    } finally {
      if (mounted) updateSlash(() => pickingAttachments = false);
    }
  }

  Future<List<ComposerAttachment>> recoverPickedPhotos(
    ComposerAttachmentStore store,
    List<ComposerAttachment> attachments,
  ) async {
    final target = photoDraftTarget;
    if (target == null) return attachments;
    final pending = await AndroidDraftPhotos.shared.forDraft(target);
    if (!mounted || pending.isEmpty) return attachments;
    final next = [...attachments];
    final ids = next.map((input) => input.id).toSet();
    var remaining =
        composerPhotoLimit - next.where((entry) => entry.photo).length;
    final handled = <PickedDraftPhotos>[];
    var missing = false;
    for (final batch in pending) {
      final additions = <ComposerAttachment>[];
      for (final entry in batch.attachments) {
        if (ids.contains(entry.id)) continue;
        final file = await store.source(entry);
        if (await File(file.path).exists()) {
          additions.add(entry);
        } else {
          missing = true;
        }
      }
      final photoCount = additions.where((entry) => entry.photo).length;
      if (photoCount > remaining) continue;
      ids.addAll(additions.map((entry) => entry.id));
      next.addAll(additions);
      remaining -= photoCount;
      handled.add(batch);
    }
    if (!mounted) return attachments;
    if (next.length != attachments.length &&
        !await widget.onDraftAttachments!(next)) {
      return attachments;
    }
    await AndroidDraftPhotos.shared
        .acknowledge(handled)
        .catchError((Object _) {});
    if (missing && mounted) updateSlash(() => composerError = '部分草稿附件已无法读取');
    return next;
  }

  Future<void> restoreComposer() async {
    final store = composerStore;
    final existing = widget.composerTab?.attachments;
    if (store == null || existing == null) return;
    try {
      var attachments = existing;
      try {
        attachments = await recoverPickedPhotos(store, existing);
      } catch (_) {
        if (mounted) updateSlash(() => composerError = '无法恢复选中的照片');
      }
      final inputs = await Future.wait(attachments.map(store.source));
      if (!mounted) return;
      var missing = false;
      for (final input in inputs) {
        if (!await File(input.path).exists()) missing = true;
      }
      if (!mounted) return;
      updateSlash(() {
        for (final input in inputs) {
          if (input.attachment.photo) {
            pictures.add(input);
          } else {
            files.add(input);
          }
        }
        if (missing) composerError = '部分草稿附件已无法读取';
      });
    } catch (_) {
      if (mounted) updateSlash(() => composerError = '无法读取草稿附件');
    } finally {
      if (mounted) updateSlash(() => restoringComposer = false);
    }
  }

  Future<void> writeComposer(Future<void> Function() action) {
    final tab = widget.composerTab;
    final previous = composerWrite;
    final job = (previous ?? composerRestore).then((_) async {
      if (mounted) await action();
    });
    final settled = job.then<void>((_) {}, onError: (Object _) {});
    composerWrite = settled;
    if (tab != null) tab.attachmentWrite = settled;
    updateSlash(() {});
    unawaited(
      settled.whenComplete(() {
        if (identical(composerWrite, settled)) {
          composerWrite = null;
          if (mounted) updateSlash(() {});
        }
        if (identical(tab?.attachmentWrite, settled)) {
          tab!.attachmentWrite = null;
        }
      }),
    );
    return job;
  }

  Future<void> commitComposer(List<XFile> documents, List<XFile> photos) async {
    final before = composerReferences(files, pictures);
    final next = composerReferences(documents, photos);
    final nextIds = next.map((item) => item.id).toSet();
    final beforeIds = before.map((item) => item.id).toSet();
    final persist = widget.onDraftAttachments;
    Object? failure;
    if (persist != null) {
      try {
        if (!await persist(next)) {
          await composerStore?.remove(
            next.where((item) => !beforeIds.contains(item.id)),
          );
          return;
        }
      } catch (error) {
        failure = error;
      }
    }
    if (mounted) {
      updateSlash(() {
        files
          ..clear()
          ..addAll(documents);
        pictures
          ..clear()
          ..addAll(photos);
        composerError = failure == null ? null : '无法保存草稿附件';
      });
    }
    // Keep prior inputs until the replacement manifest is on disk.
    if (failure != null) throw failure;
    await composerStore?.remove(
      before.where((item) => !nextIds.contains(item.id)),
    );
  }

  Future<void> addComposerInputs(
    List<XFile> documents,
    List<XFile> photos, {
    List<String> identities = const [],
  }) => writeComposer(() async {
    final store = composerStore;
    final imported = <ComposerAttachment>[];
    Future<XFile> stage(XFile file, int index, {required bool image}) async {
      if (store == null) return file;
      final copy = await store.import(
        file,
        photo: image,
        originalId: index < identities.length ? identities[index] : null,
      );
      imported.add(copy.attachment);
      return copy;
    }

    final replacing = identities.where((id) => id.isNotEmpty).toSet();
    bool replaced(XFile file) =>
        file is ComposerFile && replacing.contains(file.attachment.id);
    final next = files.where((file) => !replaced(file)).toList();
    final images = pictures.where((file) => !replaced(file)).toList();
    if (images.length + photos.length > composerPhotoLimit) {
      throw GatewayError('一次最多发送 10 张图片');
    }
    try {
      for (final (index, file) in documents.indexed) {
        next.add(await stage(file, index, image: false));
      }
      for (final (index, photo) in photos.indexed) {
        images.add(await stage(photo, documents.length + index, image: true));
      }
    } catch (_) {
      await store?.remove(imported);
      rethrow;
    }
    if (!mounted) {
      await store?.remove(imported);
      return;
    }
    await commitComposer(next, images);
  });

  Future<void> removeComposerInputs(
    Iterable<String> retainedIds, {
    List<XFile> documents = const [],
    List<XFile> photos = const [],
  }) async {
    final ids = retainedIds.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty && documents.isEmpty && photos.isEmpty) return;
    await writeComposer(() async {
      bool matches(XFile file) =>
          file is ComposerFile && ids.contains(file.attachment.id);
      final remaining = files
          .where((file) => !matches(file) && !documents.contains(file))
          .toList();
      final images = pictures
          .where((file) => !matches(file) && !photos.contains(file))
          .toList();
      if (remaining.length == files.length &&
          images.length == pictures.length) {
        return;
      }
      await commitComposer(remaining, images);
    });
  }

  Future<void> removeSelectedComposerFile(
    XFile input, {
    required bool photo,
  }) async {
    if (!canRemoveDraftAttachments) return;
    await clearSubmittedComposer(
      const [],
      documents: photo ? const [] : [input],
      photos: photo ? [input] : const [],
    );
  }

  Future<void> clearSubmittedComposer(
    Iterable<String> ids, {
    List<XFile> documents = const [],
    List<XFile> photos = const [],
  }) async {
    try {
      await removeComposerInputs(ids, documents: documents, photos: photos);
    } catch (_) {
      if (mounted) updateSlash(() => composerError = '无法保存草稿附件');
    }
  }
}

enum _DraftFileAction { save, share }

enum _WorkspaceAction { browse, review, copy }

class _ComposerWorkspaceBar extends StatelessWidget {
  const _ComposerWorkspaceBar({
    required this.path,
    required this.branch,
    required this.onBrowse,
    required this.onReview,
  });

  final String path;
  final String? branch;
  final VoidCallback? onBrowse, onReview;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelMedium;
    void copy() => unawaited(copyMobileText(context, path, '已复制远程路径'));
    final review = branch == null ? null : onReview;
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 0, 3, 2),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: review ?? onBrowse,
              onLongPress: copy,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 34),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  child: Row(
                    children: [
                      Icon(
                        branch == null
                            ? Icons.folder_open_outlined
                            : Icons.account_tree_outlined,
                        color: colors.onSurfaceVariant,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      if (branch case final name?) ...[
                        Flexible(
                          child: Text(
                            name,
                            style: style?.copyWith(color: colors.onSurface),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 7),
                          child: Text(
                            '·',
                            style: style?.copyWith(color: colors.outline),
                          ),
                        ),
                      ],
                      Expanded(
                        flex: 2,
                        child: Text(
                          path,
                          style: style?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 34,
            child: PopupMenuButton<_WorkspaceAction>(
              tooltip: context.tr('工作区操作'),
              position: PopupMenuPosition.under,
              icon: const Icon(Icons.more_horiz_rounded, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 180, maxWidth: 288),
              onSelected: (action) => switch (action) {
                _WorkspaceAction.browse => onBrowse?.call(),
                _WorkspaceAction.review => review?.call(),
                _WorkspaceAction.copy => copy(),
              },
              itemBuilder: (context) => [
                for (final (action, label, enabled) in [
                  (_WorkspaceAction.browse, '浏览工作区文件', onBrowse != null),
                  (_WorkspaceAction.review, '审查工作区变更', review != null),
                  (_WorkspaceAction.copy, '复制工作区路径', true),
                ])
                  PopupMenuItem(
                    value: action,
                    enabled: enabled,
                    child: Text(context.tr(label)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
