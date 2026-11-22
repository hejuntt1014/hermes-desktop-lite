import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'gateway.dart';
import 'models.dart';

String? workspaceBranchName(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

class WorkspaceDefaults {
  WorkspaceDefaults(Gateway gateway, String profile)
    : _key =
          'hermes.mobile.workspace.v1.${base64Url.encode(utf8.encode(jsonEncode([gateway.base.toString(), profile])))}';

  static const _storage = FlutterSecureStorage();
  final String _key;

  Future<String?> read() => _storage.read(key: _key);

  Future<void> write(String? path) => path == null
      ? _storage.delete(key: _key)
      : _storage.write(key: _key, value: path);
}

String? parentWorkspacePath(String path) {
  final value = path.trim();
  if (value.isEmpty || value == '~') return null;
  final windows = RegExp(r'^[A-Za-z]:[/\\]|^\\\\').hasMatch(value);
  final normalized = windows ? value.replaceAll('\\', '/') : value;
  final root = windows
      ? RegExp(r'^(?:[A-Za-z]:/|//[^/]+/[^/]+/?)').stringMatch(normalized)
      : normalized.startsWith('/')
      ? '/'
      : normalized.startsWith('~/')
      ? '~/'
      : null;
  if (root == null) return null;
  final bare = normalized.replaceFirst(RegExp(r'/+$'), '');
  final bareRoot = root.replaceFirst(RegExp(r'/+$'), '');
  if (bare.length <= bareRoot.length) return null;
  final end = bare.lastIndexOf('/');
  if (end < 0) return null;
  final parent = end < root.length ? root : bare.substring(0, end);
  return windows && value.contains('\\')
      ? parent.replaceAll('/', '\\')
      : parent;
}

class WorkspaceDirectoryChange {
  const WorkspaceDirectoryChange(
    this.gateway,
    this.profile,
    this.stored,
    this.runtime,
  );
  final Gateway gateway;
  final String profile, stored, runtime;

  Future<ModelVersion> _baseline() async {
    final snap = await gateway.mutationSnapshot(stored, profile);
    if (snap == null) throw GatewayError('网关未提供会话版本');
    return (
      revision: snap['runtime_revision'] as int,
      generation: snap['runtime_generation'] as int,
    );
  }

  Future<({String path, String? branch, ModelVersion? version})> change(
    String path, {
    ModelVersion? baseline,
    bool Function()? stillAttached,
  }) async {
    if (path.trim().isEmpty) throw GatewayError('请选择工作目录');
    void checkAttachment() {
      if (stillAttached?.call() == false) throw GatewayDisconnected();
    }

    checkAttachment();
    final Json result;
    ModelVersion? version;
    if (gateway.canonical) {
      final requestId = const Uuid().v4();
      Future<Json> submit(ModelVersion current) {
        checkAttachment();
        return gateway.call('session.mutate', {
          'profile': profile,
          'session_id': stored,
          'operation': 'workspace',
          'request_id': requestId,
          'expected_revision': current.revision,
          'expected_generation': current.generation,
          'payload': {'cwd': path},
        });
      }

      version = baseline ?? await _baseline();
      Json reply;
      try {
        reply = await submit(version);
      } on GatewayError catch (error) {
        final reason = error.data?['reason'] ?? error.message;
        if (reason != 'revision_conflict' && reason != 'stale_generation') {
          rethrow;
        }
        checkAttachment();
        version = modelVersion(error.data) ?? await _baseline();
        reply = await submit(version);
      }
      result = reply;
      version = modelVersion(reply) ?? version;
    } else {
      result = await gateway.call('session.cwd.set', {
        'profile': profile,
        'session_id': runtime,
        'cwd': path,
      });
    }
    checkAttachment();
    final selected = result['cwd'];
    if (selected is! String || selected.trim().isEmpty) {
      throw GatewayError('网关未确认新的工作目录');
    }
    return (
      path: selected,
      branch: workspaceBranchName(result['branch']),
      version: version,
    );
  }
}
