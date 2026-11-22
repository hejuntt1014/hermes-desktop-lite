import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'gateway.dart';

const _approvalLabels = {
  'once': '允许一次',
  'session': '本会话允许',
  'always': '始终允许',
  'deny': '拒绝',
};

List<String> _choices(dynamic value) =>
    value is List ? value.whereType<String>().toList() : [];

typedef ClarifyDraft = ({
  String questions,
  Map<String, Set<String>> selected,
  Map<String, String> other,
  Json? gatewayAnswers,
});

class Interaction {
  const Interaction({
    required this.kind,
    required this.id,
    required this.payload,
    this.requestId,
    this.generation,
  });

  final String kind, id;
  final Json payload;
  final Object? requestId;
  final int? generation;

  bool get approval => kind == 'approval';
  String get key =>
      approval || requestId == null ? '$kind:$id' : 'request:$requestId';
  (String, int?) get clarification => (id, generation);
  String get questionSignature => jsonEncode([
    for (final question in questions)
      [question.id, question.text, question.choices, question.multi],
  ]);

  static Interaction? fromPrompt(String kind, Json payload, int? generation) {
    if (!{'approval', 'clarify'}.contains(kind)) return null;
    final promptId = payload['prompt_id'];
    final id = promptId ?? payload['request_id'];
    if (id is! String || id.isEmpty || promptId == null && kind != 'approval') {
      return null;
    }
    final version = payload['execution_generation'] ?? generation;
    if (promptId != null && version is! int) return null;
    return Interaction(
      kind: kind,
      id: id,
      payload: payload,
      generation: promptId != null ? version as int : null,
    );
  }

  static Interaction? fromRequest(Json frame) {
    final id = frame['id'];
    final kind = frame['method'];
    final payload = frame['params'];
    if ((id is! int && id is! String) ||
        !{'approval', 'clarify'}.contains(kind) ||
        payload is! Json) {
      return null;
    }
    return Interaction(
      kind: kind as String,
      id: (payload['request_id'] ?? id).toString(),
      requestId: id,
      payload: payload,
    );
  }

  String get title => approval ? '工具审批' : '需要你确认';
  String get detail {
    for (final field in ['command', 'question', 'description']) {
      final text = payload[field];
      if (text is String && text.trim().isNotEmpty) return text;
    }
    return '';
  }

  List<String> get approvals {
    final listed = _choices(payload['choices']);
    return (listed.isEmpty ? const ['once', 'deny'] : listed)
        .where(
          (choice) =>
              _approvalLabels.containsKey(choice) &&
              (choice != 'always' || payload['allow_permanent'] != false) &&
              (choice != 'session' || payload['allow_session'] != false),
        )
        .toSet()
        .toList();
  }

  List<({String id, String text, List<String> choices, bool multi})>
  get questions {
    final raw = payload['questions'];
    final items = raw is List
        ? [
            for (final row in raw.whereType<Json>())
              if (row['qid'] is String && row['question'] is String)
                (
                  id: row['qid'] as String,
                  text: row['question'] as String,
                  choices: _choices(row['choices']),
                  multi: row['multi_select'] == true,
                ),
          ]
        : <({String id, String text, List<String> choices, bool multi})>[];
    return items.isNotEmpty
        ? items
        : [
            (
              id: 'answer',
              text: detail,
              choices: _choices(payload['choices']),
              multi: payload['multi_select'] == true,
            ),
          ];
  }

  Future<void> answer(
    Gateway gateway,
    String runtime,
    String profile,
    Json result,
  ) async {
    if (requestId != null) {
      gateway.replyToInteraction(requestId!, result);
      return;
    }
    final answers = result['answers'];
    final params = <String, dynamic>{
      'session_id': runtime,
      'profile': profile,
      if (generation != null) ...{
        'prompt_id': id,
        'execution_generation': generation,
      } else
        'request_id': id,
      if (approval)
        'choice': result['choice']
      else
        'answer': answers is! Json
            ? ''
            : questions.length == 1
            ? answers[questions.first.id] ?? ''
            : jsonEncode(answers),
    };
    await gateway.call(
      '$kind.respond',
      params,
      timeout: const Duration(minutes: 5),
    );
  }
}

class InteractionCard extends StatelessWidget {
  const InteractionCard({
    super.key,
    required this.interaction,
    required this.onOpen,
  });
  final Interaction interaction;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final preview = interaction.approval
        ? interaction.detail
        : interaction.questions.first.text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        child: ListTile(
          dense: true,
          leading: Icon(
            interaction.approval ? Icons.shield_outlined : Icons.help_outline,
            size: 19,
          ),
          title: Text(context.tr(interaction.title)),
          subtitle: preview.isEmpty
              ? null
              : Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: onOpen,
        ),
      ),
    );
  }
}

class InteractionSheet extends StatefulWidget {
  const InteractionSheet({
    super.key,
    required this.interaction,
    this.draft,
    this.onDraft,
  });
  final Interaction interaction;
  final ClarifyDraft? draft;
  final ValueChanged<ClarifyDraft>? onDraft;
  @override
  State<InteractionSheet> createState() => _InteractionSheetState();
}

class _InteractionSheetState extends State<InteractionSheet> {
  final selected = <String, Set<String>>{};
  final other = <String, TextEditingController>{};
  late final questions = widget.interaction.questions;
  late final signature = widget.interaction.questionSignature;
  Json? get gatewayAnswers => switch (widget.interaction.payload['answers']) {
    final Json answers => answers,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    if (widget.interaction.approval) return;
    final remote = gatewayAnswers;
    final draft = widget.draft?.questions == signature ? widget.draft : null;
    for (final question in questions) {
      final saved = remote?[question.id];
      final field = other[question.id] = TextEditingController();
      if (draft != null &&
          (saved == null || saved == draft.gatewayAnswers?[question.id])) {
        selected[question.id] = {...?draft.selected[question.id]};
        field.text = draft.other[question.id] ?? '';
        continue;
      }
      if (saved is! String || saved.isEmpty) continue;
      var values = [saved];
      if (question.multi && saved.startsWith('[')) {
        try {
          final decoded = jsonDecode(saved);
          if (decoded is List) values = _choices(decoded);
        } on FormatException {
          /* Legacy answers can be plain text. */
        }
      }
      selected[question.id] = values.where(question.choices.contains).toSet();
      field.text = values
          .where((item) => !question.choices.contains(item))
          .join('\n');
    }
  }

  @override
  void dispose() {
    for (final field in other.values) {
      field.dispose();
    }
    super.dispose();
  }

  void rememberDraft() => widget.onDraft?.call((
    questions: signature,
    selected: {
      for (final entry in selected.entries) entry.key: {...entry.value},
    },
    other: {for (final entry in other.entries) entry.key: entry.value.text},
    gatewayAnswers: gatewayAnswers,
  ));

  void submit() {
    final answers = <String, String?>{};
    for (final question in questions) {
      final typed = other[question.id]!.text.trim();
      final checked = selected[question.id] ?? const <String>{};
      final values = [
        if (question.multi || typed.isEmpty)
          ...question.choices.where(checked.contains),
        if (typed.isNotEmpty) typed,
      ];
      answers[question.id] = values.isEmpty
          ? null
          : question.multi
          ? jsonEncode(values)
          : values.first;
    }
    Navigator.pop(context, {'outcome': 'submitted', 'answers': answers});
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.interaction;
    final canSubmit =
        other.values.any((field) => field.text.trim().isNotEmpty) ||
        selected.values.any((set) => set.isNotEmpty);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 6, 22, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr(prompt.title),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr(prompt.approval ? '关闭' : '稍后回答'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (prompt.approval) ...[
                SelectableText(prompt.detail),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final choice in prompt.approvals)
                      OutlinedButton(
                        onPressed: () =>
                            Navigator.pop(context, {'choice': choice}),
                        child: Text(context.tr(_approvalLabels[choice]!)),
                      ),
                  ],
                ),
              ] else ...[
                for (final question in questions) ...[
                  if (question.text.isNotEmpty)
                    Text(
                      question.text,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  const SizedBox(height: 8),
                  if (question.choices.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final choice in question.choices)
                          FilterChip(
                            label: Text(choice),
                            selected:
                                selected[question.id]?.contains(choice) == true,
                            onSelected: (checked) {
                              final values = selected.putIfAbsent(
                                question.id,
                                () => {},
                              );
                              setState(() {
                                if (!question.multi) values.clear();
                                if (checked) {
                                  values.add(choice);
                                  if (!question.multi) {
                                    other[question.id]!.clear();
                                  }
                                } else {
                                  values.remove(choice);
                                }
                              });
                              rememberDraft();
                            },
                          ),
                      ],
                    ),
                  TextFormField(
                    controller: other[question.id],
                    onChanged: (value) {
                      setState(() {
                        if (!question.multi && value.trim().isNotEmpty) {
                          selected.remove(question.id);
                        }
                      });
                      rememberDraft();
                    },
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      labelText: question.choices.isEmpty
                          ? context.tr('你的回答')
                          : context.tr('其他答案'),
                    ),
                  ),
                  const SizedBox(height: 13),
                ],
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(context, {'outcome': 'cancelled'}),
                      child: Text(context.tr('跳过')),
                    ),
                    FilledButton(
                      onPressed: canSubmit ? submit : null,
                      child: Text(context.tr('提交')),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
