import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

part 'mobile_locale_en.dart';

enum MobileLanguage {
  system(null, '跟随系统'),
  simplifiedChinese(
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    '简体中文',
  ),
  english(Locale('en'), 'English');

  const MobileLanguage(this.locale, this.label);

  final Locale? locale;
  final String label;

  Locale get effectiveLocale =>
      locale ??
      basicLocaleListResolution(
        WidgetsBinding.instance.platformDispatcher.locales,
        MobileStrings.supported,
      );

  static MobileLanguage fromStorage(Object? value) =>
      values.where((language) => language.name == value).firstOrNull ?? system;
}

class MobileStrings {
  const MobileStrings(this.locale);

  final Locale locale;

  static const supported = [
    Locale('en'),
    Locale('zh'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  ];
  static const delegate = _MobileStringsDelegate();

  String text(String source) {
    if (locale.languageCode == 'zh') return source;
    if (_english[source] case final String translated) return translated;
    if (_httpFailure.firstMatch(source) case final Match failure) {
      return format('网关请求失败（HTTP {code}）', {'code': failure[1]!});
    }
    return source;
  }

  String profileName(String name) => name == 'default' ? text('默认') : name;

  String format(String source, Map<String, Object> arguments) {
    final singular = _englishSingular[source];
    final template =
        locale.languageCode != 'zh' &&
            singular != null &&
            arguments[singular.argument]?.toString() == '1'
        ? singular.template
        : text(source);
    return template.replaceAllMapped(
      _argument,
      (match) => arguments[match.group(1)]?.toString() ?? match[0]!,
    );
  }

  static final _argument = RegExp(r'\{([a-zA-Z][a-zA-Z0-9]*)\}');
  static final _httpFailure = RegExp(r'^网关请求失败（HTTP ([0-9]{3})）$');
}

class _MobileStringsDelegate extends LocalizationsDelegate<MobileStrings> {
  const _MobileStringsDelegate();

  @override
  bool isSupported(Locale locale) => MobileStrings.supported.any(
    (candidate) => candidate.languageCode == locale.languageCode,
  );

  @override
  Future<MobileStrings> load(Locale locale) =>
      SynchronousFuture(MobileStrings(locale));

  @override
  bool shouldReload(_MobileStringsDelegate old) => false;
}

extension MobileLocaleContext on BuildContext {
  MobileStrings get strings =>
      Localizations.of<MobileStrings>(this, MobileStrings) ??
      MobileStrings(Localizations.maybeLocaleOf(this) ?? const Locale('zh'));

  String tr(String source) => strings.text(source);
}
