part of 'mobile_settings.dart';

const _imageFiles = XTypeGroup(
  label: '图片',
  extensions: ['jpg', 'jpeg', 'png', 'webp'],
  mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
  uniformTypeIdentifiers: ['public.jpeg', 'public.png', 'org.webmproject.webp'],
);

class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key, required this.appearance});
  final MobileAppearance appearance;

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  double? strengthPreview;
  bool choosing = false;

  Future<void> save(Future<void> action) async {
    try {
      await action;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('无法保存外观偏好'))));
      }
    }
  }

  Future<void> chooseImage() async {
    setState(() => choosing = true);
    try {
      final image = await openFile(acceptedTypeGroups: [_imageFiles]);
      if (image != null) await widget.appearance.importWallpaper(image);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('无法添加这张图片'))));
      }
    } finally {
      if (mounted) setState(() => choosing = false);
    }
  }

  Future<void> themeFile({required bool exporting}) async {
    final prefs = widget.appearance;
    final colors = Theme.of(context).colorScheme;
    setState(() => choosing = true);
    try {
      if (exporting) {
        final theme =
            prefs.customTheme ??
            MobileTheme.fromScheme(
              'mobile-${const Uuid().v4()}',
              prefs.customTheme?.name ?? context.tr(prefs.palette.label),
              colors,
            );
        final saved = await prefs.exportTheme(
          theme,
          selectedBackground: prefs.background,
        );
        if (saved && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(context.tr('主题已导出'))));
        }
      } else {
        final file = await openFile();
        if (file != null) await prefs.importTheme(file);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr(e is GatewayError ? e.message : '无法处理主题包'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => choosing = false);
    }
  }

  Future<void> editTheme() async {
    final prefs = widget.appearance;
    final base = prefs.customTheme;
    final scheme = Theme.of(context).colorScheme;
    final starting =
        base ??
        MobileTheme.fromScheme(
          'mobile-${const Uuid().v4()}',
          context.tr('我的主题'),
          scheme,
        );
    final background = prefs.background;
    final wallpaper = prefs.wallpaperImage(prefs.currentWallpaper, width: 650);
    final theme = await Navigator.of(context).push<MobileTheme>(
      MaterialPageRoute(
        builder: (_) => _ThemeEditor(
          initial: starting,
          image: wallpaper,
          strength: background.strength / 100,
          editing: base != null,
          basePalette: prefs.palette,
        ),
      ),
    );
    if (theme != null && mounted) {
      await save(prefs.saveTheme(theme, background));
    }
  }

  Future<void> removeTheme(MobileTheme theme) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.tr('移除主题？')),
        content: Text(theme.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(context.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.tr('移除')),
          ),
        ],
      ),
    );
    if (approved == true && mounted) {
      await save(widget.appearance.removeTheme(theme));
    }
  }

  Widget section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Semantics(
      header: true,
      child: Text(
        context.tr(title),
        style: Theme.of(context).textTheme.titleMedium,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final prefs = widget.appearance;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('主题与背景')),
        actions: [
          IconButton(
            tooltip: context.tr('导入主题包'),
            onPressed: choosing ? null : () => themeFile(exporting: false),
            icon: const Icon(Icons.drive_folder_upload_rounded, size: 20),
          ),
          IconButton(
            tooltip: context.tr('导出主题包'),
            onPressed: choosing ? null : () => themeFile(exporting: true),
            icon: const Icon(Icons.download_outlined, size: 21),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: ListenableBuilder(
              listenable: prefs,
              builder: (context, _) {
                final theme = Theme.of(context);
                final colors = theme.colorScheme;
                final custom = prefs.customTheme;
                final wallpaper = prefs.currentWallpaper;
                final hasWallpaper = wallpaper != MobileWallpaper.none;
                final current =
                    strengthPreview ?? prefs.background.strength.toDouble();
                return ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                  children: [
                    AspectRatio(
                      aspectRatio: 2.55,
                      child: _AppearancePreview(
                        image: prefs.wallpaperImage(wallpaper, width: 650),
                        strength: current / 100,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (custom == null) ...[
                      section(context, '外观模式'),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: SegmentedButton<ThemeMode>(
                          segments: [
                            for (final mode in ThemeMode.values)
                              ButtonSegment(
                                value: mode,
                                label: Text(
                                  context.tr(MobileSettingsPage.labels[mode]!),
                                ),
                              ),
                          ],
                          selected: {prefs.mode},
                          showSelectedIcon: false,
                          onSelectionChanged: (items) =>
                              save(prefs.select(items.single)),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.tr('主题'),
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: choosing ? null : editTheme,
                          icon: Icon(
                            custom == null
                                ? Icons.add_rounded
                                : Icons.tune_rounded,
                            size: 18,
                          ),
                          label: Text(
                            custom == null
                                ? context.tr('自定义主题')
                                : context.tr('编辑当前主题'),
                          ),
                        ),
                      ],
                    ),
                    _AppearanceGrid(
                      compactColumns: 2,
                      wideColumns: 4,
                      children: [
                        for (final palette in LitePalette.values)
                          _AppearanceTile(
                            title: context.tr(palette.label),
                            selected:
                                custom == null && prefs.palette == palette,
                            onTap: () => save(prefs.selectPalette(palette)),
                            thumbnail: _ThemeSwatches(
                              colors: liteColors(colors.brightness, palette),
                            ),
                          ),
                      ],
                    ),
                    if (prefs.customThemes.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      section(context, '我的主题'),
                      _AppearanceGrid(
                        compactColumns: 2,
                        wideColumns: 4,
                        children: [
                          for (final installed in prefs.customThemes)
                            _AppearanceTile(
                              title: installed.name,
                              selected: custom?.id == installed.id,
                              onTap: () => save(prefs.selectTheme(installed)),
                              thumbnail: _ThemeSwatches(
                                colors: installed.scheme(),
                              ),
                            ),
                        ],
                      ),
                    ],
                    if (custom != null)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          onPressed: choosing
                              ? null
                              : () => removeTheme(custom),
                          child: Text(context.tr('移除当前主题')),
                        ),
                      ),
                    const SizedBox(height: 26),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.tr('背景图'),
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: choosing ? null : chooseImage,
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: Text(context.tr('添加图片')),
                        ),
                      ],
                    ),
                    if (hasWallpaper) ...[
                      Row(
                        children: [
                          Expanded(child: Text(context.tr('背景强度'))),
                          Text(
                            '${current.round()}%',
                            style: theme.textTheme.labelLarge,
                          ),
                        ],
                      ),
                      Slider(
                        value: current,
                        max: 100,
                        label: '${current.round()}%',
                        semanticFormatterCallback: (value) => context.strings
                            .format('背景强度 {value}%', {'value': value.round()}),
                        onChanged: (value) =>
                            setState(() => strengthPreview = value),
                        onChangeEnd: (value) async {
                          await save(prefs.setStrength(value));
                          if (mounted) setState(() => strengthPreview = null);
                        },
                      ),
                    ],
                    _AppearanceGrid(
                      compactColumns: 3,
                      wideColumns: 4,
                      children: [
                        for (final entry in prefs.wallpapers)
                          _AppearanceTile(
                            title: MobileWallpaper.builtIns.contains(entry)
                                ? context.tr(entry.name)
                                : entry.name,
                            selected: entry.id == wallpaper.id,
                            onTap: () => save(prefs.selectWallpaper(entry)),
                            thumbnail: _WallpaperThumbnail(
                              image: prefs.wallpaperImage(entry, width: 280),
                            ),
                          ),
                      ],
                    ),
                    if (hasWallpaper && wallpaper.asset == null)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          onPressed: () =>
                              save(prefs.forgetWallpaper(wallpaper)),
                          child: Text(context.tr('从图库移除')),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AppearancePreview extends StatelessWidget {
  const _AppearancePreview({required this.image, required this.strength});
  final ImageProvider? image;
  final double strength;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: WallpaperCanvas(
          color:
              CustomThemeTokens.read(context, ThemeColor.canvas) ??
              colors.surface,
          image: image,
          strength: strength,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  children: [
                    PositionedDirectional(
                      top: 0,
                      start: 0,
                      child: CircleAvatar(
                        radius: 12,
                        backgroundColor:
                            CustomThemeTokens.read(
                              context,
                              ThemeColor.chrome,
                            ) ??
                            colors.surfaceContainerHigh,
                        foregroundColor: colors.onSurfaceVariant,
                        child: const Icon(Icons.menu_rounded, size: 12),
                      ),
                    ),
                    PositionedDirectional(
                      top: 5,
                      start: 34,
                      child: _Shape(
                        width: 54,
                        height: 6,
                        color: colors.onSurfaceVariant.withValues(alpha: .38),
                      ),
                    ),
                    PositionedDirectional(
                      top: 25,
                      end: 5,
                      child: _Shape(
                        width: box.maxWidth * .43,
                        height: 14,
                        color: colors.secondaryContainer,
                      ),
                    ),
                    PositionedDirectional(
                      top: 44,
                      start: 2,
                      child: _Shape(
                        width: box.maxWidth * .52,
                        height: 5,
                        color: colors.onSurfaceVariant.withValues(alpha: .35),
                      ),
                    ),
                    PositionedDirectional(
                      top: 54,
                      start: 2,
                      child: _Shape(
                        width: box.maxWidth * .36,
                        height: 5,
                        color: colors.onSurfaceVariant.withValues(alpha: .35),
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional.bottomCenter,
                      child: Container(
                        height: 24,
                        decoration: BoxDecoration(
                          color:
                              CustomThemeTokens.read(
                                context,
                                ThemeColor.composer,
                              ) ??
                              colors.surfaceContainerLow,
                          border: Border.all(color: colors.outlineVariant),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        alignment: AlignmentDirectional.centerEnd,
                        child: CircleAvatar(
                          radius: 8,
                          backgroundColor: colors.primary,
                          foregroundColor: colors.onPrimary,
                          child: const Icon(
                            Icons.arrow_upward_rounded,
                            size: 10,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Shape extends StatelessWidget {
  const _Shape({
    required this.width,
    required this.height,
    required this.color,
  });
  final double width, height;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(5),
    ),
  );
}

class _AppearanceGrid extends StatelessWidget {
  const _AppearanceGrid({
    required this.children,
    required this.compactColumns,
    required this.wideColumns,
  });
  final List<Widget> children;
  final int compactColumns, wideColumns;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final columns = bounds.maxWidth >= 510 ? wideColumns : compactColumns;
      const gap = 10.0;
      final width = (bounds.maxWidth - (columns - 1) * gap) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final tile in children) SizedBox(width: width, child: tile),
        ],
      );
    },
  );
}

class _AppearanceTile extends StatelessWidget {
  const _AppearanceTile({
    required this.title,
    required this.selected,
    required this.onTap,
    required this.thumbnail,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final Widget thumbnail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        color: colors.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                width: selected ? 1.5 : 1,
                color: selected ? colors.primary : colors.outlineVariant,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: AspectRatio(
                      aspectRatio: 2.3,
                      child: ExcludeSemantics(child: thumbnail),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 7, 4, 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge,
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check_rounded,
                            size: 17,
                            color: colors.primary,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeSwatches extends StatelessWidget {
  const _ThemeSwatches({required this.colors});
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(flex: 5, child: ColoredBox(color: colors.surface)),
      Expanded(flex: 3, child: ColoredBox(color: colors.secondaryContainer)),
      Expanded(flex: 2, child: ColoredBox(color: colors.primary)),
    ],
  );
}

class _WallpaperThumbnail extends StatelessWidget {
  const _WallpaperThumbnail({required this.image});
  final ImageProvider? image;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colors.surfaceContainerHigh,
      child: Icon(
        image == null
            ? Icons.hide_image_outlined
            : Icons.image_not_supported_outlined,
        color: colors.onSurfaceVariant,
        size: 20,
      ),
    );
    final provider = image;
    return provider == null
        ? placeholder
        : Image(
            image: provider,
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => placeholder,
          );
  }
}
