import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';

enum _Modifier { primary, control, alt, none }

enum MobileShortcut {
  quickAccess(
    '快捷入口',
    'K',
    LogicalKeyboardKey.keyK,
    alternate: LogicalKeyboardKey.keyP,
    alternateLabel: 'P',
  ),
  settings('设置', ',', LogicalKeyboardKey.comma),
  newTab(
    '新建会话',
    'N',
    LogicalKeyboardKey.keyN,
    alternate: LogicalKeyboardKey.keyT,
    alternateLabel: 'T',
  ),
  nextTab('下一个标签', 'Tab', LogicalKeyboardKey.tab, modifier: _Modifier.control),
  previousTab(
    '上一个标签',
    'Tab',
    LogicalKeyboardKey.tab,
    modifier: _Modifier.control,
    shift: true,
  ),
  closeTab('关闭标签', 'W', LogicalKeyboardKey.keyW),
  reopenTab('重新打开已关闭的标签', 'T', LogicalKeyboardKey.keyT, shift: true),
  find('在会话内查找', 'F', LogicalKeyboardKey.keyF),
  review('审查 Git 变更', 'G', LogicalKeyboardKey.keyG),
  workspace('工作区', 'E', LogicalKeyboardKey.keyE, shift: true),
  turns('跳到会话轮次', 'T', LogicalKeyboardKey.keyT, modifier: _Modifier.alt),
  send(
    '发送',
    'Enter',
    LogicalKeyboardKey.enter,
    alternate: LogicalKeyboardKey.numpadEnter,
  ),
  composerEnter(
    '发送',
    'Enter',
    LogicalKeyboardKey.enter,
    alternate: LogicalKeyboardKey.numpadEnter,
    modifier: _Modifier.none,
  ),
  composerPaste('粘贴', 'V', LogicalKeyboardKey.keyV),
  composerNewline(
    '换行',
    'Enter',
    LogicalKeyboardKey.enter,
    alternate: LogicalKeyboardKey.numpadEnter,
    modifier: _Modifier.none,
    shift: true,
  ),
  nextMatch('下一个匹配', 'G', LogicalKeyboardKey.keyG),
  previousMatch('上一个匹配', 'G', LogicalKeyboardKey.keyG, shift: true),
  nextChoice(
    '下一项',
    '↓',
    LogicalKeyboardKey.arrowDown,
    modifier: _Modifier.none,
  ),
  previousChoice(
    '上一项',
    '↑',
    LogicalKeyboardKey.arrowUp,
    modifier: _Modifier.none,
  ),
  openChoice(
    '打开所选项',
    'Enter',
    LogicalKeyboardKey.enter,
    alternate: LogicalKeyboardKey.numpadEnter,
    modifier: _Modifier.none,
  ),
  previousImage(
    '上一张',
    '←',
    LogicalKeyboardKey.arrowLeft,
    modifier: _Modifier.none,
  ),
  nextImage(
    '下一张',
    '→',
    LogicalKeyboardKey.arrowRight,
    modifier: _Modifier.none,
  ),
  dismiss('返回', 'Esc', LogicalKeyboardKey.escape, modifier: _Modifier.none);

  const MobileShortcut(
    this.label,
    this.keyLabel,
    this.key, {
    this._modifier = _Modifier.primary,
    this.shift = false,
    this.alternate,
    this.alternateLabel,
  });

  final String label, keyLabel;
  final LogicalKeyboardKey key;
  final _Modifier _modifier;
  final bool shift;
  final LogicalKeyboardKey? alternate;
  final String? alternateLabel;

  Iterable<ShortcutActivator> get activators sync* {
    for (final trigger in [key, ?alternate]) {
      yield SingleActivator(
        trigger,
        control:
            _modifier == _Modifier.control || _modifier == _Modifier.primary,
        alt: _modifier == _Modifier.alt,
        shift: shift,
        includeRepeats: false,
      );
      if (_modifier == _Modifier.primary) {
        yield SingleActivator(
          trigger,
          meta: true,
          shift: shift,
          includeRepeats: false,
        );
      }
    }
  }

  List<String> captions(bool apple) {
    final prefix = [
      if (_modifier == _Modifier.control ||
          _modifier == _Modifier.primary && !apple)
        'Ctrl',
      if (_modifier == _Modifier.primary && apple) '⌘',
      if (_modifier == _Modifier.alt) apple ? '⌥' : 'Alt',
      if (shift) apple ? '⇧' : 'Shift',
    ];
    return [
      [...prefix, keyLabel].join(' + '),
      if (alternateLabel case final other?) [...prefix, other].join(' + '),
    ];
  }

  static Map<ShortcutActivator, VoidCallback> bind(
    Map<MobileShortcut, VoidCallback> actions,
  ) => {
    for (final entry in actions.entries)
      for (final activator in entry.key.activators) activator: entry.value,
  };
}

class KeyboardShortcutsPage extends StatelessWidget {
  const KeyboardShortcutsPage({super.key});

  static const groups = {
    '会话': [
      MobileShortcut.quickAccess,
      MobileShortcut.newTab,
      MobileShortcut.nextTab,
      MobileShortcut.previousTab,
      MobileShortcut.closeTab,
      MobileShortcut.reopenTab,
      MobileShortcut.settings,
      MobileShortcut.workspace,
      MobileShortcut.review,
      MobileShortcut.find,
      MobileShortcut.turns,
      MobileShortcut.send,
      MobileShortcut.composerNewline,
    ],
    '查找与定位': [
      MobileShortcut.nextChoice,
      MobileShortcut.previousChoice,
      MobileShortcut.nextMatch,
      MobileShortcut.previousMatch,
      MobileShortcut.openChoice,
    ],
    '原图': [MobileShortcut.previousImage, MobileShortcut.nextImage],
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final apple = {
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    }.contains(theme.platform);
    return CallbackShortcuts(
      bindings: MobileShortcut.bind({
        MobileShortcut.dismiss: () => Navigator.of(context).maybePop(),
      }),
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        child: Scaffold(
          appBar: AppBar(title: Text(context.tr('键盘快捷键'))),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  children: [
                    for (final group in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 8, 0, 6),
                        child: Text(
                          context.tr(group.key),
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      for (final shortcut in group.value)
                        ListTile(
                          minTileHeight: 46,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          title: Text(context.tr(shortcut.label)),
                          trailing: Text(
                            [
                              if (shortcut == MobileShortcut.send)
                                ...MobileShortcut.composerEnter.captions(apple),
                              ...shortcut.captions(apple),
                            ].join('  /  '),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      const SizedBox(height: 14),
                    ],
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      title: Text(context.tr(MobileShortcut.dismiss.label)),
                      trailing: const Text('Esc'),
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
