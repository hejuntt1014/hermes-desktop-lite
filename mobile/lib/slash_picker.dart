import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'gateway.dart';
import 'slash_commands.dart';

Future<String?> pickSlashCommand(
  BuildContext context,
  SlashService service, {
  String initial = '',
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _SlashPicker(service: service, initial: initial),
);

class _SlashPicker extends StatefulWidget {
  const _SlashPicker({required this.service, required this.initial});
  final SlashService service;
  final String initial;

  @override
  State<_SlashPicker> createState() => _SlashPickerState();
}

class _SlashPickerState extends State<_SlashPicker> {
  late final field = TextEditingController(text: widget.initial);
  SlashCatalog catalog = SlashCatalog({});
  List<({String value, String hint})> completions = [];
  Timer? debounce;
  bool loading = true, failed = false;
  int lookup = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    debounce?.cancel();
    field.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final next = await widget.service.catalog();
      if (mounted) setState(() => catalog = next);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) {
        setState(() => loading = false);
        changed(field.text);
      }
    }
  }

  ({SlashCommand command, String arg})? get argumentQuery {
    final value = field.text.trimLeft();
    final parsed = parseSlashInput(value);
    final command = parsed == null ? null : catalog.entries[parsed.name];
    if (command == null ||
        command.options.isEmpty ||
        !RegExp(r'\s').hasMatch(value)) {
      return null;
    }
    return (command: command, arg: parsed!.arg);
  }

  void changed(String value) {
    debounce?.cancel();
    final round = ++lookup;
    setState(() => completions = []);
    final argument = argumentQuery;
    if (argument == null) return;
    debounce = Timer(const Duration(milliseconds: 115), () async {
      try {
        final reply = await widget.service.complete(value.trimLeft());
        if (!mounted || round != lookup) return;
        final items = reply['items'];
        if (items is! List) return;
        final results = <({String value, String hint})>[];
        for (final item in items.whereType<Json>()) {
          final option = item['text'];
          if (option is! String || !argument.command.options.contains(option)) {
            continue;
          }
          results.add((value: option, hint: item['meta'] as String? ?? ''));
        }
        setState(() => completions = results);
      } catch (_) {
        // The catalog already contains the supported argument list.
      }
    });
  }

  void pick(String text) => Navigator.pop(context, text);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final argument = argumentQuery;
    final options =
        argument?.command.options
            .where((value) => value.startsWith(argument.arg.toLowerCase()))
            .toList() ??
        const <String>[];
    final rows = argument == null
        ? catalog.search(field.text, translate: context.tr)
        : const <SlashCommand>[];
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final height = MediaQuery.sizeOf(context).height;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: (height * .70).clamp(
            0,
            (height - keyboard - 88).clamp(0, height),
          ),
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 1, 14, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              context.tr('命令与技能'),
                              style: TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: context.tr('关闭'),
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 9),
                      child: TextField(
                        controller: field,
                        onChanged: changed,
                        decoration: InputDecoration(
                          hintText: context.tr('搜索命令或技能'),
                          prefixIcon: Icon(Icons.search_rounded, size: 20),
                        ),
                      ),
                    ),
                    if (loading) const LinearProgressIndicator(minHeight: 2),
                    if (failed)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                context.tr('暂时无法获取网关命令'),
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: load,
                              child: Text(context.tr('重试')),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (!loading && rows.isEmpty && options.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      context.tr(argument == null ? '没有匹配的命令' : '没有匹配的选项'),
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                sliver: SliverList.builder(
                  itemCount: argument == null ? rows.length : options.length,
                  itemBuilder: (context, i) {
                    if (argument != null) {
                      final option = options[i];
                      final hint = completions
                          .where((entry) => entry.value == option)
                          .firstOrNull
                          ?.hint;
                      return ListTile(
                        leading: const Icon(Icons.tune_rounded, size: 18),
                        title: Text(option),
                        subtitle: hint?.isNotEmpty == true ? Text(hint!) : null,
                        onTap: () => pick('/${argument.command.name} $option'),
                      );
                    }
                    final command = rows[i];
                    final group = i == 0 || rows[i - 1].group != command.group;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (group)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 1),
                            child: Text(
                              context.tr(command.group),
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ListTile(
                          dense: true,
                          leading: Icon(
                            command.route == SlashRoute.extension
                                ? Icons.extension_outlined
                                : Icons.terminal_rounded,
                            size: 18,
                            color: colors.primary,
                          ),
                          title: Text(
                            '/${command.name}',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: command.hint.isEmpty
                              ? null
                              : Text(
                                  context.tr(command.hint),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onTap: () => pick(command.draft),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showSlashResult(
  BuildContext context,
  String command,
  String output,
) async {
  ModalRoute<void>? resultRoute;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) {
      resultRoute = ModalRoute.of<void>(sheet);
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheet).height * .70,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 12, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '/$command',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(sheet).textTheme.titleLarge,
                      ),
                    ),
                    if (output.isNotEmpty)
                      IconButton(
                        tooltip: context.tr('复制结果'),
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: output)),
                        icon: const Icon(Icons.copy_outlined, size: 18),
                      ),
                    IconButton(
                      tooltip: context.tr('关闭'),
                      onPressed: () => Navigator.pop(sheet),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(right: 10, bottom: 12),
                    child: SelectableText(
                      output.isEmpty ? context.tr('命令已完成') : output,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  await resultRoute?.completed;
}
