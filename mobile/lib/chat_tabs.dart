import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'gateway.dart';
import 'composer_attachments.dart';
import 'session_colors.dart';
import 'workspace.dart';

String? tabSessionId(Json? row) {
  final id = row?['id'] ?? row?['session_id'];
  return id is String && id.isNotEmpty ? id : null;
}

String? sessionTitle(Json? row) {
  for (final key in const ['title', 'preview']) {
    final value = row?[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

class ChatTab {
  ChatTab(
    this.profile, {
    this.row,
    String? id,
    this.draft = '',
    this.draftStamp,
    this.draftModel,
    this.attachments = const [],
    this.workspacePosition,
    this.reviewPosition,
  }) : id = id ?? const Uuid().v4();

  final String id, profile;
  Json? row, draftModel;
  String draft;
  String? draftStamp;
  List<ComposerAttachment> attachments;
  WorkspaceBrowserPosition? workspacePosition;
  WorkspaceReviewPosition? reviewPosition;
  Future<void>? attachmentWrite;

  String? get session => tabSessionId(row);
  String? get title => sessionTitle(row);

  Json toWire() => {
    'id': id,
    'profile': profile,
    if (session != null)
      'row': {
        'id': session,
        'title': ?title,
        'cwd': row?['cwd'],
        'pinned': row?['pinned'],
        'archived': row?['archived'],
        'unread': row?['unread'],
        '_lineage_root_id': row?['_lineage_root_id'] ?? row?['lineage_root'],
      },
    if (draft.isNotEmpty) 'draft': draft,
    if (draft.isNotEmpty && draftStamp != null) 'draft_stamp': draftStamp,
    if (session == null && draftModel?.isNotEmpty == true)
      'draft_model': draftModel,
    if (attachments.isNotEmpty)
      'draft_attachments': attachments.map((file) => file.toWire()).toList(),
    'workspace_position': ?workspacePosition?.toWire(),
    'workspace_review': ?reviewPosition?.toWire(),
  };

  static ChatTab? fromWire(Json wire) {
    final id = wire['id'];
    final owner = wire['profile'];
    if (id is! String || id.isEmpty || owner is! String || owner.isEmpty) {
      return null;
    }
    final savedDraft = wire['draft'];
    final savedFiles = wire['draft_attachments'];
    return ChatTab(
      owner,
      id: id,
      row: wire['row'] is Json && tabSessionId(wire['row'] as Json) != null
          ? wire['row'] as Json
          : null,
      draft: savedDraft is String ? savedDraft : '',
      draftStamp: wire['draft_stamp'] is String
          ? wire['draft_stamp'] as String
          : null,
      draftModel: wire['draft_model'] is Json
          ? wire['draft_model'] as Json
          : null,
      workspacePosition: WorkspaceBrowserPosition.fromWire(
        wire['workspace_position'],
      ),
      reviewPosition: WorkspaceReviewPosition.fromWire(
        wire['workspace_review'],
      ),
      attachments: savedFiles is List
          ? savedFiles
                .whereType<Json>()
                .map(ComposerAttachment.fromWire)
                .nonNulls
                .toList()
          : const [],
    );
  }
}

enum TabCloseScope { current, others, right, all }

class ChatTabs {
  final List<ChatTab> open = [];
  final List<ChatTab> closed = [];
  final pinOrder = <String, List<String>>{};
  final _sessionColors = <String, Map<String, SessionTitleColor>>{};
  final _lastProfileTabs = <String, String>{};
  String? _activeId;
  bool cronExpanded = false;
  bool wakeEnabled = false;

  String? get activeId => _activeId;

  set activeId(String? value) {
    _activeId = value;
    final tab = value == null ? null : find(value);
    if (tab != null) {
      _lastProfileTabs[tab.profile] = tab.id;
    }
  }

  ChatTab? get active => open.where((tab) => tab.id == activeId).firstOrNull;
  ChatTab? find(String id) => open.where((tab) => tab.id == id).firstOrNull;

  ChatTab? preferredOpen(String profile) {
    final last = _lastProfileTabs[profile];
    final preferred = last == null ? null : find(last);
    if (preferred?.profile == profile) return preferred;
    return open.reversed.where((tab) => tab.profile == profile).firstOrNull;
  }

  ChatTab emptyDraft(String profile) =>
      open
          .where(
            (tab) =>
                tab.profile == profile &&
                tab.session == null &&
                tab.draft.isEmpty &&
                tab.attachments.isEmpty &&
                tab.draftModel?.isNotEmpty != true,
          )
          .firstOrNull ??
      activate(profile, null);

  SessionTitleColor? titleColor(
    String profile,
    String session,
    String lineage,
  ) {
    final scoped = _sessionColors[profile];
    return scoped?[lineage] ?? scoped?[session];
  }

  void setTitleColor(
    String profile,
    String session,
    String lineage,
    SessionTitleColor? color,
  ) {
    final scoped = _sessionColors[profile] ?? <String, SessionTitleColor>{};
    scoped.remove(session);
    if (color == null) {
      scoped.remove(lineage);
    } else {
      scoped[lineage] = color;
    }
    if (scoped.isEmpty) {
      _sessionColors.remove(profile);
    } else {
      _sessionColors[profile] = scoped;
    }
  }

  ChatTab activate(String profile, Json? row) {
    final session = tabSessionId(row);
    var tab = session == null
        ? null
        : open
              .where(
                (item) => item.profile == profile && item.session == session,
              )
              .firstOrNull;
    if (tab == null) {
      final saved = session == null
          ? -1
          : closed.indexWhere(
              (item) => item.profile == profile && item.session == session,
            );
      tab = saved < 0 ? ChatTab(profile, row: row) : closed.removeAt(saved);
      open.add(tab);
    }
    if (row != null) {
      tab.row = {...?tab.row, ...row};
    }
    activeId = tab.id;
    return tab;
  }

  bool move(String id, String target) {
    final from = open.indexWhere((tab) => tab.id == id);
    final to = open.indexWhere((tab) => tab.id == target);
    if (from < 0 || to < 0 || from == to) return false;
    open.insert(to, open.removeAt(from));
    return true;
  }

  void _rememberClosed(ChatTab tab) {
    if (tab.session != null ||
        tab.draft.isNotEmpty ||
        tab.attachments.isNotEmpty ||
        tab.draftModel?.isNotEmpty == true) {
      closed.removeWhere(
        (item) =>
            item.id == tab.id ||
            tab.session != null &&
                item.session == tab.session &&
                item.profile == tab.profile,
      );
      closed.insert(0, tab);
    }
  }

  void close(String id) {
    closeGroup(id, TabCloseScope.current, visible: open);
  }

  List<ChatTab> closingGroup(
    String anchor,
    TabCloseScope scope, {
    required List<ChatTab> visible,
  }) {
    final index = visible.indexWhere((tab) => tab.id == anchor);
    if (index < 0) return [];
    return [
      for (final (position, tab) in visible.indexed)
        if (switch (scope) {
          TabCloseScope.current => position == index,
          TabCloseScope.others => position != index,
          TabCloseScope.right => position > index,
          TabCloseScope.all => true,
        })
          tab,
    ];
  }

  Set<String> closeGroup(
    String anchor,
    TabCloseScope scope, {
    required List<ChatTab> visible,
  }) {
    final closing = closingGroup(anchor, scope, visible: visible);
    if (closing.isEmpty) return {};
    final index = visible.indexWhere((tab) => tab.id == anchor);
    final removed = closing.map((tab) => tab.id).toSet();
    final active = this.active;
    for (final tab in closing) {
      if (tab.id != activeId) _rememberClosed(tab);
    }
    if (active != null && removed.contains(active.id)) {
      _rememberClosed(active);
      final remaining = visible
          .where((tab) => !removed.contains(tab.id))
          .toList();
      activeId = remaining.isEmpty
          ? null
          : remaining[index.clamp(0, remaining.length - 1)].id;
    }
    open.removeWhere((tab) => removed.contains(tab.id));
    _lastProfileTabs.removeWhere((_, tab) => removed.contains(tab));
    return removed;
  }

  ChatTab? reopen(Set<String> available) {
    final index = closed.indexWhere((tab) => available.contains(tab.profile));
    if (index < 0) return null;
    final previous = closed.removeAt(index);
    final duplicate = previous.session == null
        ? null
        : open
              .where(
                (item) =>
                    item.profile == previous.profile &&
                    item.session == previous.session,
              )
              .firstOrNull;
    final tab = duplicate ?? previous;
    if (duplicate == null) open.add(tab);
    activeId = tab.id;
    return tab;
  }

  void dropSession(String profile, String session) {
    final removed = open
        .where((tab) => tab.profile == profile && tab.session == session)
        .map((tab) => tab.id)
        .toList();
    for (final id in removed) {
      close(id);
    }
    closed.removeWhere(
      (tab) => tab.profile == profile && tab.session == session,
    );
  }

  Json toWire() => {
    'open': open.map((tab) => tab.toWire()).toList(),
    'closed': closed.map((tab) => tab.toWire()).toList(),
    'active': activeId,
    if (_lastProfileTabs.isNotEmpty) 'last_profile_tabs': _lastProfileTabs,
    if (cronExpanded) 'cron_expanded': true,
    if (wakeEnabled) 'wake_enabled': true,
    if (pinOrder.isNotEmpty) 'pins': pinOrder,
    if (_sessionColors.isNotEmpty)
      'session_title_colors': {
        for (final scope in _sessionColors.entries)
          scope.key: {
            for (final entry in scope.value.entries)
              entry.key: entry.value.name,
          },
      },
  };

  static ChatTabs fromWire(Json wire) {
    final tabs = ChatTabs();
    tabs.cronExpanded = wire['cron_expanded'] == true;
    tabs.wakeEnabled = wire['wake_enabled'] == true;
    Iterable<ChatTab> read(Object? value) => value is List
        ? value.whereType<Json>().map(ChatTab.fromWire).nonNulls
        : const [];
    tabs.open.addAll(read(wire['open']));
    tabs.closed.addAll(read(wire['closed']));
    if (wire['last_profile_tabs'] case final Json last) {
      for (final entry in last.entries) {
        if (entry.value case final String id
            when tabs.find(id)?.profile == entry.key) {
          tabs._lastProfileTabs[entry.key] = id;
        }
      }
    }
    if (wire['pins'] case final Json order) {
      for (final entry in order.entries) {
        if (entry.value case final List values) {
          tabs.pinOrder[entry.key] = values.whereType<String>().toList();
        }
      }
    }
    if (wire['session_title_colors'] case final Json colors) {
      for (final scope in colors.entries) {
        if (scope.value case final Json values) {
          final scoped = <String, SessionTitleColor>{
            for (final item in values.entries)
              item.key: ?SessionTitleColor.fromWire(item.value),
          };
          if (scoped.isNotEmpty) tabs._sessionColors[scope.key] = scoped;
        }
      }
    }
    final active = wire['active'];
    tabs.activeId = active is String ? active : null;
    return tabs;
  }
}

class ChatTabStore {
  ChatTabStore(Gateway gateway)
    : _key =
          'hermes.mobile.tabs.v1.${base64Url.encode(utf8.encode(gateway.base.toString()))}';

  static const _vault = FlutterSecureStorage();
  static final _pending = <String, Future<void>>{};
  final String _key;

  Future<ChatTabs> read() async {
    await _pending[_key];
    final raw = await _vault.read(key: _key);
    return raw == null
        ? ChatTabs()
        : ChatTabs.fromWire(jsonDecode(raw) as Json);
  }

  Future<void> write(ChatTabs current) {
    final encoded = jsonEncode(current.toWire());
    final next = (_pending[_key] ?? Future<void>.value()).then(
      (_) => _vault.write(key: _key, value: encoded),
    );
    final settled = next.then<void>((_) {}, onError: (Object _) {});
    _pending[_key] = settled;
    settled.whenComplete(() {
      if (identical(_pending[_key], settled)) _pending.remove(_key);
    });
    return next;
  }
}
