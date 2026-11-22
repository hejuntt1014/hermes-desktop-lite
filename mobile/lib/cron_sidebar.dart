part of 'cron_page.dart';

class CronSidebar extends StatefulWidget {
  const CronSidebar({
    super.key,
    required this.gateway,
    required this.profile,
    required this.visible,
    required this.expanded,
    required this.onToggle,
    required this.onOpen,
  });

  final Gateway gateway;
  final String profile;
  final bool visible, expanded;
  final VoidCallback? onToggle;
  final ValueChanged<String?>? onOpen;

  @override
  State<CronSidebar> createState() => _CronSidebarState();
}

class _CronSidebarState extends State<CronSidebar> with WidgetsBindingObserver {
  late StreamSubscription<Json> _events;
  Timer? _poll;
  List<Json>? _jobs;
  bool _failed = false, _reading = false, _readAgain = false;
  bool _routeCurrent = false;
  AppLifecycleState? _lifecycle;
  int _request = 0;

  bool get _shouldWatch =>
      widget.visible &&
      widget.expanded &&
      widget.profile.isNotEmpty &&
      _routeCurrent &&
      (_lifecycle == null || _lifecycle == AppLifecycleState.resumed);

  @override
  void initState() {
    super.initState();
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    _subscribe();
  }

  void _subscribe() {
    _events = widget.gateway.events.listen((event) {
      if (!mounted || !_shouldWatch) return;
      if (event['type'] == 'client.connection') {
        if (widget.gateway.usable) {
          unawaited(_refresh(followUp: true));
        } else {
          setState(() {});
        }
      } else if (_cronChanged(event, widget.profile)) {
        unawaited(_refresh(followUp: true));
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.isCurrentOf(context) != false;
    _sync();
  }

  @override
  void didUpdateWidget(covariant CronSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.profile != widget.profile) {
      _stop();
      _jobs = null;
      _failed = false;
    }
    if (oldWidget.gateway != widget.gateway) {
      unawaited(_events.cancel());
      _subscribe();
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _sync();
  }

  void _sync() {
    if (!_shouldWatch) {
      _stop();
    } else if (_poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
      unawaited(_refresh());
    }
  }

  void _stop() {
    _poll?.cancel();
    _poll = null;
    _request++;
    _reading = false;
    _readAgain = false;
  }

  Future<void> _refresh({bool followUp = false}) async {
    if (!_shouldWatch || !widget.gateway.usable || widget.gateway.closed) {
      return;
    }
    if (_reading) {
      _readAgain |= followUp;
      return;
    }
    final id = ++_request;
    setState(() => _reading = true);
    final result = await _readCron(
      () => _readJobs(widget.gateway, widget.profile),
    );
    if (!mounted || id != _request) return;
    final again = _readAgain;
    setState(() {
      _reading = false;
      _readAgain = false;
      _failed = result.error != null;
      if (result.value case final rows?) _jobs = rows;
    });
    if (again) unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    unawaited(_events.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _cronTriggers(widget.gateway),
    builder: (context, _) => buildSidebar(context),
  );

  Widget buildSidebar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = context.tr('定时任务');
    final jobs = _jobs;
    final now = DateTime.now();
    final status = !widget.gateway.usable
        ? '已断开'
        : _failed
        ? '定时任务读取失败'
        : jobs == null
        ? '正在读取定时任务…'
        : jobs.isEmpty
        ? '暂无定时任务'
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  expanded: widget.expanded,
                  child: ListTile(
                    minTileHeight: 44,
                    dense: true,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    minLeadingWidth: 19,
                    leading: Icon(
                      Icons.schedule_outlined,
                      size: 18,
                      color: colors.primary,
                    ),
                    title: Text(
                      title,
                      style: TextStyle(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    trailing: Icon(
                      widget.expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                    ),
                    onTap: widget.onToggle,
                  ),
                ),
              ),
              IconButton(
                tooltip: context.tr('管理定时任务'),
                onPressed: widget.onOpen == null
                    ? null
                    : () => widget.onOpen?.call(null),
                icon: const Icon(Icons.more_horiz_rounded, size: 20),
              ),
            ],
          ),
          if (widget.expanded) ...[
            if (status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.tr(status),
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (_failed && widget.gateway.usable)
                      TextButton(
                        onPressed: _reading ? null : _refresh,
                        child: Text(context.tr('重试')),
                      ),
                  ],
                ),
              ),
            if (jobs != null)
              for (final job in jobs.take(3))
                ListTile(
                  dense: true,
                  minTileHeight: 40,
                  minLeadingWidth: 8,
                  horizontalTitleGap: 8,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  leading: Icon(
                    Icons.circle,
                    size: 6,
                    color: switch (_stateText(job)) {
                      '执行异常' => colors.error,
                      '已暂停' || '已停用' || '已完成' => colors.outline,
                      _ => colors.primary,
                    },
                  ),
                  title: Text(
                    _jobTitle(job, title),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    _jobStatus(
                      context,
                      job,
                      now,
                      triggering: _cronTriggers(widget.gateway).value
                          .contains((widget.profile, job['id'] as String)),
                    ),
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                  onTap: widget.onOpen == null
                      ? null
                      : () => widget.onOpen?.call(job['id'] as String),
                ),
          ],
        ],
      ),
    );
  }
}
