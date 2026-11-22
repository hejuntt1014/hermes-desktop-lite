import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'mobile_shortcuts.dart';
import 'attachment_view.dart';
import 'gateway.dart';
import 'image_format.dart';
import 'workspace.dart';

class GalleryImage {
  const GalleryImage.path(String path, {this.alt, Object? key})
    : key = key ?? path,
      _path = path,
      _resolve = null,
      _local = null;

  const GalleryImage.deferred(
    this.key,
    Future<String> Function() this._resolve, {
    this.alt,
  }) : _path = null,
       _local = null;

  GalleryImage.local(XFile file)
    : key = file.path,
      alt = file.name,
      _path = null,
      _resolve = null,
      _local = file;

  final Object key;
  final String? alt, _path;
  final Future<String> Function()? _resolve;
  final XFile? _local;

  Future<String> path() async => _local?.path ?? _path ?? await _resolve!();
}

typedef LoadedGalleryImage = ({String path, Uint8List bytes});

String imagePreviewError(Object? error) =>
    error is GatewayError && error.status == 413 ? '原图过大，无法预览' : '无法预览图片';

Future<LoadedGalleryImage> loadGalleryImage(
  WorkspaceScope scope,
  GalleryImage image, {
  FileTransferControl? control,
}) async => _loadGalleryPath(
  scope,
  workspaceFilePath(await image.path(), scope.cwd),
  control: control,
);

Future<LoadedGalleryImage> _loadGalleryPath(
  WorkspaceScope scope,
  String path, {
  FileTransferControl? control,
}) async {
  control?.throwIfCancelled();
  final result = path.startsWith('data:image/')
      ? path
      : (await scope.get('api/fs/read-data-url', {
          'path': path,
        }, true, control))['dataUrl'];
  if (result is! String || !result.startsWith('data:image/')) {
    throw GatewayError('网关未返回可读取的图片');
  }
  control?.throwIfCancelled();
  final bytes = await decodeInlineImage(result);
  control?.throwIfCancelled();
  return (path: path, bytes: bytes);
}

Future<void> exportRemoteGalleryImage(
  BuildContext context,
  WorkspaceScope scope, {
  required String path,
  required bool Function() stillOpen,
  LoadedGalleryImage? preview,
  Rect? shareOrigin,
}) async {
  if (shareOrigin != null) {
    await shareRemoteFile(
      context,
      scope.gateway,
      path: path,
      profile: scope.profile,
      session: scope.session,
      original: preview?.bytes,
      origin: shareOrigin,
      stillOpen: stillOpen,
    );
    return;
  }
  final saved = await saveRemoteFile(
    context,
    scope.gateway,
    path: path,
    profile: scope.profile,
    session: scope.session,
    original: preview?.bytes,
    stillOpen: stillOpen,
  );
  if (saved && context.mounted && stillOpen()) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.tr('图片已保存'))));
  }
}

Future<void> openImageGallery(
  BuildContext context, {
  required WorkspaceScope scope,
  required Iterable<GalleryImage> images,
  required GalleryImage selected,
  LoadedGalleryImage? initialPreview,
  ValueChanged<WorkspaceEntry>? onReference,
}) async {
  final items = <Object, GalleryImage>{};
  for (final image in images) {
    items.putIfAbsent(image.key, () => image);
  }
  if (selected.alt?.isNotEmpty == true) items[selected.key] = selected;
  items.putIfAbsent(selected.key, () => selected);
  final gallery = items.values.toList(growable: false);
  final index = gallery.indexWhere((image) => image.key == selected.key);
  final entry = await Navigator.of(context).push<WorkspaceEntry>(
    MaterialPageRoute(
      builder: (_) => _ImageGallery(
        scope: scope,
        images: gallery,
        start: index,
        initialPreview: initialPreview,
        allowReference: onReference != null,
      ),
    ),
  );
  if (context.mounted && entry != null) onReference?.call(entry);
}

class _ImageGallery extends StatefulWidget {
  const _ImageGallery({
    required this.scope,
    required this.images,
    required this.start,
    required this.allowReference,
    this.initialPreview,
  });
  final WorkspaceScope scope;
  final List<GalleryImage> images;
  final int start;
  final bool allowReference;
  final LoadedGalleryImage? initialPreview;

  @override
  State<_ImageGallery> createState() => _ImageGalleryState();
}

class _ImageGalleryState extends State<_ImageGallery> {
  final _pending = <
    int,
    ({Future<LoadedGalleryImage> image, FileTransferControl? control})
  >{};
  final _paths = <int, Future<String>>{};
  late final _pages = PageController(initialPage: widget.start);
  late int _current = widget.start;
  bool _saving = false, _zoomed = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialPreview case final initial?) {
      _pending[widget.start] = (image: Future.value(initial), control: null);
    }
  }

  @override
  void dispose() {
    for (final preview in _pending.values) {
      preview.control?.cancel();
    }
    _pages.dispose();
    super.dispose();
  }

  Future<String> _path(int page) => _paths.putIfAbsent(page, () async {
    final source = widget.images[page];
    if (source._local case final file?) return file.path;
    final path = await source.path();
    return workspaceFilePath(path, widget.scope.cwd);
  });

  Future<LoadedGalleryImage> _load(int page) => _pending.putIfAbsent(page, () {
    final control = FileTransferControl();
    final image = _path(page).then(
      (path) => _loadGalleryPath(widget.scope, path, control: control),
    );
    return (image: image, control: control);
  }).image;

  void _discard(int index) {
    _pending.remove(index)?.control?.cancel();
    _paths.remove(index);
  }

  void _move(int step) {
    final index = _current + step;
    if (!_pages.hasClients || index < 0 || index >= widget.images.length) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(
        index,
        duration: const Duration(milliseconds: 190),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _export(
    String path,
    LoadedGalleryImage? preview, {
    Rect? shareOrigin,
  }) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (widget.images[_current]._local case final file?) {
        final saved = await exportLocalAttachment(
          file,
          fallbackName: context.tr('图片'),
          stillOpen: () => mounted,
          shareOrigin: shareOrigin,
        );
        if (shareOrigin == null && saved && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(context.tr('图片已保存'))));
        }
      } else {
        await exportRemoteGalleryImage(
          context,
          widget.scope,
          path: path,
          preview: preview,
          shareOrigin: shareOrigin,
          stillOpen: () => mounted,
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr(error.toString()))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _actions() => FutureBuilder<String>(
    key: ValueKey(_current),
    future: _path(_current),
    builder: (context, destination) {
      final source = widget.images[_current];
      final resolved = destination.connectionState == ConnectionState.done
          ? destination.data
          : null;
      final local = source._local;
      final known = source._path;
      final path =
          resolved ??
          local?.path ??
          (known == null ? null : workspaceFilePath(known, widget.scope.cwd));
      final remotePath =
          local == null && path != null && !path.startsWith('data:')
          ? path
          : null;
      return FutureBuilder<LoadedGalleryImage>(
        future: local == null ? _load(_current) : null,
        builder: (context, snapshot) {
          final preview = snapshot.connectionState == ConnectionState.done
              ? snapshot.data
              : null;
          final reference = preview?.path ?? path;
          final exportPath =
              !_saving &&
                  (local != null || remotePath != null || preview != null)
              ? reference
              : null;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.allowReference && remotePath != null)
                IconButton(
                  tooltip: context.tr('引用到草稿'),
                  onPressed: _saving
                      ? null
                      : () => Navigator.pop(
                          context,
                          WorkspaceEntry(workspaceName(remotePath), remotePath),
                        ),
                  icon: const Icon(Icons.add_comment_outlined, size: 20),
                ),
              Builder(
                builder: (anchor) => IconButton(
                  tooltip: context.tr('分享原图'),
                  onPressed: exportPath == null
                      ? null
                      : () => _export(
                          exportPath,
                          preview,
                          shareOrigin: fileShareOrigin(anchor),
                        ),
                  icon: const Icon(Icons.ios_share_outlined),
                ),
              ),
              IconButton(
                tooltip: context.tr('保存原图'),
                onPressed: exportPath == null
                    ? null
                    : () => _export(exportPath, preview),
                icon: const Icon(Icons.download_outlined),
              ),
            ],
          );
        },
      );
    },
  );

  Widget _zoomableImage(int index, ImageProvider image) => _ZoomImage(
    key: ValueKey(index),
    image: image,
    alt: widget.images[index].alt,
    active: _current == index,
    onZoom: (zoomed) {
      if (_current == index && _zoomed != zoomed) {
        setState(() => _zoomed = zoomed);
      }
    },
  );

  @override
  Widget build(BuildContext context) {
    final count = widget.images.length;
    final colors = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: MobileShortcut.bind({
        MobileShortcut.dismiss: () => Navigator.of(context).maybePop(),
        if (_current > 0) MobileShortcut.previousImage: () => _move(-1),
        if (_current + 1 < count) MobileShortcut.nextImage: () => _move(1),
      }),
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        child: Scaffold(
          backgroundColor: colors.surface,
          appBar: AppBar(
            title: count == 1
                ? Text(context.tr('原图'))
                : Semantics(
                    label: context.strings.format(
                      '原图，第 {value} 张，共 {count} 张',
                      {"value": _current + 1, "count": count},
                    ),
                    excludeSemantics: true,
                    child: Text(
                      '${_current + 1} / $count',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
            actions: [_actions()],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _pages,
                    physics: _zoomed
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    itemCount: count,
                    onPageChanged: (page) => setState(() {
                      for (final index in _paths.keys.toList()) {
                        if ((index - page).abs() > 1) _discard(index);
                      }
                      _current = page;
                      _zoomed = false;
                    }),
                    itemBuilder: (context, index) {
                      if (widget.images[index]._local case final file?) {
                        return _zoomableImage(
                          index,
                          FileImage(File(file.path)),
                        );
                      }
                      return FutureBuilder(
                        future: _load(index),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final decoded = snapshot.data;
                          if (decoded == null) {
                            return Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    context.tr(
                                      imagePreviewError(snapshot.error),
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => setState(() => _discard(index)),
                                    icon: const Icon(Icons.refresh_rounded),
                                    label: Text(context.tr('重新加载图片')),
                                  ),
                                ],
                              ),
                            );
                          }
                          return _zoomableImage(
                            index,
                            MemoryImage(decoded.bytes),
                          );
                        },
                      );
                    },
                  ),
                ),
                if (count > 1)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: context.tr('上一张'),
                          onPressed: _current == 0 ? null : () => _move(-1),
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                        Expanded(
                          child: FutureBuilder<String>(
                            key: ValueKey(_current),
                            future: _path(_current),
                            builder: (context, snapshot) {
                              final path =
                                  snapshot.data ??
                                  widget.images[_current]._path;
                              final label =
                                  widget.images[_current].alt ??
                                  (path == null ||
                                          path.startsWith('data:image/')
                                      ? ''
                                      : workspaceName(path));
                              return Text(
                                label,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              );
                            },
                          ),
                        ),
                        IconButton(
                          tooltip: context.tr('下一张'),
                          onPressed: _current + 1 == count
                              ? null
                              : () => _move(1),
                          icon: const Icon(Icons.chevron_right_rounded),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomImage extends StatefulWidget {
  const _ZoomImage({
    super.key,
    required this.image,
    this.alt,
    required this.active,
    required this.onZoom,
  });
  final ImageProvider image;
  final String? alt;
  final bool active;
  final ValueChanged<bool> onZoom;

  @override
  State<_ZoomImage> createState() => _ZoomImageState();
}

class _ZoomImageState extends State<_ZoomImage> {
  final _transform = TransformationController();
  Offset _tap = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_updateZoom);
  }

  void _updateZoom() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
    if (widget.active) widget.onZoom(zoomed);
  }

  void _reset() => _transform.value = Matrix4.identity();

  void _doubleTap() {
    if (!widget.active) return;
    if (_zoomed) {
      _reset();
      return;
    }
    const scale = 2.5;
    _transform.value = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(2, 2, scale)
      ..setEntry(0, 3, _tap.dx * (1 - scale))
      ..setEntry(1, 3, _tap.dy * (1 - scale));
  }

  @override
  void didUpdateWidget(covariant _ZoomImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) _reset();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: (details) => _tap = details.localPosition,
        onDoubleTap: _doubleTap,
        child: InteractiveViewer(
          transformationController: _transform,
          maxScale: 6,
          panEnabled: _zoomed,
          child: SizedBox.expand(
            child: Image(
              image: ResizeImage.resizeIfNeeded(
                (MediaQuery.sizeOf(context).width *
                        MediaQuery.devicePixelRatioOf(context) *
                        2)
                    .round()
                    .clamp(1, 3072),
                null,
                widget.image,
              ),
              semanticLabel: widget.alt,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  Center(child: Text(context.tr('无法打开图片'))),
            ),
          ),
        ),
      ),
      if (_zoomed && widget.active)
        PositionedDirectional(
          end: 16,
          bottom: 16,
          child: IconButton.filledTonal(
            tooltip: context.tr('恢复原始缩放'),
            onPressed: _reset,
            icon: const Icon(Icons.fit_screen_outlined, size: 22),
          ),
        ),
    ],
  );
}
