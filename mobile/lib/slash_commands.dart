import 'gateway.dart';
import 'models.dart';

enum SlashRoute { local, diagnostic, extension }

class SlashCommand {
  const SlashCommand(
    this.name,
    this.hint,
    this.group, {
    this.route = SlashRoute.local,
    this.options = const [],
    this.arguments = false,
    this.browse = true,
    this.skill = false,
  });

  final String name, hint, group;
  final SlashRoute route;
  final List<String> options;
  final bool arguments, browse, skill;

  String get draft => '/$name${arguments || options.isNotEmpty ? ' ' : ''}';
}

const reasoningDisplayOptions = ['show', 'hide', 'on', 'off', 'full', 'clamp'];

const localSlashCommands = [
  SlashCommand('new', '开始新会话', '会话'),
  SlashCommand('resume', '查找并打开历史会话', '会话', arguments: true),
  SlashCommand('find', '搜索当前会话的消息', '会话'),
  SlashCommand('agents', '查看子代理和后台进程', '会话'),
  SlashCommand('branch', '从当前会话创建分支', '会话'),
  SlashCommand('title', '重命名当前会话', '会话', arguments: true),
  SlashCommand('save', '导出当前会话', '会话', options: ['md', 'json']),
  SlashCommand('stop', '停止当前回复', '会话'),
  SlashCommand('model', '选择对话模型', '配置'),
  SlashCommand(
    'reasoning',
    '设置推理强度和思考显示',
    '配置',
    options: [
      'none',
      'minimal',
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
      'ultra',
      'show',
      'hide',
      'on',
      'off',
      'full',
      'clamp',
    ],
  ),
  SlashCommand('cron', '管理当前档案的定时任务', '工具与技能'),
  SlashCommand('files', '查看工作区文件', '工具与技能'),
  SlashCommand('review', '审查工作区改动', '工具与技能'),
  SlashCommand('copy', '复制最后一条助手回复', '信息'),
  SlashCommand('version', '查看网关版本', '信息'),
  SlashCommand('help', '浏览会话和命令', '信息'),
  SlashCommand('settings', '打开设置', '配置'),
  SlashCommand('commands', '浏览斜杠命令和技能', '信息'),
];

const _diagnostics = <String, (String, String)>{
  'status': ('查看会话和模型状态', '会话'),
  'context': ('查看上下文用量和压缩信息', '会话'),
  'personality': ('查看或选择会话人格', '配置'),
  'profile': ('查看当前档案', '信息'),
  'usage': ('查看用量和限额', '信息'),
  'whoami': ('查看当前命令权限', '信息'),
  'diff': ('查看工作区差异', '信息'),
  'bundles': ('列出技能组合', '工具与技能'),
  'skills': ('查看待审核的技能', '工具与技能'),
  'memory': ('查看待审核的记忆', '工具与技能'),
  'suggestions': ('查看自动化建议', '工具与技能'),
};

SlashCommand? diagnosticSlash(String name) {
  final labels = _diagnostics[name];
  if (labels == null) return null;
  final (hint, group) = labels;
  return SlashCommand(name, hint, group, route: SlashRoute.diagnostic);
}

const _aliases = {
  'tasks': 'agents',
  'reset': 'new',
  'fork': 'branch',
  'sessions': 'resume',
  'switch': 'resume',
  'palette': 'help',
  'ctx': 'context',
  'v': 'version',
};

final _commandName = RegExp(r'^[\p{L}\p{N}_.-]+$', unicode: true);
final _input = RegExp(r'^/([^\s]+)(?:\s+([\s\S]*))?$');

typedef SlashInput = ({String name, String arg});

SlashInput? parseSlashInput(String text) {
  final match = _input.firstMatch(text.trim());
  final typed = match?.group(1)?.toLowerCase();
  if (typed == null || !_commandName.hasMatch(typed)) return null;
  return (name: _aliases[typed] ?? typed, arg: match?.group(2)?.trim() ?? '');
}

class QueuedSkill {
  const QueuedSkill(this.name, this.argument);
  final String name, argument;

  static QueuedSkill? fromWire(Json wire) {
    final name = wire['name'];
    final argument = wire['argument'];
    if (name is! String ||
        !_commandName.hasMatch(name) ||
        argument is! String) {
      return null;
    }
    return QueuedSkill(name, argument);
  }

  Json toWire() => {'name': name, 'argument': argument};
}

String? diagnosticArgument(String name, String arg) => switch (name) {
  'skills' || 'memory' when arg.isEmpty => 'pending',
  'skills' when arg == 'pending' || arg == 'diff' || arg.startsWith('diff ') =>
    arg,
  'memory' when arg == 'pending' => arg,
  'context' when arg == 'all' => arg,
  'diff' || 'personality' => arg,
  _ when arg.isEmpty => arg,
  _ => null,
};

bool validLocalArgument(String name, String arg) => switch (name) {
  'title' || 'resume' => true,
  'save' => ['', 'md', 'json'].contains(arg.toLowerCase()),
  'reasoning' =>
    arg.isEmpty ||
        effortLabels.containsKey(arg.toLowerCase()) ||
        reasoningDisplayOptions.contains(arg.toLowerCase()),
  _ => arg.isEmpty,
};

class SlashCatalog {
  SlashCatalog(Json wire) {
    final metadata = wire['commands'];
    final sub = wire['sub'];
    final skillMeta = wire['skills'];
    final extensions = <String, SlashCommand>{};
    final skillUsage = <String, int>{};
    void register(Object? pair, {String? extensionGroup}) {
      if (pair is! List || pair.isEmpty || pair.first is! String) return;
      final key = pair.first as String;
      final name = key.replaceFirst(RegExp(r'^/'), '').toLowerCase();
      if (!_commandName.hasMatch(name) ||
          _aliases.containsKey(name) ||
          localSlashCommands.any((entry) => entry.name == name)) {
        return;
      }
      final (hint, group) = _diagnostics[name] ?? ('', '');
      final exposed = metadata is Json ? metadata['/$name'] : null;
      if (group.isNotEmpty) {
        if (exposed is Json &&
            exposed['desktop'] is String &&
            exposed['desktop'] != 'advanced') {
          return;
        }
        final args = sub is Json ? sub['/$name'] : null;
        entries[name] = SlashCommand(
          name,
          hint,
          group,
          route: SlashRoute.diagnostic,
          arguments: name == 'diff' || name == 'personality',
          options: args is List
              ? args
                    .whereType<String>()
                    .where(
                      (arg) =>
                          _commandName.hasMatch(arg) &&
                          diagnosticArgument(name, arg) != null,
                    )
                    .toList()
              : const [],
        );
        return;
      }
      final meta = skillMeta is Json
          ? skillMeta[key] ?? skillMeta[name] ?? skillMeta['/$name']
          : null;
      if (extensionGroup == null && meta is! Json) return;
      final usage = meta is Json ? (meta['usage'] as num?)?.toInt() ?? 0 : 0;
      skillUsage[name] = usage;
      extensions[name] = SlashCommand(
        name,
        pair.length > 1 && pair[1] is String ? pair[1] as String : '',
        extensionGroup ?? '技能',
        route: SlashRoute.extension,
        arguments: true,
        skill: extensionGroup == null && meta is Json,
        browse: meta is! Json || usage > 0 || meta['origin'] != 'bundled',
      );
    }

    final categories = wire['categories'];
    if (categories is List) {
      for (final category in categories.whereType<Json>()) {
        final group = switch (category['name']) {
          'User commands' => '自定义命令',
          'Plugin commands' => '插件命令',
          _ => null,
        };
        final pairs = category['pairs'];
        if (pairs is List) {
          for (final pair in pairs) {
            register(pair, extensionGroup: group);
          }
        }
      }
    }
    final pairs = wire['pairs'];
    if (pairs is List) {
      for (final pair in pairs) {
        if (pair is List &&
            pair.isNotEmpty &&
            pair.first is String &&
            extensions.containsKey(
              (pair.first as String)
                  .replaceFirst(RegExp(r'^/'), '')
                  .toLowerCase(),
            )) {
          continue;
        }
        register(pair);
      }
    }
    final discovered = extensions.values.toList()
      ..sort((a, b) {
        final usage = skillUsage[b.name]!.compareTo(skillUsage[a.name]!);
        return usage == 0 ? a.name.compareTo(b.name) : usage;
      });
    for (final command in discovered) {
      entries[command.name] = command;
    }
  }

  final entries = {
    for (final command in localSlashCommands) command.name: command,
  };

  List<SlashCommand> search(String text, {String Function(String)? translate}) {
    final keyword = text.trim().replaceFirst(RegExp(r'^/'), '').toLowerCase();
    if (keyword.isEmpty) {
      return entries.values.where((command) => command.browse).toList();
    }
    return [
      ...entries.values.where((c) => c.name.startsWith(keyword)),
      ...entries.values.where(
        (c) =>
            !c.name.startsWith(keyword) &&
            (c.name.contains(keyword) ||
                c.hint.toLowerCase().contains(keyword) ||
                translate?.call(c.hint).toLowerCase().contains(keyword) ==
                    true),
      ),
    ];
  }
}

class SlashDirective {
  SlashDirective(Json reply)
    : type = reply['type'] as String?,
      message = reply['message'] as String? ?? '',
      target = reply['target'] as String? ?? '',
      display = reply['display'] as String? ?? '',
      output = [reply['warning'], reply['output'], reply['notice']]
          .whereType<String>()
          .where((part) => part.trim().isNotEmpty)
          .join('\n\n');

  final String? type;
  final String message, target, display, output;

  ({String prompt, String display}) promptFor(String command) {
    if ((type != 'skill' && type != 'send') || message.trim().isEmpty) {
      throw GatewayError('网关未返回可发送的技能内容');
    }
    return (
      prompt: message,
      display: display.trim().isEmpty ? command.trim() : display,
    );
  }
}

class SlashService {
  const SlashService(this.gateway, this.profile, this.runtime);

  final Gateway gateway;
  final String profile;
  final String? runtime;

  Json get scope => {'profile': profile, 'session_id': ?runtime};

  Future<SlashCatalog> catalog() async => SlashCatalog(
    await gateway.call(
      'commands.catalog',
      scope,
      timeout: const Duration(seconds: 8),
    ),
  );

  Future<Json> complete(String text) => gateway.call('complete.slash', {
    ...scope,
    'text': text,
  }, timeout: const Duration(seconds: 5));

  Future<SlashDirective> run(SlashCommand command, String arg) async {
    if (runtime == null) throw GatewayError('请先打开会话');
    if (command.route == SlashRoute.extension) {
      return SlashDirective(
        await gateway.call('command.dispatch', {
          ...scope,
          'name': command.name,
          'arg': arg,
        }),
      );
    }
    final tail = diagnosticArgument(command.name, arg);
    if (tail == null) throw GatewayError('请选择命令支持的参数');
    return SlashDirective(
      await gateway.call('slash.exec', {
        ...scope,
        'command': '/${command.name}${tail.isEmpty ? '' : ' $tail'}',
      }),
    );
  }
}
