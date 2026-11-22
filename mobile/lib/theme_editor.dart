part of 'mobile_settings.dart';

class _ThemeEditor extends StatefulWidget {
  const _ThemeEditor({
    required this.initial,
    required this.image,
    required this.strength,
    required this.editing,
    required this.basePalette,
  });

  final MobileTheme initial;
  final ImageProvider? image;
  final double strength;
  final bool editing;
  final LitePalette basePalette;

  @override
  State<_ThemeEditor> createState() => _ThemeEditorState();
}

class _ThemeEditorState extends State<_ThemeEditor> {
  late final name = TextEditingController(text: widget.initial.name);
  late MobileTheme draft = widget.initial;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> selectColor(ThemeColor role) async {
    final color = await showModalBottomSheet<Color>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ThemeColorSheet(
        role: role,
        initial: draft.color(role),
        quickColors: {
          draft.color(ThemeColor.accent),
          draft.color(ThemeColor.primary),
          draft.color(ThemeColor.surface),
          draft.color(ThemeColor.foreground),
          draft.color(ThemeColor.chrome),
          draft.color(ThemeColor.message),
        }.toList(),
      ),
    );
    if (color == null || !mounted) return;
    setState(
      () => draft = draft.changed(colors: {...draft.colors, role: color}),
    );
  }

  void setBrightness(Brightness next) {
    if (draft.brightness == next) return;
    final before = liteColors(draft.brightness, widget.basePalette);
    final after = liteColors(next, widget.basePalette);
    final colors = {
      for (final pair in draft.colors.entries)
        pair.key: pair.value == pair.key.fromScheme(before)
            ? pair.key.fromScheme(after)
            : pair.value,
    };
    setState(() => draft = draft.changed(brightness: next, colors: colors));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final valid = validThemeName(name.text);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editing ? context.tr('编辑主题') : context.tr('自定义主题')),
        actions: [
          TextButton(
            onPressed: valid
                ? () => Navigator.pop(
                    context,
                    draft.changed(name: name.text.trim()),
                  )
                : null,
            child: Text(context.tr('保存主题')),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                AspectRatio(
                  aspectRatio: 2.55,
                  child: Theme(
                    data: liteTheme(
                      draft.brightness,
                      LitePalette.standard,
                      draft,
                    ),
                    child: _AppearancePreview(
                      image: widget.image,
                      strength: widget.strength,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: name,
                  decoration: InputDecoration(labelText: context.tr('主题名称')),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SegmentedButton<Brightness>(
                    segments: [
                      ButtonSegment(
                        value: Brightness.light,
                        label: Text(context.tr('浅色')),
                      ),
                      ButtonSegment(
                        value: Brightness.dark,
                        label: Text(context.tr('深色')),
                      ),
                    ],
                    selected: {draft.brightness},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) =>
                        setBrightness(selection.single),
                  ),
                ),
                const SizedBox(height: 16),
                for (final role in ThemeFont.values)
                  ListTile(
                    title: Text(context.tr(role.label)),
                    contentPadding: const EdgeInsetsDirectional.only(
                      start: 4,
                      end: 2,
                    ),
                    trailing: _ThemeFontMenu(
                      role: role,
                      value: draft.font(role),
                      onChanged: (value) {
                        final fonts = {...?draft.fonts};
                        if (value == null) {
                          fonts.remove(role.name);
                        } else {
                          fonts[role.name] = value;
                        }
                        setState(() => draft = draft.changed(fonts: fonts));
                      },
                    ),
                  ),
                for (final role in ThemeColor.values)
                  ListTile(
                    title: Text(context.tr(role.label)),
                    contentPadding: const EdgeInsetsDirectional.only(
                      start: 4,
                      end: 2,
                    ),
                    minTileHeight: 48,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ThemeDot(
                          color: draft.color(role),
                          line: scheme.outlineVariant,
                        ),
                        const SizedBox(width: 9),
                        Text(
                          themeHex(draft.color(role)),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right_rounded, size: 17),
                      ],
                    ),
                    onTap: () => selectColor(role),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeFontMenu extends StatelessWidget {
  const _ThemeFontMenu({
    required this.role,
    required this.value,
    required this.onChanged,
  });

  final ThemeFont role;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = {
      '': context.tr('系统默认'),
      'sans-serif': context.tr('无衬线'),
      'serif': context.tr('衬线'),
      'monospace': context.tr('等宽'),
    };
    if (value case final String family) options.putIfAbsent(family, () => family);
    return PopupMenuButton<String>(
      tooltip: context.tr(role.label),
      initialValue: value ?? '',
      onSelected: (family) => onChanged(family.isEmpty ? null : family),
      itemBuilder: (context) => [
        for (final option in options.entries)
          PopupMenuItem(
            value: option.key,
            child: Text(option.value),
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 132),
            child: Text(
              options[value ?? '']!,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: role.resolve(value)),
            ),
          ),
          const Icon(Icons.expand_more_rounded, size: 18),
        ],
      ),
    );
  }
}

class _ThemeDot extends StatelessWidget {
  const _ThemeDot({required this.color, required this.line, this.size = 19});
  final Color color, line;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: line),
      ),
    ),
  );
}

class _ThemeColorSheet extends StatefulWidget {
  const _ThemeColorSheet({
    required this.role,
    required this.initial,
    required this.quickColors,
  });
  final ThemeColor role;
  final Color initial;
  final List<Color> quickColors;

  @override
  State<_ThemeColorSheet> createState() => _ThemeColorSheetState();
}

class _ThemeColorSheetState extends State<_ThemeColorSheet> {
  late final input = TextEditingController(text: themeHex(widget.initial));

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = parseThemeColor(input.text.trim());
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          22 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 14,
          children: [
            Text(
              context.tr(widget.role.label),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            TextField(
              controller: input,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: context.tr('十六进制颜色'),
                hintText: '#339CFF',
                prefixIcon: Center(
                  widthFactor: 1.6,
                  child: _ThemeDot(
                    color: selected ?? widget.initial,
                    line: colors.outlineVariant,
                  ),
                ),
                prefixIconConstraints: const BoxConstraints(minWidth: 44),
              ),
              onChanged: (_) => setState(() {}),
            ),
            Wrap(
              spacing: 4,
              children: [
                for (final color in widget.quickColors)
                  IconButton(
                    tooltip: themeHex(color),
                    onPressed: () =>
                        setState(() => input.text = themeHex(color)),
                    icon: _ThemeDot(
                      color: color,
                      line: colors.outlineVariant,
                      size: 24,
                    ),
                  ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton(
                onPressed: selected == null
                    ? null
                    : () => Navigator.pop(context, selected),
                child: Text(context.tr('应用颜色')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
