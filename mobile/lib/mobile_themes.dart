import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:material_ui/material_ui.dart';

import 'gateway.dart';
import 'protocol.dart';

enum ThemeFont {
  interface('界面字体'),
  code('代码字体');

  const ThemeFont(this.label);
  final String label;

  String? resolve(String? name) => switch (name) {
    'serif' when Platform.isIOS => 'Georgia',
    'sans-serif' when Platform.isIOS => 'Helvetica Neue',
    'monospace' when Platform.isIOS => 'Menlo',
    _ => name,
  };
}

enum ThemeColor {
  canvas('聊天背景'),
  surface('面板背景'),
  chrome('顶部栏'),
  line('分隔线'),
  selection('选中项'),
  message('消息气泡'),
  accent('强调色'),
  primary('主按钮'),
  foreground('正文'),
  muted('次要文字'),
  link('链接'),
  positive('成功'),
  warning('提示'),
  danger('错误'),
  code('代码背景', required: false),
  composer('输入区', required: false),
  sidebar('会话侧栏', required: false);

  const ThemeColor(this.label, {this.required = true});
  final String label;
  final bool required;

  Color fromScheme(ColorScheme scheme) => switch (this) {
    canvas || surface => scheme.surface,
    chrome || sidebar => scheme.surfaceContainerLow,
    line => scheme.outlineVariant,
    selection || message => scheme.secondaryContainer,
    accent || primary || link => scheme.primary,
    foreground => scheme.onSurface,
    muted => scheme.onSurfaceVariant,
    positive =>
      scheme.brightness == Brightness.dark
          ? const Color(0xff7ed6b6)
          : const Color(0xff248365),
    warning =>
      scheme.brightness == Brightness.dark
          ? const Color(0xffe4bd75)
          : const Color(0xff95611f),
    danger => scheme.error,
    code => scheme.surfaceContainerHighest,
    composer => scheme.surface,
  };
}

Color? parseThemeColor(Object? value) {
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    return null;
  }
  return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}

String themeHex(Color color) =>
    '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

bool validThemeName(Object? text) =>
    text is String &&
    text.trim().isNotEmpty &&
    text.runes.length <= 100 &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(text);

class MobileTheme {
  MobileTheme({
    required this.id,
    required this.name,
    required this.brightness,
    required Map<ThemeColor, Color> colors,
    this.author,
    this.fonts,
    this.windowTransparency = 0,
  }) : colors = Map.unmodifiable(colors);

  final String id, name;
  final Brightness brightness;
  final Map<ThemeColor, Color> colors;
  final String? author;
  final Json? fonts;
  final int windowTransparency;

  String? font(ThemeFont role) => fonts?[role.name] as String?;

  factory MobileTheme.fromScheme(String id, String name, ColorScheme scheme) =>
      MobileTheme(
        id: id,
        name: name,
        brightness: scheme.brightness,
        colors: {
          for (final role in ThemeColor.values)
            if (role.required) role: role.fromScheme(scheme),
        },
      );

  factory MobileTheme.parse(Json wire) {
    final id = wire['id'];
    final name = wire['name'];
    final appearance = wire['appearance'];
    final colors = wire['colors'];
    final author = wire['author'];
    final fonts = wire['fonts'];
    final transparency = wire['window_transparency'] ?? 0;
    final validId =
        id is String &&
        RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(id) &&
        !const {'default', 'pink', 'paper', 'terminal'}.contains(id);
    if (wire['schema_version'] != 1 ||
        !validId ||
        !validThemeName(name) ||
        !const {'light', 'dark'}.contains(appearance) ||
        colors is! Json ||
        (author != null && !validThemeName(author)) ||
        (fonts != null &&
            (fonts is! Json ||
                fonts.entries.any(
                  (pair) =>
                      !const {'interface', 'code'}.contains(pair.key) ||
                      (pair.value != null && !validThemeName(pair.value)),
                ))) ||
        transparency is! int ||
        transparency < 0 ||
        transparency > 60) {
      throw GatewayError('主题包的名称、版本或外观设置无效');
    }
    final parsed = <ThemeColor, Color>{};
    for (final role in ThemeColor.values) {
      if (parseThemeColor(colors[role.name]) case final value?) {
        parsed[role] = value;
      } else if (role.required || colors[role.name] != null) {
        throw GatewayError('主题包的配色格式无效');
      }
    }
    if (colors.keys.any(
      (name) => !ThemeColor.values.any((role) => role.name == name),
    )) {
      throw GatewayError('主题包包含未知配色');
    }
    return MobileTheme(
      id: id,
      name: name as String,
      brightness: appearance == 'dark' ? Brightness.dark : Brightness.light,
      colors: parsed,
      author: author as String?,
      fonts: fonts as Json?,
      windowTransparency: transparency,
    );
  }

  MobileTheme changed({
    String? name,
    Brightness? brightness,
    Map<ThemeColor, Color>? colors,
    Json? fonts,
  }) => MobileTheme(
    id: id,
    name: name ?? this.name,
    brightness: brightness ?? this.brightness,
    colors: colors ?? this.colors,
    author: author,
    fonts: fonts ?? this.fonts,
    windowTransparency: windowTransparency,
  );

  Json toWire({int? wallpaperOpacity}) => {
    'schema_version': 1,
    'id': id,
    'name': name,
    'appearance': brightness.name,
    'colors': {
      for (final color in colors.entries) color.key.name: themeHex(color.value),
    },
    'author': ?author,
    if (fonts?.isNotEmpty == true) 'fonts': fonts,
    if (wallpaperOpacity != null) 'background': {'opacity': wallpaperOpacity},
    'window_transparency': windowTransparency,
  };

  Color color(ThemeColor role) {
    if (colors[role] case final value?) return value;
    return switch (role) {
      ThemeColor.code || ThemeColor.sidebar => colors[ThemeColor.chrome]!,
      ThemeColor.composer => colors[ThemeColor.surface]!,
      _ => throw ArgumentError.value(role),
    };
  }

  ColorScheme scheme() {
    final seeded = ColorScheme.fromSeed(
      seedColor: color(ThemeColor.accent),
      brightness: brightness,
    );
    final primary = color(ThemeColor.primary);
    final error = color(ThemeColor.danger);
    final ink = color(ThemeColor.foreground);
    Color contrast(Color background) =>
        background.computeLuminance() > .179 ? Colors.black : Colors.white;
    return seeded.copyWith(
      primary: primary,
      onPrimary: contrast(primary),
      secondary: color(ThemeColor.accent),
      secondaryContainer: color(ThemeColor.message),
      onSecondaryContainer: ink,
      surface: color(ThemeColor.surface),
      onSurface: ink,
      surfaceContainerLow: color(ThemeColor.chrome),
      surfaceContainerHigh: color(ThemeColor.selection),
      surfaceContainerHighest: color(ThemeColor.code),
      onSurfaceVariant: color(ThemeColor.muted),
      outline: color(ThemeColor.line),
      outlineVariant: color(ThemeColor.line),
      error: error,
      onError: contrast(error),
    );
  }
}

class CustomThemeTokens extends ThemeExtension<CustomThemeTokens> {
  const CustomThemeTokens(this.theme);
  final MobileTheme theme;

  static Color? read(BuildContext context, ThemeColor role) =>
      Theme.of(context).extension<CustomThemeTokens>()?.theme.color(role);

  static TextStyle codeStyle(BuildContext context) {
    const role = ThemeFont.code;
    final selected = Theme.of(context)
        .extension<CustomThemeTokens>()
        ?.theme
        .font(role);
    final fallback = role.resolve('monospace')!;
    return TextStyle(
      fontFamily: role.resolve(selected) ?? 'monospace',
      fontFamilyFallback: [fallback],
    );
  }

  @override
  CustomThemeTokens copyWith({MobileTheme? theme}) =>
      CustomThemeTokens(theme ?? this.theme);

  @override
  CustomThemeTokens lerp(covariant CustomThemeTokens? other, double t) =>
      (t < .5 ? this : other) ?? this;
}

const themeArchiveLimit = 16 * 1024 * 1024 + 128 * 1024;

Future<void> runThemeArchive(
  String path,
  String directory, {
  required bool pack,
}) async {
  final result = await Isolate.run(
    () => themeArchive(path, directory, pack: pack),
  );
  if (result == 0) return;
  throw GatewayError(switch (result) {
    2 => '主题包或背景图超过主题包大小限制',
    3 => '无法读取或保存主题包',
    _ => '主题包格式无效',
  });
}

Future<Json> readThemeManifest(File file) async {
  try {
    final data = jsonDecode(await file.readAsString(encoding: utf8));
    if (data is Json) return data;
  } on FormatException {
    // A theme envelope must contain an object.
  }
  throw GatewayError('主题包配色文件无效');
}
