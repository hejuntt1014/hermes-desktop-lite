import 'package:material_ui/material_ui.dart';

import 'gateway.dart' show GatewayError, Json;
import 'mobile_clipboard.dart' show copyMobileText;
import 'mobile_locale.dart';
import 'mobile_themes.dart';
import 'media_gallery.dart';
import 'message_content.dart' show ChatImage;
import 'timeline.dart';
import 'transcript_navigation.dart';
import 'workspace.dart';

class ReasoningPreview extends StatefulWidget {
  const ReasoningPreview({
    super.key,
    required this.text,
    this.preview = true,
    this.initiallyExpanded = false,
  });

  final String text;
  final bool preview, initiallyExpanded;

  @override
  State<ReasoningPreview> createState() => _ReasoningPreviewState();
}

class _ReasoningPreviewState extends State<ReasoningPreview> {
  bool? expandedByUser;

  String get excerpt {
    if (widget.text.length <= 240) return widget.text;
    var from = widget.text.length - 240;
    final first = widget.text.codeUnitAt(from);
    if (first >= 0xdc00 && first <= 0xdfff) from++;
    return widget.text.substring(from).trimLeft();
  }

  Widget previewText(TextStyle style) => LayoutBuilder(
    builder: (context, constraints) {
      final tail = excerpt;
      final painter = TextPainter(
        text: TextSpan(text: tail, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final lines = painter.computeLineMetrics();
      final first = lines.length > 3 ? lines[lines.length - 3] : null;
      final start = first == null
          ? 0
          : painter
                .getLineBoundary(
                  painter.getPositionForOffset(Offset(0, first.baseline - 1)),
                )
                .start;
      painter.dispose();
      final preview = Text(
        tail.substring(start),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
      if (start == 0 && tail.length == widget.text.length) return preview;
      return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x66000000), Colors.black, Colors.black],
          stops: [0, .29, 1],
        ).createShader(bounds),
        child: preview,
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final expanded = expandedByUser ?? widget.initiallyExpanded;
    final showPreview = !expanded && expandedByUser == null && widget.preview;
    final style = Theme.of(context).textTheme.bodySmall!
        .copyWith(color: colors.onSurfaceVariant, height: 1.55);
    return _ActivityDisclosure(
      title: context.tr('正在思考'),
      icon: Icons.auto_awesome_outlined,
      running: true,
      expanded: expanded,
      onToggle: () => setState(() => expandedByUser = !expanded),
      body: expanded || showPreview
          ? _ActivityInset(
              child: expanded
                  ? SelectableText(widget.text, style: style)
                  : previewText(style),
            )
          : null,
    );
  }
}

enum _ActivityKind { skill, command, file, search, image, reasoning, other }

_ActivityKind _kind(ChatRow row) => switch (row.activity) {
  'skill_view' => _ActivityKind.skill,
  'terminal' || 'execute_code' => _ActivityKind.command,
  'read_file' || 'write_file' || 'list_files' || 'patch' => _ActivityKind.file,
  'search_files' ||
  'file_search' ||
  'web_search' ||
  'web_extract' => _ActivityKind.search,
  'vision_analyze' || 'image_generate' => _ActivityKind.image,
  '思考' => _ActivityKind.reasoning,
  _ => _ActivityKind.other,
};

const _kindIcon = {
  _ActivityKind.skill: Icons.extension_outlined,
  _ActivityKind.command: Icons.terminal_rounded,
  _ActivityKind.file: Icons.description_outlined,
  _ActivityKind.search: Icons.search_rounded,
  _ActivityKind.image: Icons.image_outlined,
  _ActivityKind.reasoning: Icons.auto_awesome_outlined,
  _ActivityKind.other: Icons.build_outlined,
};

String _action(ChatRow row) => switch (row.activity) {
  'skill_view' => '加载技能',
  'terminal' => '执行命令',
  'execute_code' => '运行代码',
  'read_file' => '读取文件',
  'write_file' => '写入文件',
  'list_files' => '查看目录',
  'patch' => '编辑文件',
  'search_files' || 'file_search' => '搜索文件',
  'web_search' => '搜索网页',
  'web_extract' => '读取网页',
  'vision_analyze' => '分析图片',
  'image_generate' => '生成图片',
  'todo' || 'todo_list' => '更新任务',
  'clarify' => '请求确认',
  'skill_manage' => '管理技能',
  'cronjob' => '定时任务',
  'send_message' => '发送消息',
  '思考' => '思考过程',
  _ => '工具调用',
};

String? _subject(ChatRow row) {
  final kind = _kind(row);
  final args = activityJson(row.arguments);
  if (kind == _ActivityKind.skill) {
    final target = _skillTarget(args) ?? _skillTarget(activityJson(row.body));
    return target == null ? null : _briefSubject(target);
  }
  final keys = switch (kind) {
    _ActivityKind.command => ['command', 'code'],
    _ActivityKind.file => ['path', 'file', 'file_path'],
    _ActivityKind.search => ['query', 'pattern', 'url'],
    _ => const <String>[],
  };
  for (final key in keys) {
    final value = args?[key];
    if (value is String && value.trim().isNotEmpty) {
      return _briefSubject(value);
    }
  }
  return null;
}

String? _skillTarget(Json? details) {
  final name = details?['name'];
  if (name is! String || name.trim().isEmpty) return null;
  final path = details?['file_path'] ?? details?['file'];
  return path is String && path.trim().isNotEmpty
      ? '${name.trim()} → ${path.trim()}'
      : name.trim();
}

String _briefSubject(String text) {
  final line = text.trim().split(RegExp(r'[\r\n]')).first;
  return line.length > 150 ? '${line.substring(0, 150)}…' : line;
}

class ActivityExpansion {
  final _groups = <Object, ({bool expanded, int revision})>{};
  final _steps = <Object, bool>{};
  int _revision = 0;

  Object? _identity(ChatRow row) => switch (row.toolId) {
    final id? when id.isNotEmpty => id,
    _ => row.rowId,
  };

  bool? group(List<ChatRow> rows) {
    ({bool expanded, int revision})? latest;
    for (final row in rows) {
      final choice = _groups[_identity(row)];
      if (choice != null &&
          (latest == null || choice.revision > latest.revision)) {
        latest = choice;
      }
    }
    return latest?.expanded;
  }

  void rememberGroup(List<ChatRow> rows, bool expanded) {
    final choice = (expanded: expanded, revision: ++_revision);
    for (final row in rows) {
      if (_identity(row) case final key?) _remember(_groups, key, choice);
    }
  }

  bool? step(ChatRow row) => _steps[_identity(row)];

  void rememberStep(ChatRow row, bool expanded) {
    if (_identity(row) case final key?) _remember(_steps, key, expanded);
  }

  void _remember<T>(Map<Object, T> entries, Object key, T value) {
    entries.remove(key);
    entries[key] = value;
    if (entries.length > 1024) entries.remove(entries.keys.first);
  }
}

class ActivityGroup extends StatefulWidget {
  const ActivityGroup({
    super.key,
    required this.activity,
    this.expansion,
    this.revealed = false,
    this.mediaScope,
    this.gallery,
    this.addressFor,
  });
  final TimelineActivity activity;
  final ActivityExpansion? expansion;
  final bool revealed;
  final WorkspaceScope? mediaScope;
  final Iterable<GalleryImage> Function()? gallery;
  final MessageAddress? Function(int rowId)? addressFor;

  @override
  State<ActivityGroup> createState() => _ActivityGroupState();
}

class _ActivityGroupState extends State<ActivityGroup> {
  bool? localExpansion;
  late final _ownExpansion = ActivityExpansion();
  ActivityExpansion get expansion => widget.expansion ?? _ownExpansion;
  final savedResults = <String, Future<String?>>{};

  @override
  void didUpdateWidget(covariant ActivityGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revealed != widget.revealed ||
        oldWidget.activity.expanded != widget.activity.expanded) {
      localExpansion = null;
    }
    if (!_sameScope(oldWidget.mediaScope, widget.mediaScope))
      savedResults.clear();
  }

  bool _sameScope(WorkspaceScope? a, WorkspaceScope? b) =>
      identical(a?.gateway, b?.gateway) &&
      a?.profile == b?.profile &&
      a?.session == b?.session;

  _SavedToolResult? _resultReader(ChatRow row) {
    final scope = widget.mediaScope;
    final session = scope?.session;
    final toolId = row.toolId;
    if (scope == null ||
        session == null ||
        toolId == null ||
        toolId.isEmpty ||
        row.running ||
        row.body.isNotEmpty)
      return null;
    return ({required bool retry}) {
      if (retry) savedResults.remove(toolId);
      return savedResults.putIfAbsent(toolId, () {
        final clock = Stopwatch()..start();
        const timeout = Duration(seconds: 45);
        final rowId = row.rowId;
        return TranscriptNavigation(scope.gateway, scope.profile, session)
            .storedToolResult(
              toolId,
              address: rowId == null
                  ? null
                  : widget.addressFor?.call(rowId) ?? MessageAddress(rowId),
              stillOpen: () =>
                  mounted &&
                  _sameScope(scope, widget.mediaScope) &&
                  clock.elapsed < timeout,
            )
            .timeout(timeout, onTimeout: () => throw GatewayError('读取工具结果超时'));
      });
    };
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.activity.rows;
    final expanded = widget.revealed
        ? localExpansion ?? true
        : expansion.group(rows) ?? localExpansion ?? widget.activity.expanded;
    final first = rows.first;
    final running = rows.any((row) => row.running);
    final failures = rows.where((row) => row.failed).length;
    final tools = rows
        .where((row) => _kind(row) != _ActivityKind.reasoning)
        .length;
    final title = switch ((rows.length, tools, running)) {
      (1, _, _) => context.tr(_action(first)),
      (_, 0, _) => context.tr('思考过程'),
      _ => context.strings.format(
        running ? '正在执行 · {tools} 项操作' : '执行过程 · {tools} 项操作',
        {'tools': tools},
      ),
    };
    final firstReader = _resultReader(first);
    final hasDetails =
        rows.length > 1 ||
        firstReader != null ||
        first.arguments.isNotEmpty ||
        first.inlineDiff.isNotEmpty ||
        first.body.isNotEmpty;
    final disclosure = _ActivityDisclosure(
      title: title,
      subject: rows.length == 1 ? _subject(first) : null,
      icon: rows.length == 1
          ? _kindIcon[_kind(first)]!
          : Icons.list_alt_rounded,
      status: switch ((failures, rows.length, running)) {
        (> 0, _, _) => context.strings.format('{failures} 项失败', {
          'failures': failures,
        }),
        (_, 1, true) => context.tr('运行中'),
        _ => null,
      },
      failed: failures > 0,
      running: running,
      expanded: expanded,
      onToggle: hasDetails
          ? () => setState(() {
              localExpansion = !expanded;
              if (!widget.revealed) expansion.rememberGroup(rows, !expanded);
            })
          : null,
      body: !expanded || !hasDetails
          ? null
          : _ActivityInset(
              child: rows.length == 1
                  ? _ActivityDetails(row: first, readResult: firstReader)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final row in rows)
                          _ActivityStep(
                            key: ValueKey(row.toolId ?? row.rowId ?? row),
                            row: row,
                            expansion: expansion,
                            readResult: _resultReader(row),
                          ),
                      ],
                    ),
            ),
    );
    final scope = widget.mediaScope;
    if (scope == null) return disclosure;
    final images = {
      for (final row in rows)
        if (row.imagePath case final path? when !row.failed) path,
    };
    if (images.isEmpty) return disclosure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        disclosure,
        for (final path in images)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: ChatImage(
                key: ValueKey(path),
                path: workspaceFilePath(path, scope.cwd),
                gateway: scope.gateway,
                profile: scope.profile,
                session: scope.session,
                gallery: widget.gallery,
              ),
            ),
          ),
      ],
    );
  }
}

class _ActivityDisclosure extends StatelessWidget {
  const _ActivityDisclosure({
    required this.title,
    required this.icon,
    this.status,
    this.subject,
    this.running = false,
    this.failed = false,
    this.expanded = false,
    this.onToggle,
    this.body,
  });

  final String title;
  final IconData icon;
  final String? status, subject;
  final bool running, failed, expanded;
  final VoidCallback? onToggle;
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = theme.textTheme.bodyMedium!.copyWith(
      color: colors.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
    final supporting = theme.textTheme.bodySmall!.copyWith(
      color: colors.onSurfaceVariant,
    );
    final allowMotion = !MediaQuery.disableAnimationsOf(context);
    final showProgress = running && allowMotion && !failed;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 16,
              child: showProgress
                  ? Padding(
                      padding: const EdgeInsets.all(2),
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: colors.primary,
                      ),
                    )
                  : Icon(
                      failed ? Icons.error_outline_rounded : icon,
                      size: 16,
                      color: failed ? colors.error : colors.onSurfaceVariant,
                    ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 2,
                    children: [
                      Text(title, style: label),
                      if (status case final message?)
                        Text(
                          message,
                          style: supporting.copyWith(
                            color: failed ? colors.error : null,
                          ),
                        ),
                    ],
                  ),
                  if (subject case final text?)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: supporting,
                      ),
                    ),
                ],
              ),
            ),
            if (onToggle != null) ...[
              const SizedBox(width: 4),
              Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                color: colors.onSurfaceVariant,
                size: 16,
              ),
            ],
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onToggle == null)
          content
        else
          Semantics(
            button: true,
            expanded: expanded,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onToggle,
              child: content,
            ),
          ),
        ?body,
      ],
    );
  }
}

class _ActivityInset extends StatelessWidget {
  const _ActivityInset({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsetsDirectional.only(start: 7, bottom: 8),
    padding: const EdgeInsetsDirectional.only(start: 16, bottom: 2),
    decoration: BoxDecoration(
      border: BorderDirectional(
        start: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: child,
  );
}

typedef _SavedToolResult = Future<String?> Function({required bool retry});

class _ActivityStep extends StatefulWidget {
  const _ActivityStep({
    super.key,
    required this.row,
    required this.expansion,
    this.readResult,
  });
  final ChatRow row;
  final ActivityExpansion expansion;
  final _SavedToolResult? readResult;

  @override
  State<_ActivityStep> createState() => _ActivityStepState();
}

class _ActivityStepState extends State<_ActivityStep> {
  bool localExpansion = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final expanded = widget.expansion.step(row) ?? localExpansion;
    final title = _action(row);
    final hasDetails =
        row.arguments.isNotEmpty ||
        row.inlineDiff.isNotEmpty ||
        row.body.isNotEmpty ||
        title == '工具调用' ||
        widget.readResult != null;
    return _ActivityDisclosure(
      title: context.tr(title),
      icon: _kindIcon[_kind(row)]!,
      subject: _subject(row),
      running: row.running,
      failed: row.failed,
      status: row.failed
          ? context.tr('失败')
          : row.running
          ? context.tr('运行中')
          : null,
      expanded: expanded,
      onToggle: hasDetails
          ? () => setState(() {
              localExpansion = !expanded;
              widget.expansion.rememberStep(row, !expanded);
            })
          : null,
      body: expanded
          ? _ActivityInset(
              child: _ActivityDetails(row: row, readResult: widget.readResult),
            )
          : null,
    );
  }
}

class _ActivityDetails extends StatefulWidget {
  const _ActivityDetails({required this.row, this.readResult});
  final ChatRow row;
  final _SavedToolResult? readResult;

  @override
  State<_ActivityDetails> createState() => _ActivityDetailsState();
}

class _ActivityDetailsState extends State<_ActivityDetails> {
  String _visible(String text, {required bool reasoning}) {
    const limit = 24000;
    if (reasoning || text.length <= limit) return text;
    final next = text.codeUnitAt(limit);
    final bound = next >= 0xdc00 && next <= 0xdfff ? limit - 1 : limit;
    return '${text.substring(0, bound)}\n…';
  }

  Widget section(
    BuildContext context,
    String? label,
    String raw, {
    String? display,
    String? badge,
  }) {
    final theme = Theme.of(context);
    final body = SelectableText(
      _visible(display ?? raw, reasoning: label == null),
      style: theme.textTheme.bodySmall
          ?.merge(label == null ? null : CustomThemeTokens.codeStyle(context))
          .copyWith(height: 1.5),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: label == null
          ? body
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.tr(label),
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                    if (badge != null)
                      Text(badge, style: theme.textTheme.labelSmall),
                    IconButton(
                      tooltip: context.tr('复制完整内容'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => copyMobileText(context, raw, '已复制内容'),
                      icon: const Icon(Icons.copy_outlined, size: 16),
                    ),
                  ],
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 208),
                  child: SingleChildScrollView(primary: false, child: body),
                ),
              ],
            ),
    );
  }

  Widget resultSection(BuildContext context, String body) {
    final row = widget.row;
    if (row.activity == '思考') return section(context, null, body);
    final command = _kind(row) == _ActivityKind.command
        ? activityJson(body)
        : null;
    final out = command?['output'] ?? command?['stdout'];
    final err = command?['stderr'];
    final display = [
      if (out is String && out.isNotEmpty) out,
      if (err is String && err.isNotEmpty) '${context.tr('标准错误')}\n$err',
    ];
    final exit = command?['exit_code'];
    return section(
      context,
      '结果',
      body,
      display: display.isEmpty ? null : display.join('\n\n'),
      badge: exit is int
          ? context.strings.format('退出码 {value}', {'value': exit})
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final reader = widget.readResult;
    final args = _kind(row) == _ActivityKind.command
        ? activityJson(row.arguments)
        : null;
    final command = args?['command'] ?? args?['code'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(5, 4, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_action(row) == '工具调用' && row.activity != null)
            section(context, '工具', row.activity!),
          if (row.arguments.isNotEmpty)
            section(
              context,
              '参数',
              row.arguments,
              display: command is String ? command : null,
            ),
          if (row.inlineDiff.isNotEmpty)
            section(context, '变更', row.inlineDiff),
          if (row.body.isNotEmpty)
            resultSection(context, row.body)
          else if (reader != null)
            FutureBuilder(
              future: reader(retry: false),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return Text(context.tr('正在读取工具结果…'));
                }
                if (snapshot.hasError) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.tr(snapshot.error.toString())),
                      TextButton(
                        onPressed: () => setState(() {
                          reader(retry: true);
                        }),
                        child: Text(context.tr('重试读取结果')),
                      ),
                    ],
                  );
                }
                final saved = snapshot.data;
                return saved == null
                    ? Text(context.tr('历史记录没有返回工具结果'))
                    : resultSection(context, saved);
              },
            ),
        ],
      ),
    );
  }
}
