import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'mobile_themes.dart';
import 'mobile_clipboard.dart';
import 'gateway.dart' show Json;
import 'profile_soul_drafts.dart';
import 'profiles.dart';

class ProfileManager extends StatefulWidget {
  const ProfileManager({
    super.key,
    required this.service,
    required this.activeProfile,
  });
  final ProfileService service;
  final String activeProfile;
  @override
  State<ProfileManager> createState() => _ProfileManagerState();
}

class _ProfileManagerState extends State<ProfileManager> {
  late final StreamSubscription<Json> connectionEvents;
  List<GatewayProfile> roster = [];
  bool loading = true;
  String? error;
  String filter = '';
  String? selection;
  int revision = 0;
  bool separateDetailsOpen = false;

  @override
  void initState() {
    super.initState();
    connectionEvents = widget.service.gateway.events.listen((event) {
      final payload = event['payload'];
      if (mounted &&
          event['type'] == 'client.connection' &&
          payload is Json &&
          payload['resumed'] == true) {
        unawaited(load());
      }
    });
    load();
  }

  @override
  void dispose() {
    unawaited(connectionEvents.cancel());
    super.dispose();
  }

  Future<void> load() async {
    final request = ++revision;
    final link = widget.service.gateway.connectionRevision;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final entries = await widget.service.list();
      if (!mounted ||
          revision != request ||
          widget.service.gateway.connectionRevision != link) {
        return;
      }
      setState(() {
        roster = entries;
        if (!entries.any((entry) => entry.name == selection)) {
          selection =
              entries
                  .where((entry) => entry.name == widget.activeProfile)
                  .firstOrNull
                  ?.name ??
              entries.firstOrNull?.name;
        }
      });
    } catch (e) {
      if (mounted && revision == request) setState(() => error = e.toString());
    } finally {
      if (mounted && revision == request) setState(() => loading = false);
    }
  }

  Future<void> openDetails(
    GatewayProfile profile, {
    required bool inline,
  }) async {
    if (separateDetailsOpen) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      selection = profile.name;
      separateDetailsOpen = !inline;
    });
    if (inline) return;
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => _ProfileDetails(
            service: widget.service,
            profile: profile,
            onClone: () => create(from: profile),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => separateDetailsOpen = false);
    }
  }

  Future<void> create({GatewayProfile? from}) async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _CreateProfile(
          service: widget.service,
          roster: roster,
          cloneFrom: from?.name,
        ),
      ),
    );
    if (created == true && mounted) await load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('配置档案')),
        actions: [
          IconButton(
            tooltip: context.tr('刷新配置档案列表'),
            icon: const Icon(Icons.refresh_rounded),
            onPressed: loading ? null : load,
          ),
          IconButton(
            tooltip: context.tr('新建档案'),
            icon: const Icon(Icons.add_rounded),
            onPressed: loading ? null : () => create(),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, bounds) {
            final inline = bounds.maxWidth >= 680;
            final list = buildRoster(inline: inline);
            if (!inline) return list;
            final profile = roster
                .where((profile) => profile.name == selection)
                .firstOrNull;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: (bounds.maxWidth * .30).clamp(220, 310),
                  child: list,
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: profile == null || separateDetailsOpen
                      ? Center(
                          child: Text(
                            context.tr(loading ? '正在读取…' : '选择档案查看详情'),
                          ),
                        )
                      : _ProfileDetails(
                          key: ValueKey(profile.name),
                          service: widget.service,
                          profile: profile,
                          inline: true,
                          onClone: () => create(from: profile),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget buildRoster({required bool inline}) {
    final colors = Theme.of(context).colorScheme;
    final matches = roster
        .where(
          (p) => '${p.name} ${p.displayLabel(context.strings)}'
              .toLowerCase()
              .contains(filter),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 5, 16, 10),
          child: TextField(
            onChanged: (value) =>
                setState(() => filter = value.trim().toLowerCase()),
            decoration: InputDecoration(
              hintText: context.tr('搜索档案'),
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          ListTile(
            title: Text(
              context.tr(error!),
              style: TextStyle(color: colors.error),
            ),
            trailing: TextButton(
              onPressed: load,
              child: Text(context.tr('重试')),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: load,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              itemCount: !loading && matches.isEmpty ? 1 : matches.length,
              itemBuilder: (context, index) {
                if (matches.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        filter.isEmpty
                            ? context.tr('暂无配置档案')
                            : context.tr('没有匹配的档案'),
                      ),
                    ),
                  );
                }
                final profile = matches[index];
                final label = profile.displayLabel(context.strings);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    color:
                        profile.name ==
                            (inline ? selection : widget.activeProfile)
                        ? colors.secondaryContainer
                        : Colors.transparent,
                    child: ListTile(
                      leading: CircleAvatar(
                        radius: 17,
                        backgroundColor: colors.surfaceContainer,
                        foregroundColor: colors.onSurfaceVariant,
                        child: Text(
                          label.characters.firstOrNull?.toUpperCase() ?? '·',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      title: Text(
                        label,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        [
                          if (profile.name != profile.label) profile.name,
                          if (profile.model.isNotEmpty) profile.model,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: inline
                          ? null
                          : const Icon(Icons.chevron_right_rounded, size: 19),
                      selected: inline && profile.name == selection,
                      onTap: () => openDetails(profile, inline: inline),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileDetails extends StatefulWidget {
  const _ProfileDetails({
    super.key,
    required this.service,
    required this.profile,
    required this.onClone,
    this.inline = false,
  });
  final ProfileService service;
  final GatewayProfile profile;
  final VoidCallback onClone;
  final bool inline;
  @override
  State<_ProfileDetails> createState() => _ProfileDetailsState();
}

class _ProfileDetailsState extends State<_ProfileDetails> {
  final soul = TextEditingController();
  final find = TextEditingController();
  late final drafts = ProfileSoulDraftStore(
    widget.service.gateway,
    widget.profile.name,
  );
  late final AppLifecycleListener draftLifecycle;
  Timer? writeDraftTimer;
  SoulSnapshot? original;
  ProfileDocument document = ProfileDocument.soul;
  final memoryDocuments = <ProfileDocument, String>{};
  final memoryFilters = <ProfileDocument, String>{};
  String? get memo => memoryDocuments[document];
  String? error, draftIssue;
  bool loading = true, saving = false, conflict = false, restoringDraft = true;
  int revision = 0;

  bool get dirty => original != null && original!.content != soul.text;

  @override
  void initState() {
    super.initState();
    draftLifecycle = AppLifecycleListener(
      onInactive: flushDraft,
      onPause: flushDraft,
    );
    unawaited(restoreDraft());
  }

  Future<void> restoreDraft() async {
    ProfileSoulDraft? saved;
    try {
      saved = await drafts.read();
    } catch (_) {
      if (mounted) draftIssue = '无法读取本机草稿';
    }
    if (!mounted) return;
    final draft = saved;
    setState(() {
      restoringDraft = false;
      if (draft != null) {
        original = draft.baseline;
        soul.text = draft.text;
        conflict = draft.conflict;
        loading = false;
      }
    });
    if (draft == null) await loadDocument(ProfileDocument.soul);
  }

  void rememberDraft() {
    final baseline = original;
    if (baseline == null) return;
    drafts.stage(
      dirty ? (baseline: baseline, text: soul.text, conflict: conflict) : null,
    );
    writeDraftTimer?.cancel();
    writeDraftTimer = Timer(const Duration(milliseconds: 240), flushDraft);
  }

  Future<void> flushDraft() async {
    writeDraftTimer?.cancel();
    try {
      await drafts.flush();
      if (mounted && draftIssue == '无法保存本机草稿') {
        setState(() => draftIssue = null);
      }
    } catch (_) {
      if (mounted) setState(() => draftIssue = '无法保存本机草稿');
    }
  }

  @override
  void dispose() {
    draftLifecycle.dispose();
    unawaited(flushDraft());
    soul.dispose();
    find.dispose();
    super.dispose();
  }

  Future<void> loadDocument(
    ProfileDocument selected, {
    bool refresh = false,
  }) async {
    final serial = ++revision;
    final changing = selected != document;
    final cached =
        selected != ProfileDocument.soul &&
        memoryDocuments.containsKey(selected);
    setState(() {
      document = selected;
      loading = refresh || !cached;
      error = null;
      if (changing) find.text = memoryFilters[selected] ?? '';
    });
    if (cached && !refresh) return;
    try {
      if (selected == ProfileDocument.soul) {
        final value = await widget.service.soul(widget.profile.name);
        if (!mounted || serial != revision) return;
        setState(() {
          original = value;
          soul.text = value.content;
          conflict = false;
          rememberDraft();
        });
      } else {
        final value = await widget.service.memory(widget.profile, selected);
        if (!mounted || serial != revision) return;
        setState(() => memoryDocuments[selected] = value);
      }
    } catch (e) {
      if (mounted && serial == revision) setState(() => error = e.toString());
    } finally {
      if (mounted && serial == revision) setState(() => loading = false);
    }
  }

  void choose(ProfileDocument selected) {
    if (selected == document || saving || restoringDraft) return;
    if (selected == ProfileDocument.soul && original != null) {
      // Retain the user's editor buffer when they visit the adjacent memory tabs.
      revision++;
      setState(() {
        document = selected;
        loading = false;
        error = null;
      });
    } else {
      loadDocument(selected);
    }
  }

  Future<bool> allowDiscard() async {
    if (!dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(context.tr('放弃 SOUL.md 的改动？')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(context.tr('继续编辑')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(context.tr('放弃改动')),
              ),
            ],
          ),
        ) ==
        true;
  }

  Future<void> refresh() async {
    if (saving || document == ProfileDocument.soul && !await allowDiscard()) {
      return;
    }
    if (mounted) await loadDocument(document, refresh: true);
  }

  Future<void> save() async {
    final base = original;
    if (base == null || !dirty || loading || saving || conflict) return;
    final text = soul.text;
    final name = widget.profile.name;
    final submitted = drafts.draft;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final saved = await widget.service.saveSoul(name, base, text);
      if (!mounted) {
        if (submitted != null && identical(drafts.draft, submitted)) {
          drafts.stage(
            saved ? null : (baseline: base, text: text, conflict: true),
          );
          await flushDraft();
        }
        return;
      }
      setState(() {
        if (saved) {
          original = (content: text, exists: true);
        } else {
          conflict = true;
        }
        rememberDraft();
      });
      await flushDraft();
      if (saved && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('已保存 SOUL.md'))));
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> copy() async {
    final text = document == ProfileDocument.soul ? soul.text : memo;
    if (text == null) return;
    await copyMobileText(
      context,
      text,
      document == ProfileDocument.soul && dirty ? '已复制草稿' : '已复制原文',
    );
  }

  TextSpan? memoryPreview(String text, String query, ColorScheme colors) {
    if (query.isEmpty) return TextSpan(text: text);
    final pattern = RegExp(RegExp.escape(query), caseSensitive: false);
    final spans = <TextSpan>[];
    final highlight = TextStyle(
      color: colors.onTertiaryContainer,
      backgroundColor: colors.tertiaryContainer,
      fontWeight: FontWeight.w600,
    );
    for (final line in text.split('\n')) {
      final hits = pattern.allMatches(line).iterator;
      if (!hits.moveNext()) continue;
      if (spans.isNotEmpty) spans.add(const TextSpan(text: '\n'));
      var offset = 0;
      do {
        final match = hits.current;
        spans.add(TextSpan(text: line.substring(offset, match.start)));
        spans.add(TextSpan(text: match[0], style: highlight));
        offset = match.end;
      } while (hits.moveNext());
      spans.add(TextSpan(text: line.substring(offset)));
    }
    return spans.isEmpty ? null : TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final colors = Theme.of(context).colorScheme;
    final model = [
      profile.model,
      profile.provider,
    ].where((item) => item.isNotEmpty).join(' · ');
    final isSoul = document == ProfileDocument.soul;
    final memoryText = memo;
    final visible = memoryText == null
        ? null
        : memoryPreview(memoryText, find.text.trim(), colors);
    final toolbar = AppBar(
      primary: !widget.inline,
      automaticallyImplyLeading: !widget.inline,
      title: Text(profile.displayLabel(context.strings)),
      actions: [
        IconButton(
          tooltip: context.tr('克隆档案'),
          onPressed: saving ? null : widget.onClone,
          icon: const Icon(Icons.copy_all_outlined),
        ),
      ],
    );
    final body = SafeArea(
      top: false,
      child: ListView(
        key: PageStorageKey((profile.name, document)),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(16, 5, 16, 22),
        children: [
          Card(
            elevation: 0,
            color: colors.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.isEmpty ? context.tr('跟随网关默认模型') : model,
                    style: TextStyle(
                      color: colors.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (profile.isDefault) context.tr('默认档案'),
                      if (profile.skillCount case final count?)
                        context.strings.format('{count} 项技能', {'count': count}),
                      if (profile.hasEnv) context.tr('已配置环境变量'),
                    ].join(' · '),
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  if (profile.path.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: SelectableText(
                        profile.path,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<ProfileDocument>(
            segments: [
              for (final file in ProfileDocument.values)
                ButtonSegment(
                  value: file,
                  label: Text(
                    file.filename,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            selected: {document},
            showSelectedIcon: false,
            onSelectionChanged: saving || restoringDraft
                ? null
                : (values) => choose(values.first),
          ),
          if (loading || saving)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                context.tr(error!),
                style: TextStyle(color: colors.error),
              ),
            ),
          if (draftIssue case final issue? when isSoul)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                context.tr(issue),
                style: TextStyle(color: colors.error),
              ),
            ),
          if (isSoul && conflict)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr('远端 SOUL.md 已更新，当前编辑内容尚未保存。'),
                    style: TextStyle(color: colors.error),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: loading ? null : copy,
                        child: Text(context.tr('复制草稿')),
                      ),
                      TextButton(
                        onPressed: loading ? null : refresh,
                        child: Text(context.tr('载入远端版本')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          if (!isSoul || !conflict)
            Row(
              children: [
                if (!isSoul && visible != null)
                  Expanded(
                    child: TextField(
                      controller: find,
                      onChanged: (text) =>
                          setState(() => memoryFilters[document] = text),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: context.tr('查找记忆内容'),
                        prefixIcon: const Icon(Icons.search_rounded, size: 19),
                      ),
                    ),
                  )
                else
                  const Spacer(),
                IconButton(
                  tooltip: context.tr(isSoul && dirty ? '复制草稿' : '复制原文'),
                  onPressed:
                      loading ||
                          isSoul && original == null ||
                          !isSoul && memo == null
                      ? null
                      : copy,
                  icon: const Icon(Icons.content_copy_outlined, size: 18),
                ),
                IconButton(
                  tooltip: context.tr('重新读取'),
                  onPressed: loading || saving ? null : refresh,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
          if (isSoul && original != null) ...[
            TextField(
              controller: soul,
              onChanged: (_) => setState(rememberDraft),
              enabled: !saving && !loading,
              minLines: 5,
              maxLines: 16,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: original!.exists ? null : context.tr('输入档案的人格和行为指令'),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.end,
                children: [
                  if (dirty && !saving)
                    Text(
                      context.tr('有未保存的编辑'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  FilledButton(
                    onPressed: dirty && !loading && !saving && !conflict
                        ? save
                        : null,
                    child: Text(
                      saving ? context.tr('正在保存…') : context.tr('保存 SOUL.md'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (!isSoul && memoryText != null) ...[
            const SizedBox(height: 12),
            if (visible == null || memoryText.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  memoryText.isEmpty
                      ? context.tr('暂无记忆')
                      : context.tr('没有匹配的内容'),
                ),
              )
            else
              SelectableText.rich(
                visible,
                style: CustomThemeTokens.codeStyle(context).copyWith(height: 1.45),
              ),
          ],
        ],
      ),
    );
    return PopScope(
      canPop: !saving,
      child: widget.inline
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: toolbar.preferredSize.height, child: toolbar),
                Expanded(child: body),
              ],
            )
          : Scaffold(appBar: toolbar, body: body),
    );
  }
}

class _CreateProfile extends StatefulWidget {
  const _CreateProfile({
    required this.service,
    required this.roster,
    this.cloneFrom,
  });
  final ProfileService service;
  final List<GatewayProfile> roster;
  final String? cloneFrom;
  @override
  State<_CreateProfile> createState() => _CreateProfileState();
}

class _CreateProfileState extends State<_CreateProfile> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  late String source = widget.cloneFrom ?? '';
  bool saving = false;
  String? error;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (saving || !form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.service.create(
        name.text.trim(),
        cloneFrom: source.isEmpty ? null : source,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('新建配置档案'))),
      body: SafeArea(
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              TextFormField(
                controller: name,
                enabled: !saving,
                autocorrect: false,
                decoration: InputDecoration(labelText: context.tr('档案名称')),
                validator: (value) {
                  final candidate = value?.trim() ?? '';
                  if (!ProfileService.validName(candidate)) {
                    return context.tr('使用小写字母、数字、短横线或下划线，最多 64 个字符');
                  }
                  if (widget.roster.any((item) => item.name == candidate)) {
                    return context.tr('该档案名称已存在');
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: source,
                isExpanded: true,
                decoration: InputDecoration(labelText: context.tr('档案来源')),
                items: [
                  DropdownMenuItem(value: '', child: Text(context.tr('空白档案'))),
                  for (final choice in widget.roster)
                    DropdownMenuItem(
                      value: choice.name,
                      child: Text(
                        choice.displayLabel(context.strings),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: saving
                    ? null
                    : (value) {
                        if (value != null) setState(() => source = value);
                      },
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    context.tr(error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 19),
              FilledButton(
                onPressed: saving ? null : submit,
                child: Text(saving ? context.tr('正在创建…') : context.tr('创建档案')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
