import 'package:uuid/uuid.dart';

import 'gateway.dart';

const effortLabels = {
  'none': '无',
  'minimal': '最低',
  'low': '低',
  'medium': '中',
  'high': '高',
  'xhigh': '极高',
  'max': '最大',
  'ultra': '超强',
};
const speedLabels = {'normal': '标准', 'fast': 'Fast', 'ultrafast': 'Ultrafast'};

String? normalizeModelSpeed(Object? value) => switch (value) {
  '' || 'normal' || 'off' => 'normal',
  'fast' || 'priority' || 'on' => 'fast',
  'ultrafast' || 'ultra' => 'ultrafast',
  _ => null,
};

class ModelChoice {
  const ModelChoice(
    this.id,
    this.provider, {
    this.providerName = '',
    this.aliases = const [],
    this.available = true,
    this.fast = false,
    this.ultrafast = false,
    this.reasoning,
    this.canDisableReasoning = true,
  });
  final String id, provider, providerName;
  final List<String> aliases;
  final bool available, fast, ultrafast, canDisableReasoning;
  final bool? reasoning;

  bool matches(String? model, String? source) =>
      id == model &&
      (source == provider ||
          source?.isEmpty != false ||
          aliases.contains(source));

  String? supportedEffort(String? value) =>
      reasoning == false || (value == 'none' && !canDisableReasoning)
      ? null
      : value;
  String? supportedSpeed(String? value) => switch (value) {
    'fast' when fast => value,
    'ultrafast' when ultrafast => value,
    'normal' when fast || ultrafast => value,
    _ => null,
  };
}

class ModelCatalog {
  const ModelCatalog(this.models, this.current, {this.codex = false});
  final List<ModelChoice> models;
  final ModelChoice? current;
  final bool codex;

  factory ModelCatalog.fromWire(Json value) {
    final providers = value['providers'];
    if (providers is! List) throw GatewayError('网关未返回模型列表');
    final models = <ModelChoice>[];
    var codex = false;
    for (final provider in providers.whereType<Json>()) {
      final slug = provider['slug'] as String?;
      if (slug == null || slug.isEmpty) continue;
      codex |= isCodex(slug) && provider['authenticated'] != false;
      final aliases = provider['aliases'];
      final names = aliases is List
          ? aliases.whereType<String>().toList()
          : const <String>[];
      final blocked = (provider['unavailable_models'] as List?) ?? [];
      for (final id
          in ((provider['models'] as List?) ?? []).whereType<String>()) {
        final caps = provider['capabilities']?[id];
        models.add(
          ModelChoice(
            id,
            slug,
            providerName: provider['name'] as String? ?? slug,
            aliases: names,
            available:
                provider['authenticated'] != false && !blocked.contains(id),
            fast: caps?['fast'] == true,
            ultrafast: caps?['ultrafast'] == true,
            reasoning: caps?['reasoning'] as bool?,
            canDisableReasoning: caps?['can_disable_reasoning'] != false,
          ),
        );
      }
    }
    final id = value['model'];
    final provider = value['provider'] as String? ?? '';
    final current = id is String && id.isNotEmpty
        ? models.where((item) => item.matches(id, provider)).firstOrNull ??
              ModelChoice(id, provider)
        : null;
    return ModelCatalog(models, current, codex: codex);
  }

  static Future<ModelCatalog> load(
    Gateway gateway,
    String profile,
    String? runtime, {
    required bool refresh,
  }) async {
    final canonical = gateway.canonical;
    try {
      final catalog = ModelCatalog.fromWire(
        await gateway.call(
          'model.options',
          {
            'profile': profile,
            'explicit_only': true,
            'refresh': refresh,
            'session_id': ?runtime,
          },
          timeout: refresh
              ? const Duration(seconds: 120)
              : const Duration(seconds: 15),
        ),
      );
      if (canonical || catalog.models.isNotEmpty) return catalog;
    } on GatewayError catch (error) {
      if (canonical && error.code != -32601) rethrow;
      // Earlier gateways expose the catalog through HTTP only.
    }
    return ModelCatalog.fromWire(
      await inventory(gateway, profile, refresh: refresh),
    );
  }

  static bool isCodex(String provider) =>
      provider == 'openai-codex' || provider == 'codex';

  static Future<Json> inventory(
    Gateway gateway,
    String profile, {
    required bool refresh,
  }) => gateway.api(
    'api/model/options',
    query: {'profile': profile, 'explicit_only': 'true', 'refresh': '$refresh'},
    timeout: refresh
        ? const Duration(seconds: 120)
        : const Duration(seconds: 30),
  );
}

typedef ModelVersion = ({int revision, int generation});

ModelVersion? modelVersion(dynamic wire) {
  if (wire is! Json ||
      wire['revision'] is! int ||
      wire['execution_generation'] is! int) {
    return null;
  }
  return (
    revision: wire['revision'] as int,
    generation: wire['execution_generation'] as int,
  );
}

bool modelConfirmationRequired(Json result) =>
    result['confirm_required'] == true ||
    result['status'] == 'confirmation_required';

class SessionModelControls {
  SessionModelControls({
    required this.gateway,
    required this.profile,
    required this.stored,
    required this.runtime,
    this.version,
  });
  final Gateway gateway;
  final String profile, stored, runtime;
  ModelVersion? version;
  ({String token, ModelVersion version})? _confirmation;

  bool isOlderVersion(ModelVersion candidate) {
    final observed = version;
    return observed != null &&
        (candidate.generation < observed.generation ||
            candidate.generation == observed.generation &&
                candidate.revision < observed.revision);
  }

  void observeVersion(ModelVersion candidate) {
    if (!isOlderVersion(candidate)) version = candidate;
  }

  Future<ModelVersion> _snapshot() async {
    final snap = await gateway.mutationSnapshot(stored, profile);
    if (snap == null) throw GatewayError('无法读取会话版本');
    return (
      revision: snap['runtime_revision'] as int,
      generation: snap['runtime_generation'] as int,
    );
  }

  Future<Json> change({
    ModelChoice? model,
    String? effort,
    String? speed,
    String? confirmation,
    bool confirmed = false,
    bool Function()? stillAttached,
  }) async {
    void checkAttachment() {
      if (stillAttached?.call() == false) throw GatewayDisconnected();
    }

    checkAttachment();
    if (!gateway.canonical || speed != null) {
      if (model != null &&
          (RegExp(r'(?:^|\s)(?:--|[‒–—―])').hasMatch(model.id) ||
              RegExp(r'\s').hasMatch(model.provider))) {
        throw GatewayError('网关不支持切换到此模型标识');
      }
      return gateway.call('config.set', {
        'session_id': runtime,
        'profile': profile,
        'key': model != null
            ? 'model'
            : speed != null
            ? 'fast'
            : 'reasoning',
        'value': model != null
            ? '${model.id} --provider ${model.provider} --session'
            : speed ?? effort,
        if (speed == null) 'scope': 'session',
        if (speed == null) 'confirm_expensive_model': confirmed,
      });
    }
    final request = const Uuid().v4();
    Future<Json> submit(ModelVersion baseline) {
      checkAttachment();
      return gateway.call('session.mutate', {
        'session_id': stored,
        'profile': profile,
        'request_id': request,
        'expected_revision': baseline.revision,
        'expected_generation': baseline.generation,
        'operation': model != null ? 'model' : 'reasoning',
        'payload': <String, dynamic>{
          if (model != null) ...{
            'model': model.id,
            'provider': model.provider,
            'reasoning': ?effort,
          } else
            'effort': effort,
          'confirm': ?confirmation,
        },
      });
    }

    final preview = _confirmation;
    _confirmation = null;
    if (confirmed && (preview == null || confirmation != preview.token)) {
      throw GatewayError('确认已失效，请重新选择模型');
    }
    var sentVersion = confirmed
        ? preview!.version
        : version ?? await _snapshot();
    Json result;
    try {
      result = await submit(sentVersion);
    } on GatewayError catch (e) {
      if (!{
        'revision_conflict',
        'stale_generation',
      }.contains(e.data?['reason'] ?? e.message)) {
        rethrow;
      }
      if (confirmed) throw GatewayError('确认已失效，请重新选择模型');
      checkAttachment();
      final refreshed = modelVersion(e.data) ?? await _snapshot();
      observeVersion(refreshed);
      sentVersion = version ?? refreshed;
      result = await submit(sentVersion);
    }
    if (result['confirm'] case final String token
        when !confirmed &&
            modelConfirmationRequired(result) &&
            token.isNotEmpty) {
      _confirmation = (token: token, version: sentVersion);
    }
    version ??= sentVersion;
    if (modelVersion(result) case final receipt?
        when receipt.generation == version?.generation) {
      observeVersion(receipt);
    }
    return result;
  }
}
