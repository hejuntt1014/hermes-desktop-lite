part of 'main.dart';

class _RecentSessionMetadata {
  Map<String, bool> unread = {};
  final unreadRows = ValueNotifier<List<Json>?>(null);
  Timer? scheduled;
  FileTransferControl? read;
  int? watchedConnection;
  bool dirty = false;

  void cancel() {
    scheduled?.cancel();
    scheduled = null;
    read?.cancel();
    read = null;
    dirty = false;
  }
}

extension _SessionMetadataSync on _SessionsPageState {
  bool _canRefreshMetadata(String owner) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        widget.gateway.usable &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        profiles.containsKey(owner) &&
        (profile == owner ||
            tabs.open.any(
              (tab) => tab.profile == owner && tab.session != null,
            ));
  }

  void refreshOpenProfileMetadata() {
    for (final owner in {
      profile,
      for (final tab in tabs.open)
        if (tab.session != null) tab.profile,
    }) {
      scheduleSessionMetadata(owner);
    }
  }

  int unreadConversationCount(String owner) {
    final status = sessionMetadata[owner];
    if (status == null) return 0;
    final busy = busyConversationIds(owner);
    return status.unread.entries
        .where((entry) => entry.value && !busy.contains(entry.key))
        .length;
  }

  Set<String> busyConversationIds(String owner) => {
    for (final entry in (liveTurns[owner] ?? {}).entries)
      if (entry.value != ConversationActivity.background) entry.key,
    for (final tab in tabs.open)
      if (tab.profile == owner && tabActivities.value.containsKey(tab.id))
        if (tab.session case final id?) id,
  };

  void scheduleSessionMetadata(String owner) {
    if (!_canRefreshMetadata(owner)) return;
    final status = sessionMetadata.putIfAbsent(
      owner,
      _RecentSessionMetadata.new,
    );
    if (status.read != null) {
      status.dirty = true;
      return;
    }
    status.scheduled ??= Timer(const Duration(milliseconds: 450), () {
      status.scheduled = null;
      unawaited(_refreshRecentMetadata(owner, status));
    });
  }

  Future<void> _refreshRecentMetadata(
    String owner,
    _RecentSessionMetadata status,
  ) async {
    if (!_canRefreshMetadata(owner)) return;
    final control = status.read = FileTransferControl();
    final gateway = widget.gateway;
    final connection = gateway.connectionRevision;
    bool current() =>
        _canRefreshMetadata(owner) &&
        identical(status.read, control) &&
        !status.dirty &&
        gateway.connectionRevision == connection;
    try {
      if (gateway.changeEvents && status.watchedConnection != connection) {
        status.watchedConnection = connection;
        // A profile-scoped RPC enrolls its store in the gateway's change watcher,
        // including when the restored tabs for that profile have not been mounted.
        try {
          await gateway.call('session.most_recent', {
            'profile': owner,
          }, timeout: const Duration(seconds: 5));
        } catch (_) {
          // REST is available on gateways that lack the scoped RPC.
        }
      }
      if (!identical(status.read, control)) return;
      final response = await gateway.readConversationPage(
        'api/sessions',
        query: {
          'profile': owner,
          'limit': '100',
          'min_messages': '1',
          'order': 'recent',
          'exclude_sources': hiddenSessionSources,
        },
        timeout: const Duration(seconds: 8),
        control: control,
      );
      if (!current()) return;
      final records = response['sessions'];
      final storage = response['storage'];
      if (records is! List || storage is Json && storage[owner] == 'corrupt') {
        return;
      }
      final summaries = <String, Json>{
        for (final row in records.whereType<Json>())
          if (row['profile'] == null || row['profile'] == owner)
            ?tabSessionId(row): row,
      };
      _applyRecentMetadata(owner, status, summaries, const {});
      final missing = {
        for (final tab in tabs.open)
          if (tab.profile == owner &&
              tab.session != null &&
              !summaries.containsKey(tab.session))
            tab.session!,
      };
      final exact = <String, Json>{};
      final ids = missing.toList();
      const parallelReads = 4;
      for (
        var index = 0;
        index < ids.length && current();
        index += parallelReads
      ) {
        final batch = ids.skip(index).take(parallelReads);
        final replies = await Future.wait([
          for (final id in batch)
            _readOpenMetadata(gateway, owner, id, control),
        ]);
        for (final row in replies.nonNulls) {
          exact[tabSessionId(row)!] = row;
        }
      }
      if (exact.isNotEmpty && current()) {
        _applyRecentMetadata(owner, status, summaries, exact);
      }
    } catch (_) {
      // A failed refresh leaves the last successful labels and unread count.
    } finally {
      if (identical(status.read, control)) {
        status.read = null;
        if (status.dirty) {
          status.dirty = false;
          scheduleSessionMetadata(owner);
        }
      }
    }
  }

  Future<Json?> _readOpenMetadata(
    Gateway gateway,
    String owner,
    String id,
    FileTransferControl control,
  ) async {
    final path = 'api/sessions/${Uri.encodeComponent(id)}';
    Future<Json> read(String resource) => gateway.readConversationPage(
      resource,
      query: {'profile': owner},
      timeout: const Duration(seconds: 8),
      control: control,
    );
    try {
      Json row;
      try {
        row = await read('$path/summary');
      } on GatewayError catch (error) {
        if (!{404, 405, 501}.contains(error.status)) rethrow;
        row = await read(path);
      }
      return tabSessionId(row) == id &&
              (row['profile'] == null || row['profile'] == owner)
          ? row
          : null;
    } catch (_) {
      // A missing or inaccessible record keeps its local tab and draft intact.
      return null;
    }
  }

  void _applyRecentMetadata(
    String owner,
    _RecentSessionMetadata status,
    Map<String, Json> summaries,
    Map<String, Json> exact,
  ) {
    final unread = {
      for (final entry in summaries.entries)
        entry.key:
            entry.value['unread'] == true &&
            _sessionFlag(entry.value['archived']) != true,
    };
    final unreadRows = [
      for (final entry in summaries.entries)
        if (unread[entry.key] == true) entry.value,
    ];
    final previousUnread = status.unreadRows.value;
    final unreadChanged =
        previousUnread == null ||
        previousUnread.length != unreadRows.length ||
        unreadRows.indexed.any((item) {
          final before = previousUnread[item.$1];
          final after = item.$2;
          return tabSessionId(before) != tabSessionId(after) ||
              sessionTitle(before) != sessionTitle(after) ||
              sessionTime(before) != sessionTime(after) ||
              before['pinned'] != after['pinned'];
        });
    final updates = <String, Json>{};
    for (final entry in {...summaries, ...exact}.entries) {
      final row = entry.value;
      final archived = _sessionFlag(row['archived']);
      final pinned = _sessionFlag(row['pinned']);
      final isUnread = archived == true ? false : _sessionUnread(row);
      updates[entry.key] = {
        if (isUnread != null) 'unread': isUnread,
        if (row['title'] case final String name) 'title': name,
        if (row.containsKey('title') &&
            row['title'] == null &&
            row['preview'] is String)
          'title': null,
        if (row['preview'] case final String preview) 'preview': preview,
        if (pinned != null) 'pinned': pinned,
        if (archived != null) 'archived': archived,
      };
    }

    Json updateRow(Json row) {
      final changes = updates[tabSessionId(row)];
      if (changes == null ||
          changes.entries.every((item) => row[item.key] == item.value)) {
        return row;
      }
      return {...row, ...changes};
    }

    final patches = <ChatTab, Json>{};
    for (final tab in [...tabs.open, ...tabs.closed]) {
      if (tab.profile != owner || tab.row == null) continue;
      final next = updateRow(tab.row!);
      if (!identical(next, tab.row)) patches[tab] = next;
    }
    final nextRows = owner == profile
        ? rows
              .map(updateRow)
              .where((row) => (row['archived'] == true) == archived)
              .toList()
        : rows;
    final nextRecent = owner == profile
        ? recent.map(updateRow).where((row) => row['archived'] != true).toList()
        : recent;
    final changedList =
        owner == profile &&
        (rows.length != nextRows.length ||
            recent.length != nextRecent.length ||
            rows.indexed.any(
              (item) => !identical(item.$2, nextRows[item.$1]),
            ) ||
            recent.indexed.any(
              (item) => !identical(item.$2, nextRecent[item.$1]),
            ));
    if (!changedList &&
        !unreadChanged &&
        patches.isEmpty &&
        mapEquals(unread, status.unread)) {
      return;
    }
    commitSessionMetadata(() {
      status.unread = unread;
      if (owner == profile &&
          query.isEmpty &&
          !loading &&
          nextRows.length < rows.length) {
        nextOffset = (nextOffset - (rows.length - nextRows.length)).clamp(
          0,
          nextOffset,
        );
      }
      rows = nextRows;
      recent = nextRecent;
      for (final entry in patches.entries) {
        entry.key.row = entry.value;
      }
    }, persistTabs: patches.isNotEmpty);
    if (unreadChanged) status.unreadRows.value = unreadRows;
  }
}

bool? _sessionFlag(Object? value) => switch (value) {
  bool flag => flag,
  0 => false,
  1 => true,
  _ => null,
};

bool? _sessionUnread(Json row) {
  if (_sessionFlag(row['unread']) case final flag?) return flag;
  // Older gateways return the full row for an exact lookup. Only the explicit
  // unread watermark is useful without a server-computed activity timestamp.
  if (row['last_read_at'] == 0) return true;
  if (row.containsKey('last_read_at') && row['last_read_at'] == null)
    return false;
  return null;
}
