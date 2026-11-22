import 'gateway.dart';
import 'mobile_locale.dart';

class GatewayProfile {
  const GatewayProfile({
    required this.name,
    required this.label,
    required this.path,
    required this.model,
    required this.provider,
    required this.isDefault,
    required this.hasEnv,
    required this.skillCount,
  });

  final String name, label, path, model, provider;
  final bool isDefault, hasEnv;
  final int? skillCount;

  String displayLabel(MobileStrings strings) =>
      label == name ? strings.profileName(name) : label;

  static GatewayProfile? fromWire(Json row) {
    final name = (row['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) return null;
    final label = (row['display_name'] as String?)?.trim() ?? '';
    return GatewayProfile(
      name: name,
      label: label.isEmpty ? name : label,
      path: (row['path'] as String?) ?? '',
      model: (row['model'] as String?) ?? '',
      provider: (row['provider'] as String?) ?? '',
      isDefault: row['is_default'] == true || name == 'default',
      hasEnv: row['has_env'] == true,
      skillCount: row['skill_count'] as int?,
    );
  }
}

enum ProfileDocument {
  soul('SOUL.md'),
  memory('MEMORY.md'),
  user('USER.md');

  const ProfileDocument(this.filename);
  final String filename;
}

typedef SoulSnapshot = ({String content, bool exists});

class ProfileService {
  const ProfileService(this.gateway);
  final Gateway gateway;

  static final _namePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  static bool validName(String name) => _namePattern.hasMatch(name);

  Future<List<GatewayProfile>> list() async {
    final reply = await gateway.api('api/profiles');
    final rows = reply['profiles'];
    if (rows is! List) throw GatewayError('网关未返回配置档案列表');
    return rows
        .whereType<Json>()
        .map(GatewayProfile.fromWire)
        .nonNulls
        .toList();
  }

  Future<void> create(String name, {String? cloneFrom}) async {
    if (!validName(name)) {
      throw GatewayError('请使用小写字母或数字开头，最多 64 个字符，可包含短横线和下划线');
    }
    final reply = await gateway.api(
      'api/profiles',
      method: 'POST',
      body: {
        'name': name,
        'clone_from': cloneFrom,
        'clone_channels': false,
        'mirror_credentials': false,
        'share_auth': false,
      },
    );
    if (reply['ok'] != true) throw GatewayError('网关未确认创建配置档案');
  }

  Future<SoulSnapshot> soul(String name) async {
    final reply = await gateway.api(_soulPath(name), query: {'profile': name});
    final content = reply['content'];
    final exists = reply['exists'];
    if (content is! String || exists is! bool) {
      throw GatewayError('网关未返回可读取的 SOUL.md');
    }
    return (content: content, exists: exists);
  }

  /// Recheck the original document immediately before a write, just as Desktop does.
  Future<bool> saveSoul(
    String name,
    SoulSnapshot original,
    String content,
  ) async {
    final remote = await soul(name);
    if (remote.exists && remote.content == content) return true;
    if (remote != original) return false;
    final reply = await gateway.api(
      _soulPath(name),
      method: 'PUT',
      query: {'profile': name},
      body: {'content': content},
    );
    if (reply['ok'] != true) throw GatewayError('网关未确认保存 SOUL.md');
    return true;
  }

  Future<String> memory(
    GatewayProfile profile,
    ProfileDocument document,
  ) async {
    if (document == ProfileDocument.soul) throw ArgumentError.value(document);
    final root = profile.path.replaceFirst(RegExp(r'[/\\]+$'), '');
    if (root.isEmpty) throw GatewayError('网关未提供该档案的目录');
    final reply = await gateway.api(
      'api/fs/read-text',
      query: {
        'profile': profile.name,
        'path': '$root/memories/${document.filename}',
      },
    );
    if (reply['truncated'] == true) throw GatewayError('记忆文件超过网关的预览上限');
    final text = reply['text'];
    if (text is! String) throw GatewayError('网关未返回记忆原文');
    return text;
  }

  String _soulPath(String name) =>
      'api/profiles/${Uri.encodeComponent(name)}/soul';
}
