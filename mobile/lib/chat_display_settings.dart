part of 'mobile_settings.dart';

class ConversationCanvas extends StatelessWidget {
  const ConversationCanvas({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final appearance = MobileAppearance.shared;
    return ListenableBuilder(
      listenable: appearance,
      child: child,
      builder: (context, child) {
        final width =
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))
                .ceil()
                .clamp(480, 1536);
        return WallpaperCanvas(
          color:
              CustomThemeTokens.read(context, ThemeColor.canvas) ??
              Theme.of(context).colorScheme.surface,
          image: appearance.conversationBackdrop
              ? appearance.wallpaperImage(
                  appearance.currentWallpaper,
                  width: width,
                )
              : null,
          strength: appearance.background.strength / 100,
          child: child!,
        );
      },
    );
  }
}

class _ChatDisplayPage extends StatelessWidget {
  const _ChatDisplayPage({required this.appearance});

  final MobileAppearance appearance;

  Future<void> _save(BuildContext context, Future<void> change) async {
    try {
      await change;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('无法保存聊天显示设置'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('聊天显示'))),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: ListenableBuilder(
            listenable: appearance,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
              children: [
                _DisplayOptions(
                  title: context.tr('消息字号'),
                  children: [
                    for (final size in MessageSize.values)
                      ChoiceChip(
                        label: Text(context.tr(size.label)),
                        selected: appearance.messageSize == size,
                        onSelected: (_) =>
                            _save(context, appearance.setMessageSize(size)),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                _DisplayOptions(
                  title: context.tr('推理过程'),
                  children: [
                    for (final mode in ReasoningVisibility.values)
                      ChoiceChip(
                        label: Text(context.tr(mode.label)),
                        selected: appearance.reasoning == mode,
                        onSelected: (_) => _save(
                          context,
                          appearance.setReasoningVisibility(mode),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  secondary: const Icon(Icons.wallpaper_outlined, size: 21),
                  title: Text(context.tr('对话背景')),
                  value: appearance.conversationBackdrop,
                  onChanged: (show) =>
                      _save(context, appearance.setConversationBackdrop(show)),
                ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  secondary: const Icon(Icons.volume_up_outlined, size: 21),
                  title: Text(context.tr('自动朗读回复')),
                  value: appearance.autoReadReplies,
                  onChanged: (enabled) =>
                      _save(context, appearance.setAutoReadReplies(enabled)),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _DisplayOptions extends StatelessWidget {
  const _DisplayOptions({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: children),
      ],
    ),
  );
}
