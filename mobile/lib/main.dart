import 'package:material_ui/material_ui.dart';

import 'dart:async';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:uuid/uuid.dart';

import 'appearance.dart';
import 'gateway_book.dart';
import 'gateway_switcher.dart';
import 'incoming_share.dart';
import 'chat.dart';
import 'chat_tabs.dart';
import 'composer_attachments.dart';
import 'chat_tab_strip.dart';
import 'tab_switcher.dart';
import 'ui_kit.dart';
import 'chat_tab_viewport.dart';
import 'gateway.dart';
import 'profiles.dart';
import 'profile_manager.dart';
import 'cron_page.dart';
import 'library_shortcuts.dart';
import 'session_export.dart';
import 'session_branch.dart';
import 'transcript_explorer.dart';
import 'transcript_navigation.dart';
import 'turn_corrections.dart';
import 'session_activity.dart';
import 'session_library.dart';
import 'session_colors.dart';
import 'command_receipts.dart';
import 'mobile_settings.dart';
import 'mobile_themes.dart';
import 'mobile_notifications.dart';
import 'mobile_photo_picker.dart';
import 'mobile_locale.dart';
import 'mobile_wake.dart';
import 'mobile_wake_view.dart';
import 'mobile_shortcuts.dart';
import 'split_pane.dart';
import 'workspace.dart';

part 'session_metadata.dart';

void main() => runApp(const HermesMobile());

class HermesMobile extends StatefulWidget {
  const HermesMobile({super.key});
  @override
  State<HermesMobile> createState() => _HermesMobileState();
}

class _HermesMobileState extends State<HermesMobile> {
  final appearance = MobileAppearance.shared;
  late final Future<void> appearanceReady;
  late final Future<void> notificationsReady;

  @override
  void initState() {
    super.initState();
    appearanceReady = appearance.load().catchError((Object _) {});
    unawaited(AndroidDraftPhotos.shared.start().catchError((Object _) {}));
    notificationsReady = MobileNotifications.shared
        .initialize(language: () => appearance.language)
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) => MaterialApp(
        title: 'Hermes Lite',
        debugShowCheckedModeBanner: false,
        locale: appearance.language.locale,
        supportedLocales: MobileStrings.supported,
        localizationsDelegates: const [
          MobileStrings.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        theme: liteTheme(
          Brightness.light,
          appearance.palette,
          appearance.customTheme,
        ),
        darkTheme: liteTheme(
          Brightness.dark,
          appearance.palette,
          appearance.customTheme,
        ),
        themeMode: appearance.effectiveMode,
        builder: (context, child) => AnnotatedRegion(
          value: liteSystemChrome(Theme.of(context).colorScheme),
          child: child!,
        ),
        home: ConnectPage(
          appearanceReady: appearanceReady,
          notificationsReady: notificationsReady,
        ),
      ),
    );
  }
}

class ConnectPage extends StatefulWidget {
  const ConnectPage({
    super.key,
    this.appearanceReady,
    this.notificationsReady,
    this.selectionBook,
    this.selectionActive,
    this.initialGateway,
  });
  final Future<void>? appearanceReady;
  final Future<void>? notificationsReady;
  final GatewayBook? selectionBook;
  final Gateway? selectionActive;
  final SavedGateway? initialGateway;
  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final address = TextEditingController(), token = TextEditingController();
  late final book = widget.selectionBook ?? GatewayBook();
  bool busy = true, useToken = false, switching = false;
  bool testing = false;
  ({String? version})? checked;
  Gateway? pendingClient;
  bool get selecting => widget.selectionBook != null;
  Gateway? startupGateway;
  StreamSubscription<Json>? startupEvents;
  late final AppLifecycleListener startupLifecycle;
  @override
  void initState() {
    super.initState();
    startupLifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(startupGateway?.retry());
      },
    );
    if (selecting) {
      busy = false;
      if (widget.initialGateway case final saved?) {
        address.text = saved.address;
        useToken = saved.usesToken;
      }
    } else {
      restore();
    }
  }

  Future<void> restore() async {
    try {
      await book.load();
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '无法读取已保存的网关';
        });
      }
      return;
    }
    if (book.entries.isNotEmpty) await widget.notificationsReady;
    if (!mounted) return;
    setState(() => busy = false);
    if (book.entries.isNotEmpty) {
      final target = MobileNotifications.shared.opened.value;
      final requested = target == null
          ? null
          : book.entries
                .where((saved) => target.belongsToAddress(saved.address))
                .firstOrNull;
      await restoreGateway(requested ?? book.entries.first);
    }
  }

  Future<void> restoreGateway(SavedGateway saved) async {
    if (!saved.hasCredentials) {
      setState(() {
        address.text = saved.address;
        useToken = saved.usesToken;
      });
      return;
    }
    final Gateway client;
    try {
      client = Gateway(saved.address, saved.token)..session = saved.session;
    } on GatewayError catch (failure) {
      setState(() => error = failure.message);
      return;
    }
    trackGatewaySession(client, saved);
    startupEvents = client.events.listen((event) {
      if (!mounted ||
          !identical(startupGateway, client) ||
          event['type'] != 'client.connection') {
        return;
      }
      if (client.link == GatewayLink.online) {
        stopStartup(close: false);
        unawaited(finishConnection(client, startup: true));
      } else if (client.link == GatewayLink.signIn) {
        stopStartup();
        setState(() => error = '登录已过期，请重新连接网关');
      }
    });
    setState(() {
      startupGateway = client;
      address.text = saved.address;
      useToken = saved.usesToken;
    });
    await client.restoreSavedConnection();
  }

  void stopStartup({bool close = true}) {
    final client = startupGateway;
    if (client == null) return;
    startupGateway = null;
    unawaited(startupEvents?.cancel());
    startupEvents = null;
    if (close) client.close();
  }

  void cancelStartup() {
    if (startupGateway != null) setState(stopStartup);
  }

  Future<void> forget(SavedGateway item) async {
    if (startupGateway?.base.toString() == item.address) cancelStartup();
    try {
      await book.forget(item.address);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => error = '无法移除已保存的网关');
    }
  }

  String? error;
  @override
  void dispose() {
    startupLifecycle.dispose();
    stopStartup();
    pendingClient?.close();
    address.dispose();
    token.dispose();
    super.dispose();
  }

  Future<Gateway> openGateway(
    SavedGateway entry, {
    bool allowBrowser = true,
    bool ownedByForm = false,
  }) async {
    if (entry.usesToken && !entry.hasCredentials) {
      throw GatewayError('请输入访问令牌');
    }
    final client = Gateway(
      entry.address,
      entry.token,
      browserSuccessText: () =>
          MobileStrings(MobileAppearance.shared.language.effectiveLocale)
              .text('可以返回 Hermes Lite。'),
    )..session = entry.session;
    if (ownedByForm) pendingClient = client;
    if (book.entries.any((saved) => identical(saved, entry))) {
      trackGatewaySession(client, entry);
    }
    try {
      await client.connect(allowBrowser: allowBrowser);
      return client;
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  SavedGateway formGateway() {
    final origin = Gateway.parseAddress(address.text).toString();
    final input = useToken ? token.text.trim() : '';
    if (input.isNotEmpty) return SavedGateway(origin, input, null);
    final saved = book.entries
        .where(
          (entry) => entry.address == origin && entry.usesToken == useToken,
        )
        .firstOrNull;
    if (saved != null && (!useToken || saved.hasCredentials)) return saved;
    if (useToken) throw GatewayError('请输入访问令牌');
    return SavedGateway(origin, '', null);
  }

  Future<String?> checkGateway(
    SavedGateway entry, {
    Gateway? active,
    bool ownedByForm = false,
  }) async {
    if (!entry.hasCredentials) throw GatewayError('请先登录此网关');
    if (active != null &&
        active.base.toString() == entry.address &&
        active.token == entry.token) {
      await active.verifyConnection();
      return active.version;
    }
    final probe = await openGateway(
      entry,
      allowBrowser: false,
      ownedByForm: ownedByForm,
    );
    try {
      await probe.verifyConnection();
      return probe.version;
    } finally {
      probe.close();
    }
  }

  Future<void> testFormGateway() async {
    if (busy) return;
    stopStartup();
    setState(() {
      busy = true;
      testing = true;
      checked = null;
      error = null;
    });
    try {
      final version = await checkGateway(
        formGateway(),
        active: widget.selectionActive,
        ownedByForm: true,
      );
      if (mounted) setState(() => checked = (version: version));
    } catch (failure) {
      showConnectionError(failure);
    } finally {
      pendingClient = null;
      if (mounted) {
        setState(() {
          busy = false;
          testing = false;
        });
      }
    }
  }

  void clearGatewayFeedback() {
    setState(() {
      stopStartup();
      checked = null;
      error = null;
    });
  }

  Future<void> rememberGateway(Gateway client) async {
    final address = client.base.toString();
    final saved = SavedGateway(address, client.token, client.session);
    await book.remember(saved);
    trackGatewaySession(client, saved);
  }

  void trackGatewaySession(Gateway client, SavedGateway saved) {
    var recorded = saved;
    client.onSession = (session) async {
      final updated = SavedGateway(recorded.address, client.token, session);
      await book.refresh(recorded, updated);
      recorded = updated;
    };
  }

  Future<void> switchGateway(
    BuildContext workspace,
    ValueNotifier<Gateway> active,
  ) async {
    if (switching || !workspace.mounted) return;
    switching = true;
    final previous = active.value;
    Gateway? next;
    try {
      final result = await showGatewaySwitcher(
        workspace,
        active: previous,
        book: book,
        connect: (saved) async {
          try {
            return await openGateway(
              previous.link == GatewayLink.signIn &&
                      previous.base.toString() == saved.address
                  ? SavedGateway(saved.address, saved.token, null)
                  : saved,
              ownedByForm: true,
            );
          } finally {
            pendingClient = null;
          }
        },
        check: (saved) =>
            checkGateway(saved, active: previous, ownedByForm: true),
        add: (sheet, {saved}) => Navigator.of(sheet).push<Gateway>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => ConnectPage(
              selectionBook: book,
              selectionActive: previous,
              initialGateway: saved,
            ),
          ),
        ),
        cancelPending: () => pendingClient?.close(),
      );
      next = result?.gateway;
      if (!workspace.mounted || result == null) return;
      final navigation = Navigator.of(workspace);
      if (result.leave case final action?) {
        try {
          if (action == SavedGatewayAction.forget) {
            await book.forget(previous.base.toString());
          } else {
            await book.signOut(previous.base.toString());
          }
        } catch (_) {
          throw GatewayError(
            action == SavedGatewayAction.forget ? '无法移除已保存的网关' : '无法退出本机登录',
          );
        }
        previous.close();
        if (workspace.mounted) {
          address.text = previous.base.toString();
          useToken = previous.token.isNotEmpty;
          token.clear();
          checked = null;
          error = null;
          navigation.popUntil((route) => route.isFirst);
        }
      } else if (next != null) {
        await rememberGateway(next);
        if (!workspace.mounted) return;
        final route = ModalRoute.of(workspace);
        navigation.popUntil((entry) => entry == route);
        active.value = next;
        next = null;
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.close());
      }
    } catch (error) {
      if (workspace.mounted) {
        ScaffoldMessenger.of(
          workspace,
        ).showSnackBar(SnackBar(content: Text(workspace.tr(error.toString()))));
      }
    } finally {
      next?.close();
      switching = false;
    }
  }

  Future<void> connect({SavedGateway? saved}) async {
    if (busy) return;
    stopStartup();
    setState(() {
      busy = true;
      checked = null;
      error = null;
    });
    try {
      if (saved != null) {
        address.text = saved.address;
        useToken = saved.usesToken;
        token.clear();
      }
      final client = await openGateway(
        saved ?? formGateway(),
        ownedByForm: true,
      );
      pendingClient = null;
      if (selecting) {
        if (mounted && ModalRoute.isCurrentOf(context) == true) {
          Navigator.pop<Gateway>(context, client);
        } else {
          client.close();
        }
      } else {
        await finishConnection(client);
      }
    } catch (failure) {
      showConnectionError(failure);
    } finally {
      pendingClient = null;
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> finishConnection(Gateway client, {bool startup = false}) async {
    final workspace = ValueNotifier(client);
    try {
      if (!mounted) return;
      setState(() => busy = true);
      await rememberGateway(client);
      if (startup) await widget.appearanceReady;
      if (!mounted) return;
      token.clear();
      final startInDraft = startup && !MobileAppearance.shared.restoreSession;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ValueListenableBuilder(
            valueListenable: workspace,
            builder: (context, gateway, _) => SessionsPage(
              key: ObjectKey(gateway),
              gateway: gateway,
              startInDraft: identical(gateway, client) && startInDraft,
              onSwitchGateway: () => switchGateway(context, workspace),
            ),
          ),
        ),
      );
    } catch (failure) {
      showConnectionError(failure);
    } finally {
      workspace.value.close();
      workspace.dispose();
      if (mounted) setState(() => busy = false);
    }
  }

  void showConnectionError(Object failure) {
    if (!mounted) return;
    setState(
      () =>
          error = failure is GatewayError && {401, 403}.contains(failure.status)
          ? '登录已过期，请重新连接网关'
          : failure.toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: c.surface,
      appBar: selecting ? AppBar(title: Text(context.tr('添加网关'))) : null,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(28, 28, 28, 32),
              children: [
                Row(
                  children: [
                    const BrandMark(size: 57),
                    const Spacer(),
                    LanguageMenu(
                      preferences: MobileAppearance.shared,
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 17),
                const Text(
                  'Hermes Lite',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.35,
                    height: 1.12,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  context.tr('连接网关'),
                  style: TextStyle(color: c.onSurfaceVariant, fontSize: 15),
                ),
                const SizedBox(height: 26),
                TextField(
                  controller: address,
                  enabled: !busy,
                  onChanged: (_) => clearGatewayFeedback(),
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: context.tr('网关地址'),
                    hintText: 'https://',
                    prefixIcon: Icon(Icons.link_rounded, size: 21),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: c.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    children: [
                      for (final v in [false, true])
                        Expanded(
                          child: Semantics(
                            selected: useToken == v,
                            child: Material(
                              color: useToken == v
                                  ? c.surface
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(21),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(21),
                                onTap: busy
                                    ? null
                                    : () => setState(() {
                                        stopStartup();
                                        useToken = v;
                                        checked = null;
                                        error = null;
                                      }),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  child: Text(
                                    context.tr(v ? '访问令牌' : '浏览器登录'),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: useToken == v
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                      color: useToken == v
                                          ? c.primary
                                          : c.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (useToken)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextField(
                      controller: token,
                      enabled: !busy,
                      onChanged: (_) => clearGatewayFeedback(),
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: context.tr('访问令牌'),
                      ),
                    ),
                  ),
                if (startupGateway != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 9),
                        Expanded(child: Text(context.tr('正在恢复网关连接…'))),
                        TextButton(
                          onPressed: cancelStartup,
                          child: Text(context.tr('取消自动恢复')),
                        ),
                      ],
                    ),
                  ),
                if (error != null || checked != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      error != null
                          ? context.tr(error!)
                          : [
                              context.tr('连接与认证通过'),
                              ?checked?.version,
                            ].join(' · '),
                      style: TextStyle(
                        color: error != null ? c.error : c.primary,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: busy ? null : () => connect(),
                  icon: Icon(
                    busy ? Icons.more_horiz : Icons.arrow_forward,
                    size: 18,
                  ),
                  label: Text(
                    busy && !testing ? context.tr('正在连接…') : context.tr('连接'),
                  ),
                ),
                TextButton.icon(
                  onPressed: busy ? null : testFormGateway,
                  icon: testing
                      ? const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check_rounded, size: 19),
                  label: Text(context.tr(testing ? '正在测试连接…' : '测试连接')),
                ),
                if (!selecting && book.entries.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  Text(
                    context.tr('最近使用'),
                    style: TextStyle(
                      color: c.onSurfaceVariant,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  for (final saved in book.entries)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 5),
                      leading: Icon(
                        Icons.history_rounded,
                        color: c.onSurfaceVariant,
                      ),
                      title: Text(
                        saved.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: busy ? null : () => connect(saved: saved),
                      trailing: IconButton(
                        tooltip: context.tr('移除已保存的网关'),
                        onPressed: busy ? null : () => forget(saved),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SessionsPage extends StatefulWidget {
  const SessionsPage({
    super.key,
    required this.gateway,
    this.startInDraft = false,
    this.onSwitchGateway,
  });
  final Gateway gateway;
  final bool startInDraft;
  final VoidCallback? onSwitchGateway;
  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

enum _ProfileMenuAction { manage, refresh }

class _SessionsPageState extends State<SessionsPage> {
  late final AppLifecycleListener connectionLifecycle;
  late final StreamSubscription<Json> connectionEvents;
  DateTime? backgroundedAt;
  late final wake = MobileWake(widget.gateway, openWakeConversation);
  ({String tab, Object ticket})? wakeLaunch;
  Map<String, GatewayProfile> profiles = {};
  String profile = '';
  List<Json> rows = [];
  bool loading = true, more = false;
  int version = 0, nextOffset = 0;
  final readingReceipts = <(String, String), Future<void>>{};
  String query = '';
  bool archived = false;
  bool searching = false;
  final archiveLists = <bool, ({List<Json> rows, int nextOffset, bool more})>{};
  bool mutating = false;
  Timer? debounce;
  Timer? rosterTimer;
  Timer? libraryChangeTimer;
  bool libraryNeedsRefresh = false, refreshingLibrary = false;
  bool drawerVisible = false;
  bool docked = false;
  final layoutPreferences = MobileAppearance.shared;
  late bool sidebarOpen = layoutPreferences.sidebarOpen;
  bool get libraryVisible => docked ? sidebarOpen : drawerVisible;
  int? rosterUnavailableAt;
  int? turnRosterUnavailableAt;
  final rosterReads = <(int, String)>{};
  final activeConversations = <String, Set<String>>{};
  final liveTurns = <String, Map<String, ConversationActivity>>{};
  final sessionMetadata = <String, _RecentSessionMetadata>{};
  final search = TextEditingController();
  ChatTabs tabs = ChatTabs();
  final notificationTargets = <String, ConversationAlertTarget>{};
  final messageTargets = <String, TranscriptTarget>{};
  final mountedTabs = <String>{};
  final tabActivities = ValueNotifier<Map<String, ConversationActivity>>({});
  final tabMetadataChanges = ValueNotifier(0);
  final tabReloads = <String, int>{};
  late final ChatTabStore tabStore = ChatTabStore(widget.gateway);
  late final Future<void> tabRestore;
  Timer? tabSaveTimer;
  bool tabsDirty = false;
  Future<void>? tabWrite;
  bool shareReviewing = false;
  @override
  void dispose() {
    layoutPreferences.removeListener(updateDockVisibility);
    if (IncomingShares.supported) {
      IncomingShares.shared.removeListener(reviewSharedContent);
    }
    MobileNotifications.shared.opened.removeListener(openNotification);
    connectionLifecycle.dispose();
    wake.dispose();
    connectionEvents.cancel();
    debounce?.cancel();
    rosterTimer?.cancel();
    libraryChangeTimer?.cancel();
    for (final status in sessionMetadata.values) {
      status.cancel();
      status.unreadRows.dispose();
    }
    saveTabs();
    search.dispose();
    tabActivities.dispose();
    tabMetadataChanges.dispose();
    super.dispose();
  }

  void filter(String text) {
    debounce?.cancel();
    setState(() {
      version++;
      query = text.trim();
      loading = true;
      rows = [];
      more = false;
    });
    debounce = Timer(const Duration(milliseconds: 240), () => load());
  }

  String? error;
  @override
  void initState() {
    super.initState();
    layoutPreferences.addListener(updateDockVisibility);
    if (IncomingShares.supported) {
      IncomingShares.shared.addListener(reviewSharedContent);
    }
    MobileNotifications.shared.opened.addListener(openNotification);
    tabRestore = restoreTabs();
    connectionLifecycle = AppLifecycleListener(
      onResume: () {
        updateWakeVisibility();
        unawaited(reviewSharedContent());
        unawaited(resumeGateway());
      },
      onInactive: () {
        if (!wake.askingPermission) wake.setForeground(false);
        saveTabs();
      },
      onHide: () => wake.setForeground(false),
      onPause: () {
        backgroundedAt = DateTime.now();
        rosterTimer?.cancel();
        libraryChangeTimer?.cancel();
        libraryChangeTimer = null;
        for (final status in sessionMetadata.values) {
          status.cancel();
        }
        saveTabs();
      },
    );
    connectionEvents = widget.gateway.events.listen((event) {
      if (!mounted) return;
      if (event['type'] != 'client.connection') {
        final payload = event['payload'];
        final owner =
            event['profile'] ?? (payload is Json ? payload['profile'] : null);
        final refreshMetadata = const {
          'sessions.changed',
          'session.title',
          'session.updated',
          'message.complete',
        }.contains(event['type']);
        if (refreshMetadata) {
          if (owner is String && owner.isNotEmpty) {
            scheduleSessionMetadata(owner);
          } else if (event['type'] == 'sessions.changed') {
            refreshOpenProfileMetadata();
          } else {
            scheduleSessionMetadata(profile);
          }
        }
        if (owner != null && owner != profile) return;
        if (refreshMetadata) scheduleChangedLibrary();
        if (libraryVisible &&
            const {
              'message.start',
              'message.complete',
              'client.interaction',
              'request.cancel',
              'approval.request',
              'approval.settled',
              'approval.cancelled',
              'clarify.request',
              'clarify.settled',
              'clarify.cancelled',
            }.contains(event['type'])) {
          unawaited(refreshRoster());
        }
        return;
      }
      if (event['payload']?['state'] != 'online') {
        for (final status in sessionMetadata.values) {
          status.cancel();
        }
        setState(() {
          activeConversations.clear();
          liveTurns.clear();
        });
      }
      if (event['payload']?['resumed'] == true) {
        unawaited(load(refreshProfiles: true, retain: true));
      }
    });
    load();
  }

  Future<void> resumeGateway() async {
    final pausedAt = backgroundedAt;
    backgroundedAt = null;
    final gateway = widget.gateway;
    await gateway.foreground(
      backgrounded: pausedAt == null
          ? Duration.zero
          : DateTime.now().difference(pausedAt),
    );
    if (mounted &&
        identical(widget.gateway, gateway) &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      pollLibraryActivity();
      refreshOpenProfileMetadata();
      if (libraryNeedsRefresh) scheduleChangedLibrary();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ModalRoute.isCurrentOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      updateWakeVisibility();
      unawaited(reviewSharedContent());
    });
    final wide = SplitPaneRole.sessions.fits(MediaQuery.sizeOf(context).width);
    if (wide == docked) return;
    docked = wide;
    drawerVisible = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || docked != wide) return;
      onLibraryVisibilityChanged();
    });
  }

  void updateWakeVisibility() {
    if (!mounted) return;
    wake.setForeground(
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          ModalRoute.of(context)?.isCurrent != false,
    );
  }

  Future<void> openWakeSettings() async {
    final setting = await showWakeSettings(context, wake);
    if (!mounted || setting == null) return;
    tabs.wakeEnabled = setting;
    tabsDirty = true;
    saveTabs();
    wake.setEnabled(setting);
  }

  void openWakeConversation(WakeMatch match) {
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) {
      wake.finishTransfer();
      return;
    }
    final active = tabs.active;
    final owner = match.profile ?? active?.profile ?? profile;
    if (!profiles.containsKey(owner)) {
      wake.finishTransfer();
      showSessionMenuFeedback(context.tr('无法打开唤醒词对应的档案'));
      return;
    }
    final target = match.newSession
        ? tabs.activate(owner, null)
        : tabs.preferredOpen(owner) ?? tabs.emptyDraft(owner);
    wakeLaunch = (tab: target.id, ticket: Object());
    selectTab(target);
  }

  void finishWakeLaunch(Object ticket) {
    if (!mounted || wakeLaunch?.ticket != ticket) return;
    setState(() => wakeLaunch = null);
    wake.finishTransfer();
  }

  void onLibraryVisibilityChanged() {
    pollLibraryActivity();
    if (libraryVisible) scheduleChangedLibrary();
  }

  void updateDockVisibility() {
    final open = layoutPreferences.sidebarOpen;
    if (open == sidebarOpen) return;
    setState(() => sidebarOpen = open);
    if (docked) onLibraryVisibilityChanged();
  }

  Future<void> toggleLibrary() async {
    if (!docked) {
      shell.currentState?.openDrawer();
      return;
    }
    if (sidebarOpen) FocusManager.instance.primaryFocus?.unfocus();
    try {
      await layoutPreferences.setSidebarOpen(!sidebarOpen);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('无法保存布局'))));
      }
    }
  }

  void openNotification() {
    final opened = MobileNotifications.shared.opened;
    final target = opened.value;
    if (!mounted ||
        profiles.isEmpty ||
        target == null ||
        target.owner != ConversationAlertTarget.ownerFor(widget.gateway)) {
      return;
    }
    opened.value = null;
    if (!profiles.containsKey(target.profile)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !profiles.containsKey(target.profile)) return;
      final route = ModalRoute.of(context);
      if (route != null) {
        Navigator.of(context).popUntil((item) => identical(item, route));
      }
      final tab = tabs.activate(target.profile, {
        'id': target.session,
        'profile': target.profile,
        'title': target.title,
      });
      if (target.prompt != null || target.reply) {
        notificationTargets[tab.id] = target;
      }
      selectTab(tab);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void pollLibraryActivity() {
    rosterTimer?.cancel();
    if (!libraryVisible) return;
    unawaited(refreshRoster());
    rosterTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(refreshRoster());
      if (libraryNeedsRefresh || !widget.gateway.changeEvents) {
        scheduleChangedLibrary();
      }
    });
  }

  bool get canRefreshLibrary =>
      mounted &&
      libraryVisible &&
      profile.isNotEmpty &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      widget.gateway.usable &&
      query.isEmpty &&
      nextOffset <= sessionListPageSize;

  void scheduleChangedLibrary() {
    libraryNeedsRefresh = true;
    if (!canRefreshLibrary || refreshingLibrary || libraryChangeTimer != null) {
      return;
    }
    libraryChangeTimer = Timer(const Duration(milliseconds: 650), () {
      libraryChangeTimer = null;
      unawaited(refreshChangedLibrary());
    });
  }

  Future<void> refreshChangedLibrary() async {
    if (!canRefreshLibrary || refreshingLibrary) return;
    if (loading || mutating) {
      scheduleChangedLibrary();
      return;
    }
    final generation = version;
    final connection = widget.gateway.connectionRevision;
    final currentRows = rows;
    refreshingLibrary = true;
    libraryNeedsRefresh = false;
    var failed = false;
    try {
      final page = await readSessionPage(0);
      if (canRefreshLibrary &&
          generation == version &&
          connection == widget.gateway.connectionRevision &&
          identical(currentRows, rows) &&
          !loading &&
          !mutating) {
        applySessionPage(page, offset: 0, append: false);
      } else {
        libraryNeedsRefresh = true;
      }
    } catch (_) {
      // A background read keeps the visible list and retries on the next tick.
      libraryNeedsRefresh = true;
      failed = true;
    } finally {
      refreshingLibrary = false;
      if (libraryNeedsRefresh && !failed) scheduleChangedLibrary();
    }
  }

  Future<void> refreshRoster() async {
    final gateway = widget.gateway;
    final owner = profile;
    final connection = gateway.connectionRevision;
    final request = (connection, owner);
    if (!mounted ||
        !libraryVisible ||
        owner.isEmpty ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        rosterUnavailableAt == connection &&
            turnRosterUnavailableAt == connection ||
        !gateway.usable ||
        !rosterReads.add(request)) {
      return;
    }
    bool current() =>
        mounted &&
        identical(widget.gateway, gateway) &&
        gateway.connectionRevision == connection;
    Future<void> refreshBackground() async {
      try {
        final result = await SessionActivityService.roster(gateway, owner);
        if (current()) setState(() => activeConversations[owner] = result);
      } on GatewayError catch (e) {
        if (current() && e.code == -32601) rosterUnavailableAt = connection;
      } catch (_) {
        // Keep the latest roster during a transient connection loss.
      }
    }

    Future<void> refreshTurns() async {
      try {
        final result = await SessionActivityService.turns(gateway, owner);
        if (!current()) return;
        final newSession =
            owner == profile &&
            !archived &&
            result.storedSessions.any(
              (id) =>
                  liveTurns[owner]?.containsKey(id) != true &&
                  !rows.any(
                    (row) =>
                        tabSessionId(row) == id || sessionLineage(row) == id,
                  ),
            );
        setState(() => liveTurns[owner] = result.states);
        if (newSession) scheduleChangedLibrary();
      } on GatewayError catch (e) {
        if (current() && e.code == -32601) turnRosterUnavailableAt = connection;
      } catch (_) {
        // Keep the latest roster during a transient connection loss.
      }
    }

    try {
      await Future.wait([
        if (rosterUnavailableAt != connection) refreshBackground(),
        if (turnRosterUnavailableAt != connection) refreshTurns(),
      ]);
    } finally {
      rosterReads.remove(request);
    }
  }

  Future<void> load({
    bool append = false,
    bool refreshProfiles = false,
    bool retain = false,
  }) async {
    final generation = ++version;
    final retainedOffset = retain && !append && query.isEmpty ? nextOffset : 0;
    setState(() {
      loading = true;
      error = null;
      if (!append && !retain) rows = [];
    });
    try {
      await tabRestore;
      if (!mounted || generation != version) return;
      if (profiles.isEmpty || refreshProfiles) {
        final entries = await ProfileService(widget.gateway).list();
        if (!mounted || generation != version) return;
        if (entries.isEmpty) throw GatewayError('网关没有可用的配置档案');
        setState(() {
          profiles = {for (final entry in entries) entry.name: entry};
          if (!profiles.containsKey(profile)) {
            final fallback =
                entries.where((entry) => entry.isDefault).firstOrNull?.name ??
                entries.first.name;
            final saved = tabs.active;
            final permitted =
                saved != null && profiles.containsKey(saved.profile)
                ? saved
                : null;
            final tab = widget.startInDraft && profile.isEmpty
                ? tabs.emptyDraft(permitted?.profile ?? fallback)
                : permitted ??
                      tabs.open
                          .where((item) => item.profile == fallback)
                          .firstOrNull ??
                      tabs.activate(fallback, null);
            tabs.activeId = tab.id;
            mountedTabs.add(tab.id);
            archiveLists.clear();
            profile = tab.profile;
            recent = [];
            rows = [];
          }
        });
      }
      openNotification();
      if (refreshProfiles || !sessionMetadata.containsKey(profile)) {
        refreshOpenProfileMetadata();
      }
      var offset = append ? nextOffset : 0;
      var page = await readSessionPage(offset);
      if (!mounted || generation != version) return;
      if (retainedOffset > sessionListPageSize && page['sessions'] is List) {
        final combined = <Object?>[...page['sessions'] as List];
        final total = page['total'];
        while (total is int &&
            offset + sessionListPageSize < retainedOffset &&
            offset + sessionListPageSize < total) {
          offset += sessionListPageSize;
          page = await readSessionPage(offset);
          if (!mounted || generation != version) return;
          final items = page['sessions'];
          if (items is! List) throw GatewayError('网关未返回会话列表');
          combined.addAll(items);
        }
        page = {...page, 'sessions': combined};
      }
      applySessionPage(page, offset: offset, append: append);
      if (libraryVisible) unawaited(refreshRoster());
    } catch (e) {
      if (mounted && generation == version) {
        final message = switch (e) {
          GatewayError(status: 401) => '需要重新登录',
          GatewayError(status: 403) => '当前登录无法读取此信息',
          GatewayError(status: null, code: null, :final message) => message,
          _ => '暂时无法读取会话列表',
        };
        setState(() => error = message);
      }
    } finally {
      if (mounted && generation == version) {
        setState(() => loading = false);
        unawaited(reviewSharedContent());
        if (libraryNeedsRefresh) scheduleChangedLibrary();
      }
    }
  }

  void applySessionPage(
    Json page, {
    required int offset,
    required bool append,
  }) {
    if (page['storage'] case final Json storage
        when storage[profile] == 'corrupt') {
      throw GatewayError('网关的会话存储暂时不可读');
    }
    final items = page[query.isEmpty ? 'sessions' : 'results'];
    if (items is! List) throw GatewayError('网关未返回会话列表');
    final unique = <String, Json>{
      if (append)
        for (final row in rows) ?tabSessionId(row): row,
      for (final row in items.whereType<Json>())
        if ((row['profile'] == null || row['profile'] == profile) &&
            (row['archived'] == true) == archived)
          ?tabSessionId(row): row,
    };
    setState(() {
      rows = unique.values.toList();
      if (query.isEmpty && !archived) {
        recent = [...rows]
          ..sort(
            (a, b) => (sessionTime(b)?.millisecondsSinceEpoch ?? 0).compareTo(
              sessionTime(a)?.millisecondsSinceEpoch ?? 0,
            ),
          );
        recent = recent.take(3).toList();
      }
      nextOffset = offset + sessionListPageSize;
      more = query.isEmpty && nextOffset < (page['total'] as int? ?? 0);
      error = null;
    });
  }

  bool get canReviewSharedContent {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        profile.isNotEmpty &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        ModalRoute.isCurrentOf(context) == true;
  }

  Future<void> reviewSharedContent() async {
    if (!IncomingShares.supported || shareReviewing || !canReviewSharedContent)
      return;
    final inbox = IncomingShares.shared;
    shareReviewing = true;
    var consumed = false;
    try {
      final item = await inbox.peek();
      if (item == null || !canReviewSharedContent) return;
      await reviewIncomingShare(
        context,
        item,
        onAccept: () async {
          try {
            await saveSharedDraft(item);
          } catch (_) {
            await inbox.finish(item, consumed: false);
            rethrow;
          }
        },
      );
      if (!mounted) return;
      await inbox.finish(item, consumed: true);
      consumed = true;
    } catch (_) {
      if (mounted) showSessionMenuFeedback(context.tr('无法导入共享内容'));
    } finally {
      shareReviewing = false;
      if (consumed) unawaited(reviewSharedContent());
    }
  }

  Future<void> saveSharedDraft(SharedContent item) async {
    if (tabs.find(item.id) case final existing?) {
      selectTab(existing);
      return;
    }
    final owner = profile;
    final draft = ChatTab(owner, id: item.id, draft: item.text);
    final files = await IncomingShares.shared.copy(item);
    var photoCount = 0;
    await persistNewDraft(
      draft,
      Stream.fromIterable(files).asyncMap((file) async {
        final photo =
            photoCount < composerPhotoLimit && await isComposerPhoto(file);
        if (photo) photoCount++;
        return (file: file, photo: photo);
      }),
    );
    if (mounted) selectTab(draft);
  }

  Future<void> copyDraftToNewTab(ChatTab source) async {
    if (!mounted || !identical(tabs.active, source)) return;
    await source.attachmentWrite;
    if (!mounted || !identical(tabs.active, source)) return;
    final text = source.draft;
    final attachments = source.attachments.toList(growable: false);
    if (text.isEmpty && attachments.isEmpty) return;

    final draft = ChatTab(
      source.profile,
      draft: text,
      draftStamp: text.isEmpty ? null : const Uuid().v4(),
    );
    final original = ComposerAttachmentStore(
      widget.gateway,
      source.profile,
      source.id,
    );
    Stream<({XFile file, bool photo})> inputs() async* {
      for (final attachment in attachments) {
        yield (
          file: await original.source(attachment),
          photo: attachment.photo,
        );
      }
    }

    await persistNewDraft(draft, inputs());
    if (!mounted) return;
    if (identical(tabs.active, source)) {
      selectTab(draft);
    } else {
      setState(() {});
    }
  }

  Future<void> persistNewDraft(
    ChatTab draft,
    Stream<({XFile file, bool photo})> inputs,
  ) async {
    final store = ComposerAttachmentStore(
      widget.gateway,
      draft.profile,
      draft.id,
    );
    final imported = <ComposerAttachment>[];
    try {
      await for (final input in inputs) {
        imported.add(
          (await store.import(input.file, photo: input.photo)).attachment,
        );
      }
      if (!mounted || !profiles.containsKey(draft.profile)) {
        throw GatewayDisconnected();
      }
      draft.attachments = imported;
      tabs.open.add(draft);
      tabsDirty = true;
      await flushTabs();
    } catch (_) {
      if (tabs.open.remove(draft)) {
        tabsDirty = true;
        saveTabs();
      }
      await store.remove(imported);
      rethrow;
    }
  }

  Future<Json> readSessionPage(int offset) async {
    final scope = profile;
    final text = query;
    if (text.isEmpty) {
      return widget.gateway.readConversationPage(
        'api/sessions',
        query: {
          'profile': scope,
          'limit': '$sessionListPageSize',
          'offset': '$offset',
          'order': 'recent',
          'min_messages': '1',
          'exclude_sources': hiddenSessionSources,
          if (archived) 'archived': 'only',
        },
      );
    }
    Future<Json> search(String value) => widget.gateway.readConversationPage(
      'api/sessions/search',
      query: {
        'profile': scope,
        'q': value,
        'limit': '$sessionListPageSize',
        'min_messages': '1',
        'exclude_sources': hiddenSessionSources,
      },
    );
    final normalized = text
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((part) => part.isNotEmpty)
        .join(' ');
    if (normalized.isEmpty || normalized == text) return search(text);
    try {
      final page = await search(text);
      if (page['results'] case final List results when results.isNotEmpty) {
        return page;
      }
    } on GatewayError catch (error) {
      if (!{400, 422, 500}.contains(error.status)) rethrow;
    }
    return search(normalized);
  }

  ({List<LibraryEntry> pins, List<LibraryEntry> sessions}) get libraryRows =>
      projectLibrary(
        rows,
        searching: query.isNotEmpty,
        archived: archived,
        pinOrder: tabs.pinOrder[profile] ?? const [],
      );

  void reorderPins(List<LibraryEntry> pins, int from, int to) {
    if (from == to || archived || query.isNotEmpty) return;
    final ids = pins.map((entry) => sessionLineage(entry.row)).toList();
    if (from < 0 || to < 0 || from >= ids.length || to >= ids.length) return;
    ids.insert(to, ids.removeAt(from));
    final other =
        tabs.pinOrder[profile]?.where((key) => !ids.contains(key)).toList() ??
        const [];
    setState(() => tabs.pinOrder[profile] = [...ids, ...other]);
    tabsDirty = true;
    saveTabs();
  }

  Future<void> markOpenedRead(ChatTab tab) async {
    final id = tab.session;
    if (id == null || tab.row?['unread'] != true) return;
    await markSessionRead(tab.profile, id);
  }

  Future<bool> markSessionRead(String owner, String id) async {
    if (!widget.gateway.usable) return false;
    final scope = (owner, id);
    if (readingReceipts.containsKey(scope)) return false;
    final request = widget.gateway.patchSession(id, owner, {'unread': false});
    readingReceipts[scope] = request;
    try {
      await request;
      if (mounted) updateTabRows(owner, id, {'unread': false});
      return true;
    } catch (_) {
      return false;
    } finally {
      readingReceipts.remove(scope);
    }
  }

  Future<void> sessionActions(
    Json row, {
    String? tabProfile,
    SessionMenuAction? selected,
  }) async {
    if (mutating) return;
    final id = tabSessionId(row);
    if (id == null) return;
    final name = sessionTitle(row) ?? context.tr('未命名会话');
    final owner = tabProfile ?? profile;
    final viewProfile = profile;
    final lineage = sessionLineage(row);
    final pins =
        owner != profile ||
            archived ||
            query.isNotEmpty ||
            row['pinned'] != true
        ? const <LibraryEntry>[]
        : libraryRows.pins;
    final pinnedIndex = pins.indexWhere(
      (entry) => sessionLineage(entry.row) == sessionLineage(row),
    );
    final pinned = row['pinned'] == true;
    final unread = row['unread'] == true;
    final shortcuts = [
      (SessionMenuAction.rename, Icons.edit_outlined, '重命名'),
      (
        SessionMenuAction.pin,
        pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
        pinned ? '取消置顶' : '置顶',
      ),
      (
        SessionMenuAction.read,
        unread
            ? Icons.mark_chat_read_outlined
            : Icons.mark_chat_unread_outlined,
        unread ? '标记为已读' : '标记为未读',
      ),
      (
        SessionMenuAction.archive,
        row['archived'] == true
            ? Icons.unarchive_outlined
            : Icons.archive_outlined,
        row['archived'] == true ? '移出归档' : '归档',
      ),
    ];
    GlassSheetAction<SessionMenuAction> entry(
      (SessionMenuAction, IconData, String) item,
    ) => GlassSheetAction(
      value: item.$1,
      icon: item.$2,
      label: context.tr(item.$3),
      enabled: !item.$1.requiresGateway || widget.gateway.usable,
      destructive: item.$1 == SessionMenuAction.delete,
    );
    final action =
        selected ??
        await showGlassActionSheet<SessionMenuAction>(
          context,
          title: name,
          subtitle: [
            profileLabel(owner),
            if (sessionTime(row) case final time?)
              MaterialLocalizations.of(context).formatMediumDate(time),
          ].join(' · '),
          quick: [
            for (final (action, icon, label) in shortcuts)
              GlassSheetAction(
                value: action,
                icon: icon,
                label: context.tr(label),
                enabled: widget.gateway.usable,
              ),
          ],
          groups: [
            [
              if (tabProfile == null)
                entry((
                  SessionMenuAction.open,
                  Icons.open_in_new_rounded,
                  '在新标签页打开',
                )),
              if (pinnedIndex > 0)
                entry((
                  SessionMenuAction.pinUp,
                  Icons.arrow_upward_rounded,
                  '上移置顶',
                )),
              if (pinnedIndex >= 0 && pinnedIndex + 1 < pins.length)
                entry((
                  SessionMenuAction.pinDown,
                  Icons.arrow_downward_rounded,
                  '下移置顶',
                )),
              entry((
                SessionMenuAction.color,
                Icons.palette_outlined,
                '会话标题颜色',
              )),
              entry((SessionMenuAction.copyId, Icons.copy_outlined, '复制会话 ID')),
            ],
            [
              entry((
                SessionMenuAction.branch,
                Icons.call_split_rounded,
                '分叉会话',
              )),
              entry((
                SessionMenuAction.export,
                Icons.download_outlined,
                '导出会话',
              )),
              entry((
                SessionMenuAction.share,
                Icons.ios_share_outlined,
                '分享会话',
              )),
            ],
            [
              entry((
                SessionMenuAction.delete,
                Icons.delete_outline_rounded,
                '删除',
              )),
            ],
          ],
        );
    if (!mounted ||
        action == null ||
        profile != viewProfile ||
        !profiles.containsKey(owner) ||
        mutating ||
        action.requiresGateway && !widget.gateway.usable) {
      return;
    }
    Json change;
    switch (action) {
      case SessionMenuAction.open:
        selectTab(tabs.activate(owner, row));
        return;
      case SessionMenuAction.color:
        final previous = tabs.titleColor(owner, id, lineage);
        final choice = await chooseSessionTitleColor(
          context,
          name: name,
          selected: previous,
        );
        if (!mounted || choice == null || previous == choice.color) return;
        setState(() => tabs.setTitleColor(owner, id, lineage, choice.color));
        tabsDirty = true;
        try {
          await flushTabs();
        } catch (_) {
          if (mounted) showSessionMenuFeedback(context.tr('无法保存会话标题颜色'));
        }
        return;
      case SessionMenuAction.copyId:
        try {
          await Clipboard.setData(ClipboardData(text: id));
          if (mounted) showSessionMenuFeedback(context.tr('已复制会话 ID'));
        } catch (_) {
          if (mounted) showSessionMenuFeedback(context.tr('无法复制会话 ID'));
        }
        return;
      case SessionMenuAction.rename:
        var draft = name;
        final title = await showDialog<String>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(context.tr('重命名会话')),
            content: TextFormField(
              initialValue: name,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onChanged: (value) => draft = value,
              onFieldSubmitted: (value) => Navigator.pop(dialog, value.trim()),
              decoration: InputDecoration(labelText: context.tr('会话标题')),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(context.tr('取消')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, draft.trim()),
                child: Text(context.tr('保存')),
              ),
            ],
          ),
        );
        if (title == null || title.isEmpty || title == name) return;
        change = {'title': title};
      case SessionMenuAction.pin:
        change = {'pinned': row['pinned'] != true};
      case SessionMenuAction.pinUp:
      case SessionMenuAction.pinDown:
        final current = libraryRows.pins;
        final index = current.indexWhere(
          (entry) => sessionLineage(entry.row) == sessionLineage(row),
        );
        if (index >= 0) {
          reorderPins(
            current,
            index,
            index + (action == SessionMenuAction.pinUp ? -1 : 1),
          );
        }
        return;
      case SessionMenuAction.read:
        try {
          await readingReceipts[(owner, id)];
        } catch (_) {
          // The explicit choice still applies after an automatic read failed.
        }
        change = {'unread': row['unread'] != true};
      case SessionMenuAction.archive:
        change = row['archived'] == true
            ? {'archived': false}
            : {'archived': true, 'pinned': false};
      case SessionMenuAction.branch:
        setState(() => mutating = true);
        try {
          final forked = await branchConversation(
            widget.gateway,
            parent: id,
            profile: owner,
            title: name,
          );
          if (mounted && profile == viewProfile) {
            final refresh = profile == owner;
            selectTab(tabs.activate(owner, forked));
            if (refresh) await load();
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(context.tr(e.toString()))));
          }
        } finally {
          if (mounted) setState(() => mutating = false);
        }
        return;
      case SessionMenuAction.export:
      case SessionMenuAction.share:
        final sharing = action == SessionMenuAction.share;
        final format = await showModalBottomSheet<SessionExportFormat>(
          context: context,
          showDragHandle: true,
          builder: (sheet) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Markdown'),
                  onTap: () =>
                      Navigator.pop(sheet, SessionExportFormat.markdown),
                ),
                ListTile(
                  leading: const Icon(Icons.data_object_rounded),
                  title: const Text('JSON'),
                  onTap: () => Navigator.pop(sheet, SessionExportFormat.json),
                ),
              ],
            ),
          ),
        );
        if (format == null || !mounted || profile != viewProfile) return;
        final media = MediaQuery.sizeOf(context);
        setState(() => mutating = true);
        try {
          final completed = await exportConversation(
            context,
            widget.gateway,
            id: id,
            profile: owner,
            title: name,
            format: format,
            stillOpen: () => mounted,
            shareOrigin: sharing
                ? Rect.fromLTWH(media.width / 2, media.height / 2, 1, 1)
                : null,
          );
          if (completed && mounted && !sharing) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(context.tr('会话已导出'))));
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(context.tr(e.toString()))));
          }
        } finally {
          if (mounted) setState(() => mutating = false);
        }
        return;
      case SessionMenuAction.delete:
        final approved = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(context.tr('删除会话？')),
            content: Text(
              context.strings.format('将从网关永久删除「{name}」。', {'name': name}),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(context.tr('取消')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(context.tr('删除')),
              ),
            ],
          ),
        );
        if (approved != true) return;
        change = {};
    }
    if (!mounted || profile != viewProfile) return;
    setState(() => mutating = true);
    try {
      if (action == SessionMenuAction.delete) {
        await widget.gateway.deleteSession(id, owner);
      } else {
        await widget.gateway.patchSession(id, owner, change);
      }
      if (!mounted) return;
      if (profile == owner &&
          (action == SessionMenuAction.archive ||
              action == SessionMenuAction.delete)) {
        setState(() {
          rows = rows.where((row) => tabSessionId(row) != id).toList();
          recent = recent.where((row) => tabSessionId(row) != id).toList();
          archiveLists.updateAll(
            (_, cached) => (
              rows: cached.rows
                  .where((row) => tabSessionId(row) != id)
                  .toList(),
              nextOffset: cached.nextOffset,
              more: cached.more,
            ),
          );
        });
      }
      if (action == SessionMenuAction.delete) {
        final gateway = widget.gateway;
        final discarded = [
          ...tabs.open,
          ...tabs.closed,
        ].where((tab) => tab.profile == owner && tab.session == id).toList();
        forgetMountedTabs(discarded.map((tab) => tab.id).toSet());
        final previous = tabs.activeId;
        tabs.dropSession(owner, id);
        if (tabs.activeId != previous || tabs.active == null) {
          selectTab(tabs.active ?? tabs.activate(profile, null));
        } else {
          setState(() => tabsDirty = true);
        }
        await flushTabs();
        for (final tab in discarded) {
          await ComposerAttachmentStore(
            gateway,
            owner,
            tab.id,
          ).remove(tab.attachments);
        }
        await CommandReceipts(gateway, owner, id).delete();
        await TurnCorrections(gateway, owner, id).delete();
      } else {
        updateTabRows(owner, id, change);
      }
      if (profile == owner) await load(retain: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr(e.toString()))));
      }
    } finally {
      if (mounted) setState(() => mutating = false);
    }
  }

  void showSessionMenuFeedback(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Json? tabSummary(ChatTab tab) {
    final row = tab.row;
    if (row == null || tab.profile != profile) return row;
    return rows
            .where((candidate) => tabSessionId(candidate) == tab.session)
            .firstOrNull ??
        row;
  }

  SessionTitleColor? tabTitleColor(ChatTab tab) {
    final row = tabSummary(tab);
    final id = tab.session;
    return row == null || id == null
        ? null
        : tabs.titleColor(tab.profile, id, sessionLineage(row));
  }

  final shell = GlobalKey<ScaffoldState>();
  final libraryKey = GlobalKey();
  Json? get selected => tabs.active?.row;
  List<Json> recent = [];

  Future<void> restoreTabs() async {
    try {
      final restored = await tabStore.read();
      if (mounted) {
        tabs = restored;
        wake.restore(tabs.wakeEnabled);
      }
    } catch (_) {
      // A fresh tab is available if local tab state cannot be read.
    }
  }

  void saveTabs() => unawaited(flushTabs().catchError((Object _) {}));

  Future<void> flushTabs() async {
    tabSaveTimer?.cancel();
    if (!tabsDirty) {
      await tabWrite;
      return;
    }
    tabsDirty = false;
    final write = tabStore.write(tabs);
    tabWrite = write;
    try {
      await write;
    } catch (_) {
      tabsDirty = true;
      rethrow;
    } finally {
      if (identical(tabWrite, write)) tabWrite = null;
    }
  }

  void updateDraft(ChatTab tab, String text, String? stamp) {
    if ((tab.draft == text && tab.draftStamp == stamp) ||
        tabs.find(tab.id) == null) {
      return;
    }
    tab.draft = text;
    tab.draftStamp = stamp;
    tabsDirty = true;
    tabSaveTimer?.cancel();
    tabSaveTimer = Timer(const Duration(milliseconds: 300), saveTabs);
  }

  Future<bool> updateDraftAttachments(
    ChatTab tab,
    List<ComposerAttachment> inputs,
  ) async {
    if (!mounted || !identical(tabs.find(tab.id), tab)) return false;
    tab.attachments = inputs;
    tabsDirty = true;
    await flushTabs();
    return true;
  }

  void updateWorkspacePosition(ChatTab tab, WorkspaceBrowserPosition position) {
    if (!mounted || !identical(tabs.find(tab.id), tab)) return;
    tab.workspacePosition = position;
    tabsDirty = true;
    tabSaveTimer?.cancel();
    tabSaveTimer = Timer(const Duration(milliseconds: 300), saveTabs);
  }

  void updateWorkspaceReviewPosition(
    ChatTab tab,
    WorkspaceReviewPosition position,
  ) {
    if (!mounted || !identical(tabs.find(tab.id), tab)) return;
    tab.reviewPosition = position;
    tabsDirty = true;
    tabSaveTimer?.cancel();
    tabSaveTimer = Timer(const Duration(milliseconds: 300), saveTabs);
  }

  void commitSessionMetadata(VoidCallback change, {required bool persistTabs}) {
    setState(change);
    if (!persistTabs) return;
    tabMetadataChanges.value++;
    tabsDirty = true;
    saveTabs();
  }

  void updateTabRows(String owner, String id, Json values) {
    final metadata = sessionMetadata[owner];
    final fields = values['archived'] == true
        ? {...values, 'unread': false}
        : values;
    commitSessionMetadata(() {
      final unread = metadata?.unread;
      if (fields['unread'] case final bool next
          when unread?.containsKey(id) == true) {
        unread![id] = next;
      }
      if (owner == profile) {
        Json apply(Json row) =>
            tabSessionId(row) == id ? {...row, ...fields} : row;
        rows = rows.map(apply).toList();
        recent = recent.map(apply).toList();
      }
      for (final tab in [...tabs.open, ...tabs.closed]) {
        if (tab.profile == owner && tab.session == id) {
          tab.row = {...?tab.row, ...fields};
        }
      }
    }, persistTabs: true);
    final unreadRows = metadata?.unreadRows.value;
    if (metadata != null &&
        unreadRows != null &&
        unreadRows.any((row) => tabSessionId(row) == id)) {
      metadata.unreadRows.value = [
        for (final row in unreadRows)
          if (tabSessionId(row) != id)
            row
          else if (fields['unread'] != false)
            {...row, ...fields},
      ];
    }
    scheduleSessionMetadata(owner);
  }

  Future<void> bindTab(ChatTab tab, Json row) async {
    if (!mounted || tabs.find(tab.id) == null || tab.session != null) return;
    setState(() => tab.row = row);
    tabsDirty = true;
    await flushTabs();
  }

  void selectTab(ChatTab tab, {bool closeDrawer = true}) {
    if (!profiles.containsKey(tab.profile)) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (closeDrawer) shell.currentState?.closeDrawer();
    final changed = profile != tab.profile;
    setState(() {
      if (wakeLaunch case final request? when request.tab != tab.id) {
        wakeLaunch = null;
        wake.finishTransfer();
      }
      tabs.activeId = tab.id;
      mountedTabs.add(tab.id);
      if (changed) {
        archiveLists.clear();
        profile = tab.profile;
        recent = [];
        rows = [];
        archived = false;
        search.clear();
        query = '';
        debounce?.cancel();
      }
    });
    tabsDirty = true;
    saveTabs();
    if (changed) {
      scheduleSessionMetadata(tab.profile);
      unawaited(load());
    } else if (tab.session != null &&
        sessionMetadata[tab.profile]?.unread.containsKey(tab.session) != true) {
      scheduleSessionMetadata(tab.profile);
    }
    unawaited(markOpenedRead(tab));
  }

  void open([Json? row]) {
    if (profile.isEmpty ||
        row?['profile'] != null && row?['profile'] != profile) {
      return;
    }
    selectTab(tabs.activate(profile, row));
  }

  void openMessage(TranscriptTarget target) {
    if (!mounted) return;
    if (!profiles.containsKey(target.profile)) {
      showSessionMenuFeedback(context.tr('无法定位此消息'));
      return;
    }
    final listed = target.profile == profile
        ? rows.where((row) => tabSessionId(row) == target.session).firstOrNull
        : null;
    final saved = [...tabs.open, ...tabs.closed]
        .where(
          (tab) =>
              tab.profile == target.profile && tab.session == target.session,
        )
        .firstOrNull;
    final tab = tabs.activate(
      target.profile,
      listed ??
          saved?.row ??
          {
            'id': target.session,
            'profile': target.profile,
            'title': target.title,
          },
    );
    messageTargets[tab.id] = target;
    selectTab(tab);
  }

  Future<void> openBookmarks() async {
    shell.currentState?.closeDrawer();
    final target = await Navigator.of(context).push<TranscriptTarget>(
      MaterialPageRoute(
        builder: (_) =>
            TranscriptExplorer(gateway: widget.gateway, returnSelection: true),
      ),
    );
    if (mounted && target != null) openMessage(target);
  }

  Future<void> openActiveConversations() async {
    final owner = profile;
    if (owner.isEmpty) return;
    final selected = await chooseActiveConversation(
      context,
      gateway: widget.gateway,
      profile: owner,
      knownRows: [
        ...rows,
        ...recent,
        for (final tab in tabs.open)
          if (tab.profile == owner && tab.row != null) tab.row!,
      ],
    );
    if (mounted && profile == owner && selected != null) open(selected);
  }

  Future<void> openUnreadConversations() async {
    final owner = profile;
    final metadata = sessionMetadata[owner];
    if (metadata == null) return;
    scheduleSessionMetadata(owner);
    final selected = await chooseUnreadConversation(
      context,
      rows: metadata.unreadRows,
      activity: tabActivities,
      busySessions: () => busyConversationIds(owner),
      markRead: (id) => markSessionRead(owner, id),
    );
    if (mounted && profile == owner && selected != null) open(selected);
  }

  List<ChatTab> get visibleTabs =>
      tabs.open.where((tab) => profiles.containsKey(tab.profile)).toList();

  void cycleTab(int step) {
    final visible = visibleTabs;
    if (visible.length < 2) return;
    final current = visible.indexWhere((tab) => tab.id == tabs.activeId);
    if (current >= 0) selectTab(visible[(current + step) % visible.length]);
  }

  Future<void> showOpenTabs() async {
    final active = tabs.active;
    if (active == null || visibleTabs.isEmpty) return;
    refreshOpenProfileMetadata();
    final chosen = await showTabSwitcher(
      context,
      active: active.id,
      actions: TabSwitcherActions(
        tabs: () => visibleTabs,
        onClose: closeTab,
        onCloseGroup: closeTabGroup,
        onNew: () => open(),
        onReopen: canReopenTab ? reopenTab : null,
      ),
      activities: tabActivities,
      metadataChanges: tabMetadataChanges,
      profileLabel: profileLabel,
      titleColor: tabTitleColor,
    );
    if (mounted &&
        chosen != null &&
        tabs.find(chosen.id) == chosen &&
        profiles.containsKey(chosen.profile) &&
        chosen.id != tabs.activeId) {
      selectTab(chosen);
    }
  }

  void moveTab(ChatTab source, ChatTab target) {
    if (!tabs.move(source.id, target.id)) return;
    setState(() => tabsDirty = true);
    saveTabs();
  }

  void closeTab(ChatTab tab) => closeTabGroup(tab, TabCloseScope.current);

  void forgetMountedTabs(Set<String> ids) {
    mountedTabs.removeAll(ids);
    if (ids.any(tabActivities.value.containsKey)) {
      tabActivities.value = Map.of(tabActivities.value)
        ..removeWhere((id, _) => ids.contains(id));
    }
    notificationTargets.removeWhere((id, _) => ids.contains(id));
    messageTargets.removeWhere((id, _) => ids.contains(id));
    tabReloads.removeWhere((id, _) => ids.contains(id));
  }

  Future<void> closeTabGroup(ChatTab tab, TabCloseScope scope) async {
    final before = visibleTabs;
    final pending = tabs
        .closingGroup(tab.id, scope, visible: before)
        .map((entry) => entry.attachmentWrite)
        .nonNulls
        .toList();
    if (pending.isNotEmpty) {
      await Future.wait(pending);
      if (!mounted) return;
    }
    final previous = tabs.activeId;
    final removed = tabs.closeGroup(
      tab.id,
      scope,
      visible: before.where((entry) => tabs.find(entry.id) != null).toList(),
    );
    if (removed.isEmpty) return;
    forgetMountedTabs(removed);
    if (previous == tabs.activeId) {
      setState(() => tabsDirty = true);
      saveTabs();
      return;
    }
    final next = tabs.active;
    selectTab(
      next != null && profiles.containsKey(next.profile)
          ? next
          : tabs.open
                    .where((row) => profiles.containsKey(row.profile))
                    .firstOrNull ??
                tabs.activate(profile, null),
    );
  }

  void reloadTab(ChatTab tab) {
    if (!widget.gateway.usable ||
        tab.session == null ||
        tabs.find(tab.id) == null ||
        !profiles.containsKey(tab.profile)) {
      return;
    }
    if (mountedTabs.contains(tab.id)) {
      tabReloads.update(tab.id, (version) => version + 1, ifAbsent: () => 1);
    }
    selectTab(tab);
  }

  void manageTabSession(ChatTab tab, {SessionMenuAction? selected}) {
    final row = tabSummary(tab);
    if (row == null ||
        tabs.find(tab.id) == null ||
        !profiles.containsKey(tab.profile)) {
      return;
    }
    unawaited(sessionActions(row, tabProfile: tab.profile, selected: selected));
  }

  bool get canReopenTab =>
      tabs.closed.any((tab) => profiles.containsKey(tab.profile));

  void reopenTab() {
    final tab = tabs.reopen(profiles.keys.toSet());
    if (tab != null) selectTab(tab);
  }

  @override
  Widget build(BuildContext context) {
    final active = tabs.active;
    if (profile.isEmpty || active == null) {
      return Scaffold(body: library(context));
    }
    final currentRoute = ModalRoute.isCurrentOf(context) != false;
    final landscapeKeyboard =
        currentRoute &&
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
    final visible = visibleTabs;
    final liveTabs = visible
        .where((tab) => mountedTabs.contains(tab.id))
        .toList();
    const role = SplitPaneRole.sessions;
    final color =
        CustomThemeTokens.read(context, ThemeColor.sidebar) ??
        Theme.of(context).colorScheme.surface;
    final sidebar = docked && !sidebarOpen
        ? null
        : KeyedSubtree(key: libraryKey, child: library(context));
    final activeIndex = liveTabs.indexWhere((tab) => tab.id == active.id);
    final transcript = ChatTabViewport(
      active: activeIndex < 0 ? null : activeIndex,
      children: [
        for (final tab in liveTabs)
          Visibility(
            key: ValueKey(tab.id),
            visible: tab.id == active.id,
            maintainState: true,
            maintainAnimation: true,
            maintainSize: true,
            child: TickerMode(
              enabled: tab.id == active.id,
              child: tabPage(tab, visible, active, landscapeKeyboard),
            ),
          ),
      ],
    );
    return CallbackShortcuts(
      bindings: MobileShortcut.bind({
        MobileShortcut.newTab: open,
        MobileShortcut.closeTab: () => closeTab(active),
        if (canReopenTab) MobileShortcut.reopenTab: reopenTab,
        if (visible.length > 1) ...{
          MobileShortcut.nextTab: () => cycleTab(1),
          MobileShortcut.previousTab: () => cycleTab(-1),
        },
      }),
      child: Scaffold(
        key: shell,
        resizeToAvoidBottomInset: currentRoute,
        drawerScrimColor: Colors.transparent,
        // The drawer frosts the whole screen; the sidebar takes most of the
        // width and the blurred strip beside it closes the drawer on tap.
        drawer: docked
            ? null
            : Drawer(
                width: MediaQuery.sizeOf(context).width,
                backgroundColor: Colors.transparent,
                elevation: 0,
                shape: const RoundedRectangleBorder(),
                // A light blur over the whole screen keeps the chat visible
                // beside the sidebar; the sidebar itself is denser frost.
                child: GlassBackdrop(
                  tint: color,
                  blur: 12,
                  opacity: .18,
                  child: Row(
                    children: [
                      SizedBox(
                        width: (MediaQuery.sizeOf(context).width * .84)
                            .clamp(260, 420)
                            .toDouble(),
                        // A floating glass card inset from the screen edge,
                        // its corners concentric with the display's.
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
                          child: GlassSurface(
                            radius: 28,
                            tint: color,
                            opacity:
                                Theme.of(context).brightness == Brightness.dark
                                ? .7
                                : .72,
                            child: sidebar ?? const SizedBox.shrink(),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => shell.currentState?.closeDrawer(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        onDrawerChanged: (visible) {
          if (docked || drawerVisible == visible) return;
          setState(() => drawerVisible = visible);
          onLibraryVisibilityChanged();
        },
        body: ListenableBuilder(
          listenable: layoutPreferences,
          builder: (_, _) => ResizableSplitPane(
            role: role,
            preferredWidth: layoutPreferences.paneWidth(role),
            onWidthChanged: (width) =>
                layoutPreferences.setPaneWidth(role, width),
            list: docked && sidebarOpen
                ? Material(color: color, child: sidebar)
                : null,
            content: transcript,
          ),
        ),
      ),
    );
  }

  Widget tabPage(
    ChatTab tab,
    List<ChatTab> visible,
    ChatTab active,
    bool landscapeKeyboard,
  ) => ChatPage(
    gateway: widget.gateway,
    profile: tab.profile,
    profileLabel: profileLabel(tab.profile),
    id: tab.session,
    cwd: tab.row?['cwd'] as String?,
    title: tab.row == null ? 'Hermes Lite' : tab.title ?? context.tr('未命名会话'),
    titleColor: tabTitleColor(tab),
    reloadRequest: tabReloads[tab.id] ?? 0,
    openTabs: visible,
    onSelectTab: (id) {
      if (tabs.find(id) case final target? when target.profile == profile) {
        selectTab(target);
      }
    },
    initialDraft: tab.draft,
    initialDraftStamp: tab.draftStamp,
    composerTab: tab,
    onDraftAttachments: (inputs) => updateDraftAttachments(tab, inputs),
    onWorkspacePosition: (position) => updateWorkspacePosition(tab, position),
    onWorkspaceReviewPosition: (position) =>
        updateWorkspaceReviewPosition(tab, position),
    draftModel: tab.draftModel,
    onDraftModel: (options) {
      if (tabs.find(tab.id) == null || tab.session != null) return;
      tab.draftModel = options.isEmpty ? null : options;
      tabsDirty = true;
      saveTabs();
    },
    onDraft: (text, stamp) => updateDraft(tab, text, stamp),
    onFlushDraft: flushTabs,
    onBound: (row) => bindTab(tab, row),
    onLibrary: toggleLibrary,
    unreadConversations: unreadConversationCount(tab.profile),
    libraryDocked: docked ? sidebarOpen : null,
    onCron: openCron,
    wake: wake,
    onWakeSettings: openWakeSettings,
    wakeLaunch: wakeLaunch?.tab == tab.id ? wakeLaunch?.ticket : null,
    onWakeLaunchHandled: finishWakeLaunch,
    onRenamed: (id, title) => updateTabRows(tab.profile, id, {'title': title}),
    onActivityChanged: (activity) {
      if (!mounted ||
          tabs.find(tab.id) != tab ||
          tabActivities.value[tab.id] == activity)
        return;
      final next = Map.of(tabActivities.value);
      if (activity == null) {
        next.remove(tab.id);
      } else {
        next[tab.id] = activity;
      }
      tabActivities.value = next;
      if (tab.profile == profile &&
          sessionMetadata[tab.profile]?.unread[tab.session] == true) {
        setState(() {});
      }
    },
    notificationTarget: tab.id == active.id
        ? notificationTargets[tab.id]
        : null,
    onNotificationOpened: (target) {
      if (identical(notificationTargets[tab.id], target)) {
        setState(() => notificationTargets.remove(tab.id));
      }
    },
    onNew: () => open(),
    onNewWithDraft: () => copyDraftToNewTab(tab),
    onConversationAction: tab.session == null || mutating
        ? null
        : (action) => manageTabSession(tab, selected: action),
    onGatewaySignIn: widget.onSwitchGateway,
    recent: tab.profile == profile ? recent : const [],
    onOpen: open,
    onOpenMessage: openMessage,
    messageTarget: messageTargets[tab.id],
    onMessageTargetOpened: (target) {
      if (identical(messageTargets[tab.id], target)) {
        setState(() => messageTargets.remove(tab.id));
      }
    },
    onCloseTab: () => closeTab(tab),
    onReopenTab: canReopenTab ? reopenTab : null,
    onShowTabs: showOpenTabs,
    tabCount: visible.length,
    onCycleTab: visible.length > 1 ? cycleTab : null,
    keyboardActive: tab.id == active.id,
    landscapeKeyboard: landscapeKeyboard,
    fileDropActive: !drawerVisible,
    // Phones use the tab switcher sheet; only wide layouts keep a strip.
    tabStrip:
        tab.id == active.id &&
            visible.length > 1 &&
            MediaQuery.sizeOf(context).width >= 840
        ? ValueListenableBuilder(
            valueListenable: tabActivities,
            builder: (_, activityByTab, _) => ChatTabStrip(
              tabs: visible,
              active: active.id,
              onSelect: selectTab,
              onClose: closeTab,
              onNew: () => open(),
              onMove: moveTab,
              onCloseGroup: closeTabGroup,
              onReload: widget.gateway.usable ? reloadTab : null,
              onSessionOptions: mutating ? null : manageTabSession,
              activityFor: (tab) => activityByTab[tab.id],
              titleColor: tabTitleColor,
              profileLabel: profileLabel,
              onReopen: canReopenTab ? reopenTab : null,
            ),
          )
        : null,
  );

  Future<void> openCronJobs() async {
    final owner = profile;
    final choice = await chooseCronJob(
      context,
      gateway: widget.gateway,
      profile: owner,
    );
    if (!mounted || choice == null || profile != owner) return;
    await openCron(
      jobId: choice.jobId,
      create: choice.intent == CronSheetIntent.create,
    );
  }

  Future<void> openCron({String? jobId, bool create = false}) async {
    final owner = profile;
    shell.currentState?.closeDrawer();
    final run = await Navigator.of(context).push<Json>(
      MaterialPageRoute(
        builder: (route) => CronPage(
          gateway: widget.gateway,
          profile: owner,
          initialJobId: jobId,
          startCreating: create,
          openConversation: (row) => Navigator.pop(route, row),
        ),
      ),
    );
    if (mounted && run != null && profile == owner) open(run);
  }

  Future<void> manageProfiles() async {
    shell.currentState?.closeDrawer();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileManager(
          service: ProfileService(widget.gateway),
          activeProfile: profile,
        ),
      ),
    );
    if (mounted) await load(refreshProfiles: true);
  }

  Future<void> openSettings() async {
    final tab = tabs.active;
    final session = tab?.session;
    await Navigator.push<void>(
      context,
      floatingPageRoute<void>(
        context,
        builder: (_) => MobileSettingsPage(
          gateway: widget.gateway,
          profile: profile,
          onGateway: widget.onSwitchGateway,
          notificationTarget: tab != null && session != null
              ? ConversationAlertTarget(
                  owner: ConversationAlertTarget.ownerFor(widget.gateway),
                  profile: tab.profile,
                  session: session,
                  title: tab.title ?? context.tr('未命名会话'),
                )
              : null,
        ),
      ),
    );
  }

  String profileLabel(String name) =>
      profiles[name]?.displayLabel(context.strings) ??
      context.strings.profileName(name);

  /// Section titles ([strong]) read as headings; date groups stay quiet.
  Widget libraryHeading(
    BuildContext context,
    String label, {
    bool strong = false,
  }) => Padding(
    padding: EdgeInsetsDirectional.fromSTEB(
      strong ? 22 : 12,
      strong ? 18 : 12,
      10,
      strong ? 6 : 2,
    ),
    child: Semantics(
      header: true,
      child: Text(
        context.tr(label),
        style: strong
            ? Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)
            : Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
      ),
    ),
  );

  Widget libraryTile(LibraryEntry entry, {Widget? trailing}) {
    final row = entry.row;
    final id = tabSessionId(row);
    final roster = activeConversations[profile];
    final turns = liveTurns[profile];
    final lineage = sessionLineage(row);
    final activity =
        (turns?[id] ?? turns?[lineage]) ??
        (roster?.contains(id) == true || roster?.contains(lineage) == true
            ? ConversationActivity.background
            : null);
    final current = selected;
    final isSelected = current != null && sessionLineage(current) == lineage;
    final showActions = id != null && (isSelected || archived);
    return ConversationTile(
      key: ValueKey(id),
      row: row,
      titleColor: id == null
          ? null
          : tabs.titleColor(profile, id, sessionLineage(row)),
      depth: entry.depth,
      lastBranch: entry.last,
      activity: archived ? null : activity,
      selected: isSelected,
      onTap: () => open(row),
      onLongPress: () => sessionActions(row),
      trailing: showActions
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: context.tr('会话选项'),
                  onPressed: () => sessionActions(row),
                  icon: const Icon(Icons.more_horiz_rounded, size: 20),
                ),
                ?trailing,
              ],
            )
          : trailing,
    );
  }

  Widget libraryFooter(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (error case final text?) {
      return ListTile(
        title: Text(context.tr(text)),
        trailing: IconButton(
          tooltip: context.tr('重新读取'),
          onPressed: load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      );
    }
    if (more) {
      return TextButton(
        onPressed: () => load(append: true),
        child: Text(context.tr('更多会话')),
      );
    }
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Center(
          child: Text(context.tr(query.isEmpty ? '暂无会话' : '没有找到会话')),
        ),
      );
    }
    return const SizedBox(height: 10);
  }

  Widget library(BuildContext context) => SafeArea(
    bottom: false,
    child: LayoutBuilder(
      builder: (context, bounds) =>
          buildLibrary(context, short: bounds.maxHeight < 295),
    ),
  );

  Future<void> toggleArchive() {
    debounce?.cancel();
    if (query.isEmpty && rows.isNotEmpty) {
      archiveLists[archived] = (rows: rows, nextOffset: nextOffset, more: more);
    }
    final cached = query.isEmpty ? archiveLists.remove(!archived) : null;
    setState(() {
      archived = !archived;
      rows = cached?.rows ?? [];
      nextOffset = cached?.nextOffset ?? 0;
      more = cached?.more ?? false;
    });
    return load(retain: cached != null);
  }

  Future<void> chooseProfile(Rect anchor) async {
    final chosen = await showGlassMenu<Object>(
      context,
      anchor: anchor,
      width: 240,
      items: [
        for (final p in profiles.values)
          GlassMenuItem(
            value: p.name,
            icon: p.name == profile
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            label: profileLabel(p.name),
          ),
        GlassMenuItem(
          value: _ProfileMenuAction.manage,
          icon: Icons.manage_accounts_outlined,
          label: context.tr('管理档案'),
          separated: true,
        ),
        GlassMenuItem(
          value: _ProfileMenuAction.refresh,
          icon: Icons.refresh_rounded,
          label: context.tr('刷新配置档案列表'),
        ),
      ],
    );
    if (!mounted) return;
    switch (chosen) {
      case _ProfileMenuAction.manage:
        manageProfiles();
      case _ProfileMenuAction.refresh:
        load(refreshProfiles: true, retain: true);
      case String p when p != profile:
        selectTab(
          tabs.preferredOpen(p) ?? tabs.activate(p, null),
          closeDrawer: false,
        );
    }
  }

  Future<void> libraryMore(Rect anchor) async {
    final chosen = await showGlassMenu<_LibraryMore>(
      context,
      anchor: anchor,
      width: 236,
      items: [
        GlassMenuItem(
          value: _LibraryMore.bookmarks,
          icon: Icons.bookmarks_outlined,
          label: context.tr('消息书签'),
        ),
        GlassMenuItem(
          value: _LibraryMore.archive,
          icon: Icons.archive_outlined,
          label: context.tr(archived ? '返回会话' : '已归档'),
          enabled: !mutating,
        ),
        GlassMenuItem(
          value: _LibraryMore.profiles,
          icon: Icons.manage_accounts_outlined,
          label: context.tr('管理档案'),
          separated: true,
        ),
        GlassMenuItem(
          value: _LibraryMore.gateway,
          icon: Icons.dns_outlined,
          label: context.tr('切换网关'),
          enabled: widget.onSwitchGateway != null,
        ),
      ],
    );
    if (!mounted || chosen == null) return;
    switch (chosen) {
      case _LibraryMore.bookmarks:
        openBookmarks();
      case _LibraryMore.archive:
        toggleArchive();
      case _LibraryMore.profiles:
        manageProfiles();
      case _LibraryMore.gateway:
        shell.currentState?.closeDrawer();
        widget.onSwitchGateway?.call();
    }
  }

  void stopSearching() {
    search.clear();
    filter('');
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => searching = false);
  }

  /// The sidebar reads as one sheet of frosted glass: profile at the top,
  /// four large destinations, then the conversations as plain rows. New
  /// chat, search and settings float at the bottom within thumb reach.
  Widget buildLibrary(BuildContext context, {required bool short}) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final (:pins, :sessions) = libraryRows;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final showSearch = searching || query.isNotEmpty;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Stack(
          children: [
            Positioned.fill(
              child: RefreshIndicator(
                onRefresh: load,
                child: CustomScrollView(
                  key: PageStorageKey('$profile/$archived/$query'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      key: const ValueKey('conversation-search'),
                      child: showSearch
                          ? libraryFindBar(context)
                          : libraryProfileBar(context),
                    ),
                    if (!short && !showSearch && !archived)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                        sliver: SliverToBoxAdapter(
                          child: LibraryShortcuts(
                            items: [
                              LibraryShortcut(
                                icon: Icons.bolt_rounded,
                                label: context.tr('进行中'),
                                count:
                                    activeConversations[profile]?.length ?? 0,
                                onTap: profile.isEmpty
                                    ? null
                                    : openActiveConversations,
                              ),
                              LibraryShortcut(
                                icon: Icons.mark_chat_unread_outlined,
                                label: context.tr('未读'),
                                count: unreadConversationCount(profile),
                                onTap:
                                    sessionMetadata[profile]
                                            ?.unreadRows
                                            .value ==
                                        null
                                    ? null
                                    : openUnreadConversations,
                              ),
                              LibraryShortcut(
                                icon: Icons.schedule_rounded,
                                label: context.tr('定时任务'),
                                onTap: profile.isEmpty ? null : openCronJobs,
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (archived)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: context.tr('返回会话'),
                                onPressed: mutating ? null : toggleArchive,
                                icon: const Icon(Icons.arrow_back_rounded),
                              ),
                              Text(
                                context.tr('已归档'),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (pins.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: libraryHeading(context, '置顶', strong: true),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        sliver: SliverReorderableList(
                          itemCount: pins.length,
                          onReorderItem: (from, to) =>
                              reorderPins(pins, from, to),
                          proxyDecorator: (child, _, _) => child,
                          itemBuilder: (context, index) => libraryTile(
                            pins[index],
                            trailing: pins.length < 2
                                ? null
                                : ReorderableDragStartListener(
                                    index: index,
                                    child: Tooltip(
                                      message: context.tr('拖动排序'),
                                      child: SizedBox.square(
                                        dimension: 44,
                                        child: Icon(
                                          Icons.drag_indicator_rounded,
                                          size: 18,
                                          color: c.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ],
                    if (!archived && sessions.isNotEmpty)
                      SliverToBoxAdapter(
                        child: libraryHeading(context, '会话', strong: true),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      sliver: SliverList.builder(
                        itemCount: sessions.length,
                        itemBuilder: (context, index) {
                          final entry = sessions[index];
                          return Column(
                            key: ValueKey(tabSessionId(entry.row)),
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (entry.heading case final heading?)
                                libraryHeading(
                                  context,
                                  heading.label ??
                                      MaterialLocalizations.of(context)
                                          .formatMonthYear(heading.month!),
                                ),
                              libraryTile(entry),
                            ],
                          );
                        },
                      ),
                    ),
                    SliverToBoxAdapter(child: libraryFooter(context)),
                    // Room to scroll the last rows above the floating bar.
                    const SliverToBoxAdapter(child: SizedBox(height: 92)),
                  ],
                ),
              ),
            ),
            if (!keyboard)
              Positioned(
                left: 16,
                right: 16,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        FilledButton.icon(
                          onPressed: profile.isEmpty ? null : () => open(),
                          style: FilledButton.styleFrom(
                            backgroundColor: c.onSurface,
                            foregroundColor: c.surface,
                            minimumSize: const Size(0, 52),
                            padding: const EdgeInsets.symmetric(horizontal: 22),
                            elevation: 4,
                            shadowColor: Colors.black.withValues(alpha: .3),
                          ),
                          icon: const Icon(Icons.edit_square, size: 20),
                          label: Text(
                            context.tr('新建'),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Spacer(),
                        GlassSurface(
                          radius: 26,
                          child: SizedBox(
                            height: 52,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(width: 4),
                                IconButton(
                                  tooltip: context.tr('搜索当前档案的会话'),
                                  onPressed: () =>
                                      setState(() => searching = true),
                                  icon: const Icon(Icons.search_rounded),
                                ),
                                IconButton(
                                  tooltip: context.tr('设置'),
                                  onPressed: openSettings,
                                  icon: const Icon(Icons.settings_outlined),
                                ),
                                const SizedBox(width: 4),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Profile switcher as one soft pill: round avatar, name, chevron.
  Widget libraryProfileBar(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
      child: Row(
        children: [
          Flexible(
            child: Builder(
              builder: (anchor) => Material(
                color: c.onSurface.withValues(alpha: .05),
                shape: const StadiumBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => chooseProfile(globalRectOf(anchor)),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(5, 5, 12, 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipOval(child: const BrandMark(size: 30)),
                        const SizedBox(width: 9),
                        Flexible(
                          child: Text(
                            profile.isEmpty
                                ? context.tr('档案')
                                : profileLabel(profile),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 19,
                          color: c.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          Builder(
            builder: (anchor) => IconButton(
              tooltip: context.tr('更多'),
              onPressed: () => libraryMore(globalRectOf(anchor)),
              icon: Icon(Icons.more_horiz_rounded, color: c.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget libraryFindBar(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: search,
            autofocus: searching,
            onChanged: filter,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: context.tr('搜索当前档案的会话'),
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
            ),
          ),
        ),
        TextButton(onPressed: stopSearching, child: Text(context.tr('取消'))),
      ],
    ),
  );
}

enum _LibraryMore { bookmarks, archive, profiles, gateway }
