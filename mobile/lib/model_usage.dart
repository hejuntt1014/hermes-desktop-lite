import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'gateway.dart';
import 'models.dart';

typedef _UsageWindow = ({String? label, double used, DateTime? reset});
typedef _UsageAccount = ({
  String? label,
  int number,
  List<_UsageWindow> windows,
});

List<_UsageAccount> _codexAccounts(Json inventory) {
  final providers = inventory['providers'];
  if (providers is! List) return [];
  final usage = providers
      .whereType<Json>()
      .where((row) {
        final provider = row['slug'];
        return provider is String &&
            ModelCatalog.isCodex(provider) &&
            row['authenticated'] != false;
      })
      .map((row) => row['usage'])
      .whereType<Json>()
      .firstOrNull;
  if (usage == null) return [];
  final accounts = usage['accounts'];
  final rows = accounts is List && accounts.isNotEmpty
      ? accounts.whereType<Json>().toList()
      : [usage];
  return [
    for (final (index, row) in rows.indexed)
      (
        label: row['label'] is String && (row['label'] as String).isNotEmpty
            ? row['label'] as String
            : null,
        number: index + 1,
        windows: _windows(row['windows']),
      ),
  ].where((account) => account.windows.isNotEmpty).toList();
}

List<_UsageWindow> _windows(Object? value) {
  if (value is! List) return [];
  return [
    for (final row in value.whereType<Json>())
      if (row['used_percent'] case final num used when used.isFinite)
        (
          label: switch (row['label']) {
            'Session' => '会话额度',
            'Weekly' => '每周额度',
            final String label when label.trim().isNotEmpty => label,
            _ => null,
          },
          used: used.toDouble().clamp(0, 100),
          reset: DateTime.tryParse(row['resets_at']?.toString() ?? '')
              ?.toLocal(),
        ),
  ];
}

class CodexUsagePage extends StatefulWidget {
  const CodexUsagePage({
    super.key,
    required this.gateway,
    required this.profile,
  });

  final Gateway gateway;
  final String profile;

  @override
  State<CodexUsagePage> createState() => _CodexUsagePageState();
}

class _CodexUsagePageState extends State<CodexUsagePage> {
  late Future<List<_UsageAccount>> quota = read();

  Future<List<_UsageAccount>> read() async => _codexAccounts(
    await ModelCatalog.inventory(
      widget.gateway,
      widget.profile,
      refresh: false,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder(
      future: quota,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState != ConnectionState.done;
        final accounts = snapshot.data ?? const <_UsageAccount>[];
        return Scaffold(
          appBar: AppBar(
            title: Text(context.tr("Codex 订阅额度")),
            actions: [
              IconButton(
                tooltip: context.tr('刷新额度'),
                onPressed: loading
                    ? null
                    : () => setState(() => quota = read()),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                if (loading) const LinearProgressIndicator(minHeight: 2),
                if (snapshot.hasError)
                  ListTile(
                    leading: Icon(Icons.error_outline_rounded),
                    title: Text(context.tr('暂时无法读取额度')),
                  )
                else if (!loading && accounts.isEmpty)
                  ListTile(title: Text(context.tr('暂无可用额度数据'))),
                for (final account in accounts) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      account.label ??
                          context.strings.format('账户 {number}', {
                            'number': account.number,
                          }),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  for (final window in account.windows)
                    _QuotaWindow(window: window),
                  const Divider(),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _QuotaWindow extends StatelessWidget {
  const _QuotaWindow({required this.window});
  final _UsageWindow window;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = '${(100 - window.used).round()}%';
    final locale = MaterialLocalizations.of(context);
    final reset = window.reset;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            children: [
              Expanded(child: Text(context.tr(window.label ?? '订阅用量'))),
              Text(
                context.strings.format('剩余 {remaining}', {
                  "remaining": remaining,
                }),
                style: theme.textTheme.labelLarge,
              ),
            ],
          ),
          ExcludeSemantics(
            child: LinearProgressIndicator(
              value: window.used / 100,
              minHeight: 5,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          if (reset != null)
            Text(
              context.strings.format("{value} {value2} 重置", {
                "value": locale.formatShortDate(reset),
                "value2": locale.formatTimeOfDay(TimeOfDay.fromDateTime(reset)),
              }),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
