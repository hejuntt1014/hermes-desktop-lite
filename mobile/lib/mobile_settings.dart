import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:uuid/uuid.dart';
import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'attachment_view.dart' show saveLocalFile;
import 'chat_display.dart';
import 'mobile_themes.dart';
import 'gateway.dart';
import 'gateway_status_view.dart';
import 'mobile_wallpapers.dart';
import 'mobile_notifications.dart';
import 'mobile_locale.dart';
import 'mobile_shortcuts.dart';
import 'split_pane.dart';

part 'appearance_page.dart';
part 'chat_display_settings.dart';
part 'theme_editor.dart';

typedef BackgroundChoice = ({String wallpaper, int strength});

class _AppearanceState {
  const _AppearanceState({
    this.language = MobileLanguage.system,
    this.mode = ThemeMode.system,
    this.palette = LitePalette.standard,
    this.gallery = const [],
    this.backgrounds = const {},
    this.activeTheme = '',
    this.customThemes = const [],
    this.paneWidths = const {},
    this.sidebarOpen = true,
    this.messageSize = MessageSize.standard,
    this.reasoning = ReasoningVisibility.gateway,
    this.conversationBackdrop = true,
    this.autoReadReplies = false,
    this.restoreSession = true,
    this.attachmentTransport = AttachmentTransport.automatic,
  });

  final MobileLanguage language;
  final ThemeMode mode;
  final LitePalette palette;
  final List<MobileWallpaper> gallery;
  final Map<String, BackgroundChoice> backgrounds;
  final String activeTheme;
  final List<MobileTheme> customThemes;
  final Map<SplitPaneRole, double> paneWidths;
  final bool sidebarOpen;
  final MessageSize messageSize;
  final ReasoningVisibility reasoning;
  final bool conversationBackdrop;
  final bool autoReadReplies;
  final bool restoreSession;
  final AttachmentTransport attachmentTransport;

  static _AppearanceState fromWire(Json wire) {
    final backgrounds = <String, BackgroundChoice>{};
    final saved = wire['backgrounds'];
    if (saved is Json) {
      for (final item in saved.entries) {
        if (item.value case final Json entry) {
          final wallpaper = entry['wallpaper'];
          final strength = entry['strength'];
          if (wallpaper is String && strength is int) {
            backgrounds[item.key] = (
              wallpaper: wallpaper,
              strength: strength.clamp(0, 100),
            );
          }
        }
      }
    }
    final recorded = wire['themes'];
    final custom = <MobileTheme>[];
    if (recorded is List) {
      for (final candidate in recorded.whereType<Json>()) {
        try {
          custom.add(MobileTheme.parse(candidate));
        } on GatewayError {
          // Do not prevent valid themes and wallpaper preferences from loading.
        }
      }
    }
    final active = wire['active_theme'];
    final gallery = wire['gallery'];
    final widths = wire['pane_widths'];
    return _AppearanceState(
      language: MobileLanguage.fromStorage(wire['language']),
      mode:
          ThemeMode.values
              .where((mode) => mode.name == wire['mode'])
              .firstOrNull ??
          ThemeMode.system,
      palette:
          LitePalette.values
              .where((item) => item.id == wire['palette'])
              .firstOrNull ??
          LitePalette.standard,
      gallery: gallery is List
          ? gallery
                .whereType<Json>()
                .map(MobileWallpaper.fromWire)
                .nonNulls
                .toList()
          : const [],
      paneWidths: {
        if (widths is Json)
          for (final role in SplitPaneRole.values)
            if (widths[role.name] case final num width when width.isFinite)
              role: width.clamp(role.minimum, role.maximum).toDouble(),
      },
      sidebarOpen: wire['sidebar_open'] != false,
      messageSize:
          MessageSize.values
              .where((size) => size.name == wire['message_size'])
              .firstOrNull ??
          MessageSize.standard,
      reasoning:
          ReasoningVisibility.values
              .where((mode) => mode.name == wire['reasoning_visibility'])
              .firstOrNull ??
          ReasoningVisibility.gateway,
      conversationBackdrop: wire['conversation_backdrop'] != false,
      autoReadReplies: wire['auto_read_replies'] == true,
      restoreSession: wire['restore_session'] != false,
      attachmentTransport:
          wire['attachment_transport'] == AttachmentTransport.base64.name
          ? AttachmentTransport.base64
          : AttachmentTransport.automatic,
      backgrounds: backgrounds,
      activeTheme: active is String && custom.any((theme) => theme.id == active)
          ? active
          : '',
      customThemes: custom,
    );
  }

  Json toWire() => {
    'language': language.name,
    'mode': mode.name,
    'palette': palette.id,
    'gallery': gallery.map((item) => item.toWire()).toList(),
    if (activeTheme.isNotEmpty) 'active_theme': activeTheme,
    if (customThemes.isNotEmpty)
      'themes': customThemes.map((theme) => theme.toWire()).toList(),
    if (paneWidths.isNotEmpty)
      'pane_widths': {
        for (final entry in paneWidths.entries) entry.key.name: entry.value,
      },
    if (!sidebarOpen) 'sidebar_open': false,
    if (messageSize != MessageSize.standard) 'message_size': messageSize.name,
    if (reasoning != ReasoningVisibility.gateway)
      'reasoning_visibility': reasoning.name,
    if (!conversationBackdrop) 'conversation_backdrop': false,
    if (autoReadReplies) 'auto_read_replies': true,
    if (!restoreSession) 'restore_session': false,
    if (attachmentTransport != AttachmentTransport.automatic)
      'attachment_transport': attachmentTransport.name,
    'backgrounds': {
      for (final entry in backgrounds.entries)
        entry.key: {
          'wallpaper': entry.value.wallpaper,
          'strength': entry.value.strength,
        },
    },
  };

  _AppearanceState copyWith({
    MobileLanguage? language,
    ThemeMode? mode,
    LitePalette? palette,
    List<MobileWallpaper>? gallery,
    Map<String, BackgroundChoice>? backgrounds,
    String? activeTheme,
    List<MobileTheme>? customThemes,
    Map<SplitPaneRole, double>? paneWidths,
    bool? sidebarOpen,
    MessageSize? messageSize,
    ReasoningVisibility? reasoning,
    bool? conversationBackdrop,
    bool? autoReadReplies,
    bool? restoreSession,
    AttachmentTransport? attachmentTransport,
  }) => _AppearanceState(
    language: language ?? this.language,
    mode: mode ?? this.mode,
    palette: palette ?? this.palette,
    gallery: gallery ?? this.gallery,
    backgrounds: backgrounds ?? this.backgrounds,
    activeTheme: activeTheme ?? this.activeTheme,
    customThemes: customThemes ?? this.customThemes,
    paneWidths: paneWidths ?? this.paneWidths,
    sidebarOpen: sidebarOpen ?? this.sidebarOpen,
    messageSize: messageSize ?? this.messageSize,
    reasoning: reasoning ?? this.reasoning,
    conversationBackdrop: conversationBackdrop ?? this.conversationBackdrop,
    autoReadReplies: autoReadReplies ?? this.autoReadReplies,
    restoreSession: restoreSession ?? this.restoreSession,
    attachmentTransport: attachmentTransport ?? this.attachmentTransport,
  );
}

class MobileAppearance extends ChangeNotifier {
  static final shared = MobileAppearance();
  static const _storage = FlutterSecureStorage();
  static const _legacyKey = 'hermes.mobile.appearance.theme.v1';
  static const _key = 'hermes.mobile.appearance.v2';
  final _wallpapers = WallpaperStorage();
  Directory? _folder;
  _AppearanceState _state = const _AppearanceState();
  Future<void> _writes = Future.value();

  ThemeMode get mode => _state.mode;
  MobileLanguage get language => _state.language;
  double paneWidth(SplitPaneRole role) =>
      _state.paneWidths[role] ?? role.standard;
  bool get sidebarOpen => _state.sidebarOpen;
  MessageSize get messageSize => _state.messageSize;
  ReasoningVisibility get reasoning => _state.reasoning;
  bool get conversationBackdrop => _state.conversationBackdrop;
  bool get autoReadReplies => _state.autoReadReplies;
  bool get restoreSession => _state.restoreSession;
  AttachmentTransport get attachmentTransport => _state.attachmentTransport;
  LitePalette get palette => _state.palette;
  List<MobileTheme> get customThemes => List.unmodifiable(_state.customThemes);
  MobileTheme? get customTheme =>
      customThemes.where((theme) => theme.id == _state.activeTheme).firstOrNull;
  ThemeMode get effectiveMode => switch (customTheme?.brightness) {
    Brightness.light => ThemeMode.light,
    Brightness.dark => ThemeMode.dark,
    _ => mode,
  };
  String get themeId =>
      _state.activeTheme.isEmpty ? palette.id : _state.activeTheme;
  List<MobileWallpaper> get wallpapers => [
    ...MobileWallpaper.builtIns,
    ..._state.gallery,
  ];

  BackgroundChoice get background => _choice(_state, themeId);

  BackgroundChoice _choice(_AppearanceState state, String themeId) =>
      state.backgrounds[themeId] ??
      (
        wallpaper: themeId == LitePalette.blueHour.id
            ? MobileWallpaper.blue.id
            : MobileWallpaper.none.id,
        strength: themeId == LitePalette.blueHour.id ? 45 : 50,
      );

  MobileWallpaper get currentWallpaper =>
      wallpapers.where((item) => item.id == background.wallpaper).firstOrNull ??
      MobileWallpaper.none;

  ImageProvider? wallpaperImage(
    MobileWallpaper wallpaper, {
    required int width,
  }) {
    if (wallpaper.asset case final asset?) {
      return ResizeImage.resizeIfNeeded(width, null, AssetImage(asset));
    }
    final folder = _folder;
    if (folder == null || wallpaper == MobileWallpaper.none) return null;
    return ResizeImage.resizeIfNeeded(
      width,
      null,
      FileImage(_wallpapers.forId(folder, wallpaper.id)),
    );
  }

  Future<void> load() => _serialize(() async {
    final raw = await _storage.read(key: _key);
    final wire = raw == null
        ? {'mode': await _storage.read(key: _legacyKey)}
        : jsonDecode(raw);
    if (wire is! Json) return;
    final restored = _AppearanceState.fromWire(wire);
    if (restored.gallery.isNotEmpty) _folder = await _wallpapers.root();
    _state = restored;
    notifyListeners();
  });

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _writes.then((_) => operation());
    _writes = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _change(_AppearanceState Function(_AppearanceState) change) =>
      _serialize(() async {
        final state = change(_state);
        if (identical(state, _state)) return;
        await _storage.write(key: _key, value: jsonEncode(state.toWire()));
        _state = state;
        notifyListeners();
      });

  Future<void> select(ThemeMode next) => _change(
    (state) => state.mode == next ? state : state.copyWith(mode: next),
  );

  Future<void> selectLanguage(MobileLanguage next) => _change(
    (state) => state.language == next ? state : state.copyWith(language: next),
  );

  Future<void> setPaneWidth(SplitPaneRole role, double? width) =>
      _change((state) {
        final next = width
            ?.roundToDouble()
            .clamp(role.minimum, role.maximum)
            .toDouble();
        if (state.paneWidths[role] == next) return state;
        final widths = {...state.paneWidths};
        if (next == null) {
          widths.remove(role);
        } else {
          widths[role] = next;
        }
        return state.copyWith(paneWidths: widths);
      });

  Future<void> setSidebarOpen(bool open) => _change(
    (state) =>
        state.sidebarOpen == open ? state : state.copyWith(sidebarOpen: open),
  );

  Future<void> setMessageSize(MessageSize size) => _change(
    (state) =>
        state.messageSize == size ? state : state.copyWith(messageSize: size),
  );

  Future<void> setReasoningVisibility(ReasoningVisibility visibility) =>
      _change(
        (state) => state.reasoning == visibility
            ? state
            : state.copyWith(reasoning: visibility),
      );

  Future<void> setConversationBackdrop(bool show) => _change(
    (state) => state.conversationBackdrop == show
        ? state
        : state.copyWith(conversationBackdrop: show),
  );

  Future<void> setAutoReadReplies(bool enabled) => _change(
    (state) => state.autoReadReplies == enabled
        ? state
        : state.copyWith(autoReadReplies: enabled),
  );

  Future<void> setRestoreSession(bool restore) => _change(
    (state) => state.restoreSession == restore
        ? state
        : state.copyWith(restoreSession: restore),
  );

  Future<void> setAttachmentTransport(AttachmentTransport transport) => _change(
    (state) => state.attachmentTransport == transport
        ? state
        : state.copyWith(attachmentTransport: transport),
  );

  Future<void> selectPalette(LitePalette next) => _change(
    (state) => state.palette == next && state.activeTheme.isEmpty
        ? state
        : state.copyWith(palette: next, activeTheme: ''),
  );

  Future<void> selectTheme(MobileTheme theme) =>
      _change((state) => state.copyWith(activeTheme: theme.id));

  Future<void> saveTheme(
    MobileTheme theme,
    BackgroundChoice inheritedBackground,
  ) => _change(
    (state) => state.copyWith(
      activeTheme: theme.id,
      customThemes: [
        for (final existing in state.customThemes)
          if (existing.id != theme.id) existing,
        theme,
      ],
      backgrounds: {
        ...state.backgrounds,
        if (!state.backgrounds.containsKey(theme.id))
          theme.id: inheritedBackground,
      },
    ),
  );

  Future<void> removeTheme(MobileTheme theme) => _change(
    (state) => state.copyWith(
      activeTheme: state.activeTheme == theme.id ? '' : state.activeTheme,
      customThemes: state.customThemes
          .where((item) => item.id != theme.id)
          .toList(),
      backgrounds: {
        for (final entry in state.backgrounds.entries)
          if (entry.key != theme.id) entry.key: entry.value,
      },
    ),
  );

  Future<void> selectWallpaper(MobileWallpaper choice) {
    final target = themeId;
    return _change((state) {
      final current = _choice(state, target);
      return state.copyWith(
        backgrounds: {
          ...state.backgrounds,
          target: (wallpaper: choice.id, strength: current.strength),
        },
      );
    });
  }

  Future<void> setStrength(double strength) {
    final target = themeId;
    return _change((state) {
      final current = _choice(state, target);
      return state.copyWith(
        backgrounds: {
          ...state.backgrounds,
          target: (
            wallpaper: current.wallpaper,
            strength: strength.round().clamp(0, 100),
          ),
        },
      );
    });
  }

  Future<void> importWallpaper(XFile file) async {
    final target = themeId;
    final directory = _folder ??= await _wallpapers.root();
    final imported = await _wallpapers.add(file, directory);
    await _change((state) {
      final current = _choice(state, target);
      return state.copyWith(
        gallery: [
          imported,
          ...state.gallery.where((item) => item.id != imported.id),
        ],
        backgrounds: {
          ...state.backgrounds,
          target: (
            wallpaper: imported.id,
            strength: current.strength == 0 ? 50 : current.strength,
          ),
        },
      );
    });
  }

  Future<void> importTheme(XFile file) async {
    if (await file.length() > themeArchiveLimit) {
      throw GatewayError('主题包或背景图超过主题包大小限制');
    }
    final stage = await Directory.systemTemp.createTemp('hermes-theme-import-');
    try {
      final archive = File('${stage.path}/theme.hermes-theme');
      await file.saveTo(archive.path);
      await runThemeArchive(archive.path, stage.path, pack: false);
      final data = await readThemeManifest(File('${stage.path}/theme.json'));
      final theme = MobileTheme.parse(data);
      if (customThemes.any((existing) => existing.id == theme.id)) {
        throw GatewayError('该主题已安装');
      }
      final background = data['background'];
      MobileWallpaper? image;
      var opacity = 50;
      if (background != null) {
        if (background is! Json || background['opacity'] is! int) {
          throw GatewayError('主题背景强度无效');
        }
        opacity = background['opacity'] as int;
        if (opacity < 0 || opacity > 100) throw GatewayError('主题背景强度无效');
        final folder = _folder ??= await _wallpapers.root();
        image = await _wallpapers.add(
          XFile('${stage.path}/background', name: theme.name),
          folder,
        );
      }
      await _change((state) {
        if (state.customThemes.any((existing) => existing.id == theme.id)) {
          throw GatewayError('该主题已安装');
        }
        return state.copyWith(
          activeTheme: theme.id,
          customThemes: [...state.customThemes, theme],
          backgrounds: {
            ...state.backgrounds,
            theme.id: (
              wallpaper: image?.id ?? MobileWallpaper.none.id,
              strength: opacity,
            ),
          },
          gallery: [
            if (image != null &&
                !state.gallery.any((item) => item.id == image?.id))
              image,
            ...state.gallery,
          ],
        );
      });
    } finally {
      await stage.delete(recursive: true);
    }
  }

  Future<bool> exportTheme(
    MobileTheme theme, {
    BackgroundChoice? selectedBackground,
  }) async {
    final current = selectedBackground ?? _choice(_state, theme.id);
    final wallpaper = wallpapers
        .where((item) => item.id == current.wallpaper)
        .firstOrNull;
    final stage = await Directory.systemTemp.createTemp('hermes-theme-export-');
    try {
      var present = false;
      if (wallpaper != null && wallpaper != MobileWallpaper.none) {
        final image = File('${stage.path}/background');
        if (wallpaper.asset case final asset?) {
          final bytes = await rootBundle.load(asset);
          await image.writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          );
        } else {
          final directory = _folder;
          if (directory == null) throw GatewayError('无法读取主题背景图');
          final source = _wallpapers.forId(directory, wallpaper.id);
          if (await source.length() > 16 * 1024 * 1024) {
            throw GatewayError('主题包或背景图超过主题包大小限制');
          }
          await source.copy(image.path);
        }
        present = true;
      }
      await File('${stage.path}/theme.json').writeAsString(
        jsonEncode(
          theme.toWire(wallpaperOpacity: present ? current.strength : null),
        ),
      );
      final sanitized = theme.name
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '-')
          .trim();
      final basename = sanitized.isEmpty ? theme.id : sanitized;
      final archive = File('${stage.path}/$basename.hermes-theme');
      await runThemeArchive(archive.path, stage.path, pack: true);
      return await saveLocalFile(archive);
    } finally {
      await stage.delete(recursive: true);
    }
  }

  Future<void> forgetWallpaper(MobileWallpaper choice) async {
    if (!_state.gallery.any((item) => item.id == choice.id)) return;
    await _change(
      (state) => state.copyWith(
        gallery: state.gallery.where((item) => item.id != choice.id).toList(),
        backgrounds: {
          for (final entry in state.backgrounds.entries)
            if (entry.value.wallpaper == choice.id)
              entry.key: (
                wallpaper: MobileWallpaper.none.id,
                strength: entry.value.strength,
              )
            else
              entry.key: entry.value,
        },
      ),
    );
    // Persist the library first so interrupted cleanup cannot leave a missing selection.
    final folder = _folder;
    if (folder != null && !_state.gallery.any((item) => item.id == choice.id)) {
      final image = _wallpapers.forId(folder, choice.id);
      if (await image.exists()) await image.delete();
    }
  }
}

class LanguageMenu extends StatelessWidget {
  const LanguageMenu({
    super.key,
    required this.preferences,
    this.compact = false,
  });

  final MobileAppearance preferences;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => PopupMenuButton<MobileLanguage>(
        tooltip: context.tr('界面语言'),
        position: PopupMenuPosition.under,
        onSelected: (language) async {
          try {
            await preferences.selectLanguage(language);
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(context.tr('无法保存界面语言'))));
            }
          }
        },
        itemBuilder: (context) => [
          for (final language in MobileLanguage.values)
            CheckedPopupMenuItem(
              value: language,
              checked: language == preferences.language,
              child: Text(context.tr(language.label)),
            ),
        ],
        icon: compact ? const Icon(Icons.language_rounded) : null,
        child: compact
            ? null
            : ListTile(
                leading: Icon(
                  Icons.language_rounded,
                  color: colors.onSurfaceVariant,
                  size: 21,
                ),
                title: Text(context.tr('界面语言')),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(context.tr(preferences.language.label)),
                    const SizedBox(width: 5),
                    const Icon(Icons.expand_more_rounded, size: 18),
                  ],
                ),
              ),
      ),
    );
  }
}

class MobileSettingsPage extends StatelessWidget {
  const MobileSettingsPage({
    super.key,
    required this.gateway,
    required this.profile,
    this.onGateway,
    this.appearance,
    this.notificationTarget,
  });
  final Gateway gateway;
  final String profile;
  final VoidCallback? onGateway;
  final MobileAppearance? appearance;
  final ConversationAlertTarget? notificationTarget;

  static const labels = {
    ThemeMode.system: '跟随系统',
    ThemeMode.light: '浅色',
    ThemeMode.dark: '深色',
  };

  @override
  Widget build(BuildContext context) {
    final prefs = appearance ?? MobileAppearance.shared;
    final colors = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: MobileShortcut.bind({
        MobileShortcut.dismiss: () => Navigator.of(context).maybePop(),
        MobileShortcut.settings: () => Navigator.of(context).maybePop(),
      }),
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        child: Scaffold(
          appBar: AppBar(title: Text(context.tr('设置'))),
          body: SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 650),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                  children: [
                    Text(
                      context.tr('常规'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    LanguageMenu(preferences: prefs),
                    ListenableBuilder(
                      listenable: prefs,
                      builder: (context, _) => SwitchListTile(
                        secondary: Icon(
                          Icons.restore_rounded,
                          color: colors.onSurfaceVariant,
                          size: 21,
                        ),
                        title: Text(context.tr('启动时恢复上次会话')),
                        subtitle: Text(context.tr('关闭后，启动时进入一个空白草稿。')),
                        value: prefs.restoreSession,
                        onChanged: (restore) async {
                          try {
                            await prefs.setRestoreSession(restore);
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(context.tr('无法保存启动设置'))),
                              );
                            }
                          }
                        },
                      ),
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.keyboard_outlined,
                        color: colors.onSurfaceVariant,
                        size: 21,
                      ),
                      title: Text(context.tr('键盘快捷键')),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => const KeyboardShortcutsPage(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      context.tr('外观'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    ListenableBuilder(
                      listenable: prefs,
                      builder: (context, _) => ListTile(
                        leading: Icon(
                          Icons.palette_outlined,
                          color: colors.onSurfaceVariant,
                          size: 21,
                        ),
                        title: Text(context.tr('主题与背景')),
                        subtitle: Text(
                          '${prefs.customTheme?.name ?? context.tr(prefs.palette.label)} · ${context.tr(labels[prefs.effectiveMode]!)}',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => AppearancePage(appearance: prefs),
                          ),
                        ),
                      ),
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: colors.onSurfaceVariant,
                        size: 21,
                      ),
                      title: Text(context.tr('聊天显示')),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => _ChatDisplayPage(appearance: prefs),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      context.tr('通知'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    NotificationSettings(previewTarget: notificationTarget),
                    const SizedBox(height: 24),
                    Text(
                      context.tr('网关连接'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      leading: Icon(
                        Icons.monitor_heart_outlined,
                        color: colors.onSurfaceVariant,
                        size: 21,
                      ),
                      title: Text(context.tr('网关状态')),
                      subtitle: StreamBuilder<Json>(
                        stream: gateway.events.where(
                          (e) => e['type'] == 'client.connection',
                        ),
                        builder: (context, _) => Text(
                          [
                            context.tr(gatewayLinkLabel(gateway.link)),
                            gateway.base.toString(),
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => GatewayStatusPage(
                            gateway: gateway,
                            profile: profile,
                            onSelectGateway: onGateway,
                          ),
                        ),
                      ),
                    ),
                    _AttachmentTransportTile(preferences: prefs),
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

class _AttachmentTransportTile extends StatelessWidget {
  const _AttachmentTransportTile({required this.preferences});

  final MobileAppearance preferences;

  String label(BuildContext context, AttachmentTransport transport) =>
      transport == AttachmentTransport.automatic ? context.tr('自动') : 'Base64';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) {
      final selected = preferences.attachmentTransport;
      final title = context.tr('附件上传方式');
      return PopupMenuButton<AttachmentTransport>(
        tooltip: title,
        initialValue: selected,
        onSelected: (value) async {
          try {
            await preferences.setAttachmentTransport(value);
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(context.tr('无法保存附件上传设置'))));
            }
          }
        },
        itemBuilder: (menu) => [
          for (final transport in AttachmentTransport.values)
            CheckedPopupMenuItem(
              value: transport,
              checked: transport == selected,
              child: Text(label(menu, transport)),
            ),
        ],
        child: ListTile(
          leading: const Icon(Icons.upload_file_outlined, size: 21),
          title: Text(title),
          subtitle: Text(
            context.tr(
              selected == AttachmentTransport.automatic
                  ? '优先使用 HTTP 上传'
                  : '通过网关连接上传',
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label(context, selected)),
              const SizedBox(width: 5),
              const Icon(Icons.expand_more_rounded, size: 18),
            ],
          ),
        ),
      );
    },
  );
}
