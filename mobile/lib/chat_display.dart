import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'gateway.dart';

enum MessageSize {
  small('小', 14),
  standard('标准', 16),
  large('大', 18),
  extraLarge('特大', 20);

  const MessageSize(this.label, this.points);
  final String label;
  final double points;
}

enum ReasoningVisibility {
  gateway('跟随网关'),
  visible('显示'),
  hidden('隐藏');

  const ReasoningVisibility(this.label);
  final String label;

  bool shows(ProfileReasoning profile) => switch (this) {
    gateway => profile.visible,
    visible => true,
    hidden => false,
  };
}

enum ReasoningPresentation { preview, expanded, collapsed }

class ProfileReasoning extends ChangeNotifier {
  ProfileReasoning._(this._gateway, this._profile);

  static final _byGateway = Expando<Map<String, ProfileReasoning>>();

  static ProfileReasoning of(Gateway gateway, String profile) =>
      (_byGateway[gateway] ??= {}).putIfAbsent(
        profile,
        () => ProfileReasoning._(gateway, profile),
      );

  final Gateway _gateway;
  final String _profile;
  bool _visible = false;
  ReasoningPresentation _presentation = ReasoningPresentation.preview;
  int? _loadedConnection;
  ({int connection, int revision})? _loadingFor;
  int _revision = 0;
  Future<void>? _loading;

  bool get visible => _visible;
  ReasoningPresentation get presentation => _presentation;

  Future<void> refresh({bool force = false}) async {
    final connection = _gateway.connectionRevision;
    if (_loading case final pending?
        when _loadingFor == (connection: connection, revision: _revision)) {
      return pending;
    }
    if (_loadedConnection == connection && !force) return;
    final stamp = (connection: connection, revision: ++_revision);
    final pending = _read(stamp.revision, connection);
    _loading = pending;
    _loadingFor = stamp;
    try {
      await pending;
    } finally {
      if (identical(_loading, pending)) {
        _loading = null;
        _loadingFor = null;
      }
    }
  }

  Future<void> _read(int revision, int connection) async {
    Json config;
    try {
      config = await _gateway.api(
        'api/config',
        query: {'profile': _profile},
        timeout: const Duration(seconds: 8),
      );
    } on GatewayError catch (error) {
      if (!{404, 405, 501}.contains(error.status)) return;
      config = const {};
    } catch (_) {
      return;
    }
    if (revision != _revision || connection != _gateway.connectionRevision) {
      return;
    }
    final display = _configSection(config, 'display');
    final cli = _configSection(_configSection(display, 'platforms'), 'cli');
    final visible = cli['show_reasoning'] ?? display['show_reasoning'];
    final section =
        _configSection(cli, 'sections')['thinking'] ??
        _configSection(display, 'sections')['thinking'];
    _loadedConnection = connection;
    _set(
      visible != false && visible != 'false' && visible != 0,
      switch (section) {
        'collapsed' => ReasoningPresentation.collapsed,
        'expanded' => ReasoningPresentation.expanded,
        _ => ReasoningPresentation.preview,
      },
    );
  }

  void apply(String command) {
    _revision++;
    switch (command) {
      case 'show' || 'on':
        _set(true, ReasoningPresentation.expanded);
      case 'hide' || 'off':
        _set(false, _presentation);
      case 'full':
        _set(_visible, ReasoningPresentation.expanded);
      case 'clamp':
        _set(_visible, ReasoningPresentation.collapsed);
    }
    if ((command == 'full' || command == 'clamp') &&
        _loadedConnection == null) {
      unawaited(refresh());
    }
  }

  void _set(bool visible, ReasoningPresentation presentation) {
    if (visible == _visible && presentation == _presentation) return;
    _visible = visible;
    _presentation = presentation;
    notifyListeners();
  }
}

Json _configSection(Json node, String key) =>
    node[key] is Json ? node[key] as Json : const {};

class TranscriptTextSize extends StatelessWidget {
  const TranscriptTextSize({
    super.key,
    required this.size,
    required this.child,
  });

  final MessageSize size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final factor = size.points / MessageSize.standard.points;
    return MediaQuery(
      data: factor == 1
          ? media
          : media.copyWith(
              textScaler: _MessageScaler(media.textScaler, factor),
            ),
      child: child,
    );
  }
}

class _MessageScaler extends TextScaler {
  const _MessageScaler(this.system, this.factor);

  final TextScaler system;
  final double factor;

  @override
  double scale(double fontSize) => system.scale(fontSize * factor);

  @override
  double get textScaleFactor => scale(16) / 16;

  @override
  bool operator ==(Object other) =>
      other is _MessageScaler &&
      other.system == system &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(system, factor);
}
