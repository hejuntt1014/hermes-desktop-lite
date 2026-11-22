part of 'chat.dart';

/// Status rows that stack above the composer in the floating dock.
extension _ChatDock on _ChatPageState {
  List<Widget> dockNotices(ColorScheme colors) => [
    if (historyError case final message?)
      TextButton.icon(
        onPressed: canRetryRecentHistory ? retryRecentHistory : null,
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: Text(context.tr(message)),
      ),
    if (gatewayReady && (opening || hydrating || loadingRecentHistory))
      LinearProgressIndicator(
        minHeight: 2,
        semanticsLabel: context.tr(
          loadingRecentHistory ? '正在读取历史消息' : '正在恢复会话',
        ),
      ),
    if (!gatewayReady) connectionNotice(),
    if (error != null && gatewayReady) buildConversationError(error!, colors),
    if (rewrite case final Json plan)
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        child: Card(
          color: colors.surfaceContainerLow,
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan['phase'] == RewritePhase.submit.name
                      ? context.tr('替换消息待确认')
                      : context.tr('会话更新待确认'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  children: [
                    if ({'rewind', 'submit'}.contains(plan['phase']) ||
                        plan['phase'] == 'legacy' &&
                            plan['legacy_image_count'] == 0)
                      TextButton(
                        onPressed: idleForRewrite ? continueRewrite : null,
                        child: Text(context.tr('继续')),
                      ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              await Clipboard.setData(
                                ClipboardData(
                                  text: plan['text']?.toString() ?? '',
                                ),
                              );
                            },
                      child: Text(context.tr('复制内容')),
                    ),
                    TextButton(
                      onPressed: busy ? null : discardRewrite,
                      child: Text(context.tr('清除待发内容')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    if (pendingInteractions.isNotEmpty)
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 165),
        child: ListView(
          primary: false,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final item in pendingInteractions.values)
              InteractionCard(
                interaction: item,
                onOpen: () => showInteraction(item),
              ),
          ],
        ),
      ),
    if (running && taskSnapshot != null && taskSnapshot!.tasks.isNotEmpty)
      SessionTasks(snapshot: taskSnapshot!, running: running),
    if (unconfirmedSend case final pending?) unconfirmedNotice(pending),
    if (workActivity case final monitor?)
      SessionWorkSummary(
        key: ValueKey(monitor.service.session),
        monitor: monitor,
      ),
    followupPanel(),
    voiceStatus(),
    if ((widget.wake, widget.onWakeSettings) case (
      final listener?,
      final settings?,
    ))
      WakeIndicator(wake: listener, onSettings: settings),
    if (composerError case final message?)
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(context.tr(message), style: TextStyle(color: colors.error)),
      ),
  ];
}
