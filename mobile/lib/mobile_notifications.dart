import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'gateway.dart';
import 'transcript_navigation.dart';

class ConversationAlertTarget {
  const ConversationAlertTarget({
    required this.owner,
    required this.profile,
    required this.session,
    required this.title,
    this.prompt,
    this.reply = false,
    this.message,
  });

  final String owner, profile, session, title;
  final String? prompt;
  final bool reply;
  final MessageAddress? message;

  static String ownerFor(Gateway gateway) => _ownerFor(gateway.base);

  bool belongsToAddress(String address) {
    try {
      return owner == _ownerFor(Gateway.parseAddress(address));
    } on GatewayError {
      return false;
    }
  }

  static String _ownerFor(Uri address) =>
      sha256.convert(utf8.encode(address.toString())).toString();

  static ConversationAlertTarget? parse(String raw) {
    final data = jsonDecode(raw);
    if (data is! Json) return null;
    final owner = data['owner'];
    final profile = data['profile'];
    final session = data['session'];
    final title = data['title'];
    final sent = data['sent'];
    if (owner is! String ||
        profile is! String ||
        profile.isEmpty ||
        session is! String ||
        session.isEmpty ||
        title is! String ||
        sent is! int) {
      return null;
    }
    final age = DateTime.now().millisecondsSinceEpoch - sent;
    if (age < 0 || age > const Duration(hours: 1).inMilliseconds) return null;
    final prompt = data['prompt'];
    final message = data['message'];
    return ConversationAlertTarget(
      owner: owner,
      profile: profile,
      session: session,
      title: title,
      prompt: prompt is String ? prompt : null,
      reply: data['reply'] == true,
      message: message is Json ? MessageAddress.fromWire(message) : null,
    );
  }

  String toRoute() => jsonEncode({
    'owner': owner,
    'profile': profile,
    'session': session,
    'title': title,
    'prompt': ?prompt,
    if (reply) 'reply': true,
    'message': ?message?.toWire(),
    'sent': DateTime.now().millisecondsSinceEpoch,
  });

  String get promptTag => sha256
      .convert(utf8.encode(jsonEncode([owner, profile, session, prompt])))
      .toString();
}

class _PostedPrompt {
  _PostedPrompt(this.target, this.route, {this.delivered = false});

  final ConversationAlertTarget target;
  final String route;
  bool delivered;
}

class MobileNotifications extends ChangeNotifier {
  MobileNotifications._();
  static final shared = MobileNotifications._();
  static const _platform = MethodChannel('hermes_lite/notifications');
  static const _storage = FlutterSecureStorage();
  static const _key = 'hermes.mobile.notifications.v1';
  static const _promptKey = 'hermes.mobile.notification-prompts.v1';

  final opened = ValueNotifier<ConversationAlertTarget?>(null);
  final _postedPrompts = <String, _PostedPrompt>{};
  Future<void> _promptWrite = Future<void>.value();
  bool prompts = false, replies = false;
  bool ready = false;
  MobileLanguage Function()? _language;

  Future<void> initialize({MobileLanguage Function()? language}) async {
    _language = language;
    _platform.setMethodCallHandler((call) async {
      if (call.method == 'opened') await takeOpened();
    });
    final activation = takeOpened();
    try {
      final data = await _storage.read(key: _key);
      if (data != null) {
        final saved = jsonDecode(data);
        if (saved is Json) {
          prompts = saved['prompts'] == true;
          replies = saved['replies'] == true;
        }
      }
    } on PlatformException {
      // Keep the defaults if secure storage is unavailable.
    } on FormatException {
      // An invalid stored preference should not disable the settings UI.
    }
    await _restorePrompts();
    ready = true;
    notifyListeners();
    await activation;
  }

  Future<void> _restorePrompts() async {
    try {
      final raw = await _storage.read(key: _promptKey);
      if (raw == null) return;
      final entries = jsonDecode(raw);
      if (entries is! Json) return;
      var expired = false;
      for (final entry in entries.entries) {
        final route = entry.value;
        if (route is! String) continue;
        final target = ConversationAlertTarget.parse(route);
        if (target == null ||
            target.prompt == null ||
            target.promptTag != entry.key) {
          _removePrompt(entry.key);
          expired = true;
        } else {
          _postedPrompts.putIfAbsent(
            entry.key,
            () => _PostedPrompt(target, route, delivered: true),
          );
        }
      }
      if (expired) _savePrompts();
    } on PlatformException {
      // Notification reconciliation is independent of gateway startup.
    } on FormatException {
      // Only locally generated notification routes are restored.
    }
  }

  void _savePrompts() {
    final routes = jsonEncode({
      for (final entry in _postedPrompts.entries)
        if (entry.value.delivered) entry.key: entry.value.route,
    });
    _promptWrite = _promptWrite.then((_) async {
      try {
        await _storage.write(key: _promptKey, value: routes);
      } on PlatformException {
        // The in-memory index still covers this application process.
      }
    });
  }

  Future<void> takeOpened() async {
    try {
      final raw = await _platform.invokeMethod<String>('takeOpened');
      if (raw != null) {
        if (ConversationAlertTarget.parse(raw) case final next?) {
          opened.value = next;
        }
      }
    } on MissingPluginException {
      // The platform may not implement local notification activation.
    } on PlatformException {
      // Notification activation is independent of gateway startup.
    } on FormatException {
      // Discard invalid or expired native payloads.
    }
  }

  Future<bool> status() async {
    try {
      return await _platform.invokeMethod<bool>('status') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> openSystemSettings() => _platform.invokeMethod<void>('settings');

  Future<bool> setEnabled({bool? prompts, bool? replies}) async {
    final nextPrompts = prompts ?? this.prompts;
    final nextReplies = replies ?? this.replies;
    final enabling =
        nextPrompts && !this.prompts || nextReplies && !this.replies;
    if (enabling &&
        !await status() &&
        await _platform.invokeMethod<bool>('request') != true) {
      return false;
    }
    await _storage.write(
      key: _key,
      value: jsonEncode({'prompts': nextPrompts, 'replies': nextReplies}),
    );
    this.prompts = nextPrompts;
    this.replies = nextReplies;
    notifyListeners();
    return true;
  }

  bool get _background {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused;
  }

  void prompt(ConversationAlertTarget target, {required bool approval}) {
    final tag = target.promptTag;
    if (!prompts || !_background || _postedPrompts.containsKey(tag)) {
      return;
    }
    final attempt = _postedPrompts[tag] = _PostedPrompt(target, target.toRoute());
    if (_postedPrompts.length > 64) {
      _forgetPrompt(_postedPrompts.keys.first);
    }
    unawaited(
      _post(tag, approval ? '等待你审批' : '等待你回答', target).then((posted) {
        if (!identical(_postedPrompts[tag], attempt)) {
          if (posted && !_postedPrompts.containsKey(tag)) _removePrompt(tag);
          return;
        }
        if (posted) {
          attempt.delivered = true;
          _savePrompts();
        } else {
          _postedPrompts.remove(tag);
        }
      }),
    );
  }

  void clearPrompt(ConversationAlertTarget target) =>
      _forgetPrompt(target.promptTag);

  void reconcilePrompts(ConversationAlertTarget scope, Iterable<String> active) {
    final expired = _postedPrompts.entries
        .where((entry) {
          final target = entry.value.target;
          return target.owner == scope.owner &&
              target.profile == scope.profile &&
              target.session == scope.session &&
              !active.contains(target.prompt);
        })
        .map((entry) => entry.key)
        .toList();
    for (final tag in expired) {
      _forgetPrompt(tag);
    }
  }

  void _forgetPrompt(String tag) {
    final removed = _postedPrompts.remove(tag);
    if (removed?.delivered == true) _savePrompts();
    if (ready) _removePrompt(tag);
  }

  void _removePrompt(String tag) {
    unawaited(
      _platform
          .invokeMethod<void>('remove', tag)
          .catchError((Object _) {}),
    );
  }

  void reply(ConversationAlertTarget target) {
    if (!replies || !_background) return;
    unawaited(_post(target.promptTag, '回复已完成', target));
  }

  Future<bool> preview(ConversationAlertTarget? target) =>
      _post('hermes-notification-preview', 'Hermes Lite · 通知预览', target);

  Future<bool> _post(
    String id,
    String title,
    ConversationAlertTarget? target,
  ) async {
    try {
      final strings = MobileStrings(
        (_language?.call() ?? MobileLanguage.system).effectiveLocale,
      );
      return await _platform.invokeMethod<bool>('post', {
            'id': id,
            'title': strings.text(title),
            'body': target == null
                ? strings.text('系统通知可用')
                : '${strings.profileName(target.profile)} · ${target.title}',
            'route': ?target?.toRoute(),
          }) ==
          true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

class NotificationSettings extends StatefulWidget {
  const NotificationSettings({super.key, this.previewTarget});
  final ConversationAlertTarget? previewTarget;

  @override
  State<NotificationSettings> createState() => _NotificationSettingsState();
}

class _NotificationSettingsState extends State<NotificationSettings> {
  final alerts = MobileNotifications.shared;
  late final AppLifecycleListener lifecycle;
  bool allowed = false, busy = false, attempted = false;

  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(onResume: refresh);
    unawaited(refresh());
  }

  @override
  void dispose() {
    lifecycle.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    final state = await alerts.status();
    if (mounted) setState(() => allowed = state);
  }

  Future<void> update({bool? prompts, bool? replies}) async {
    setState(() => busy = true);
    try {
      final result = await alerts.setEnabled(
        prompts: prompts,
        replies: replies,
      );
      if (!mounted) return;
      if (!result) setState(() => attempted = true);
      await refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('无法保存通知设置'))));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: alerts,
    builder: (context, _) => Column(
      children: <Widget>[
        SwitchListTile.adaptive(
          title: Text(context.tr('等待回答或审批')),
          value: alerts.prompts,
          onChanged: busy || !alerts.ready
              ? null
              : (value) => update(prompts: value),
        ),
        SwitchListTile.adaptive(
          title: Text(context.tr('回复完成')),
          value: alerts.replies,
          onChanged: busy || !alerts.ready
              ? null
              : (value) => update(replies: value),
        ),
        if (!allowed && (attempted || alerts.prompts || alerts.replies))
          ListTile(
            title: Text(context.tr('打开系统通知设置')),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: alerts.openSystemSettings,
          ),
        if (allowed)
          ListTile(
            title: Text(context.tr('发送预览通知')),
            trailing: const Icon(Icons.notifications_active_outlined, size: 20),
            onTap: () async {
              if (!await alerts.preview(widget.previewTarget) &&
                  context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(context.tr('暂时无法发送通知'))));
              }
            },
          ),
      ].map((row) => Semantics(container: true, child: row)).toList(),
    ),
  );
}
