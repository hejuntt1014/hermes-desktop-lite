import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:record/record.dart';

import 'gateway.dart';

typedef WakeMatch = ({String? profile, bool newSession});

class MobileWake extends ChangeNotifier {
  MobileWake(this.gateway, this.onDetected) {
    _events = gateway.events.listen(_onEvent);
  }

  final Gateway gateway;
  final void Function(WakeMatch) onDetected;
  late final StreamSubscription<Json> _events;
  bool enabled = false;
  String? error;
  String? phrase;
  bool _foreground = false, _closed = false, _dirty = false;
  bool _explicit = false, _transfer = false, _requesting = false;
  bool askingPermission = false;
  int _voiceUsers = 0, _connection = 0;
  Future<void>? _sync;
  _WakeLease? _lease;
  _WakeAudio? _audio;

  bool get listening => _audio?.active == true;
  bool get starting => _requesting;
  bool get _wantsLease =>
      !_closed && enabled && _foreground && gateway.link == GatewayLink.online;
  bool get _wantsAudio =>
      _wantsLease && !_transfer && _voiceUsers == 0 && error == null;

  static const _client = {'surface': 'gui', 'client_capture': true};

  Future<Json> status() => _call('status', _client);

  void restore(bool value) {
    enabled = value;
    _refresh();
  }

  void setEnabled(bool value) {
    enabled = value;
    error = null;
    _explicit = value;
    _refresh();
  }

  void setForeground(bool value) {
    if (_foreground == value || _closed) return;
    _foreground = value;
    if (value && error == '网关未接收唤醒音频') error = null;
    _refresh();
  }

  Future<void> borrowMicrophone() {
    _voiceUsers++;
    return _refresh();
  }

  void returnMicrophone() {
    _voiceUsers--;
    if (!_closed) _refresh();
  }

  void finishTransfer() {
    _transfer = false;
    if (!_closed) _refresh();
  }

  void _onEvent(Json event) {
    if (_closed) return;
    if (event['type'] == 'client.connection') {
      _connection++;
      _lease = null;
      _audio?.discard();
      if (event['payload']?['state'] == 'online') error = null;
      _refresh();
    } else if (event['type'] == 'wake.detected' && _wantsAudio && listening) {
      final payload = event['payload'];
      if (payload is! Json) return;
      final profile = payload['profile'];
      _lease?.paused = true;
      _transfer = true;
      unawaited(
        _handoff((
          profile: profile is String && profile.isNotEmpty ? profile : null,
          newSession: payload['start_new_session'] != false,
        )),
      );
    }
  }

  Future<void> _handoff(WakeMatch match) async {
    await _refresh();
    if (_wantsLease && _transfer) {
      onDetected(match);
    } else {
      finishTransfer();
    }
  }

  Future<void> _refresh() {
    if (!_wantsAudio) _audio?.discard();
    _dirty = true;
    _changed();
    return _sync ??= _reconcile().whenComplete(() => _sync = null);
  }

  Future<void> _reconcile() async {
    while (_dirty) {
      _dirty = false;
      final connection = _connection;
      try {
        if (!_wantsAudio) {
          await _releaseAudio();
          await _yieldLease(connection);
          continue;
        }
        if (listening) continue;
        await _releaseAudio();
        _requesting = true;
        _changed();
        await _arm(connection);
      } catch (failure) {
        if (connection == _connection && _wantsAudio) {
          error = failure is GatewayError ? failure.message : '无法启动语音唤醒';
          _dirty = true;
        }
      } finally {
        _requesting = false;
        _changed();
      }
    }
  }

  Future<void> _arm(int connection) async {
    bool current() => connection == _connection && _wantsAudio;
    if (_lease == null) {
      final available = await status();
      if (!current()) return;
      if (available['available'] != true) throw GatewayError('网关语音唤醒不可用');
      if (available['capture'] != 'client') {
        throw GatewayError('网关需要启用客户端麦克风');
      }
    }
    final recorder = AudioRecorder();
    var retained = false;
    try {
      final bool permitted;
      askingPermission = _explicit;
      try {
        permitted = await recorder.hasPermission(request: askingPermission);
      } finally {
        askingPermission = false;
      }
      if (!permitted) {
        if (current()) throw GatewayError('请在系统设置中允许使用麦克风');
        return;
      }
      if (!current()) return;
      var lease = _lease;
      if (lease?.paused == true) {
        final resumed = await _call('resume', const {});
        if (connection != _connection) return;
        if (resumed['resumed'] == true) {
          lease!.paused = false;
        } else {
          _lease = lease = null;
        }
        if (!current()) return;
      }
      if (lease == null) {
        final firstGesture = _explicit;
        _explicit = false;
        final started = await _call('start', {
          ..._client,
          if (firstGesture) 'persist': true,
        });
        if (connection != _connection) return;
        if (started['started'] != true) throw _refusal(started['reason']);
        lease = _lease = _WakeLease();
        if (started['capture'] != 'client' ||
            started['sample_rate'] != 16000 ||
            started['frame_length'] is! int ||
            (started['frame_length'] as int) < 1 ||
            (started['frame_length'] as int) > 32000) {
          await _stopLease(connection);
          if (current()) throw GatewayError('网关返回了不支持的唤醒音频格式');
          return;
        }
        lease.samples = started['frame_length'] as int;
        phrase = started['phrase'] as String?;
        if (!current()) return;
      }
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      if (!current()) return;
      final audio = _audio = _WakeAudio(
        recorder,
        lease.samples * 2,
        (pcm) {
          return _call('feed', {
            'pcm_b64': base64Encode(pcm),
            'sample_rate': 16000,
          });
        },
        () {
          if (!current()) return;
          error = '网关未接收唤醒音频';
          _refresh();
        },
      );
      retained = true;
      audio.start(stream);
    } finally {
      if (!retained) await recorder.dispose();
    }
  }

  Future<void> _releaseAudio() async {
    final audio = _audio;
    _audio = null;
    await audio?.close();
  }

  Future<void> _yieldLease(int connection) async {
    final lease = _lease;
    if (lease == null || connection != _connection) return;
    if (!_wantsLease || error != null) {
      await _stopLease(connection);
    } else if (!lease.paused && !_wantsAudio) {
      final paused = await _call('pause', const {});
      if (identical(_lease, lease)) {
        if (paused['paused'] == true) {
          lease.paused = true;
        } else {
          _lease = null;
        }
      }
    }
  }

  Future<void> _stopLease(int connection) async {
    if (_lease == null || connection != _connection) return;
    _lease = null;
    if (gateway.link == GatewayLink.online) await _call('stop', const {});
  }

  Future<Json> _call(String method, Json params) async {
    try {
      return await gateway.call(
        'wake.$method',
        params,
        timeout: Duration(seconds: method == 'feed' ? 4 : 8),
      );
    } on GatewayError catch (failure) {
      if (failure.code == -32601) throw GatewayError('网关未提供语音唤醒');
      if (failure is GatewayDisconnected) rethrow;
      throw GatewayError('网关语音唤醒不可用');
    }
  }

  GatewayError _refusal(Object? reason) => GatewayError(switch (reason) {
    'owned' => '语音唤醒正在另一客户端使用',
    'disabled' || 'disabled_for_surface' => '网关未启用此前台的语音唤醒',
    _ => '网关语音唤醒不可用',
  });

  void _changed() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_events.cancel());
    unawaited(_refresh());
    super.dispose();
  }
}

class _WakeLease {
  bool paused = false;
  int samples = 0;
}

class _WakeAudio {
  _WakeAudio(this.recorder, int frameBytes, this.send, this.onFailure)
    : _frame = Uint8List(frameBytes);
  final AudioRecorder recorder;
  final Future<Json> Function(Uint8List) send;
  final void Function() onFailure;
  final Uint8List _frame;
  int _filled = 0, _rejected = 0;
  bool active = true, _sending = false;
  Uint8List? _latest;
  StreamSubscription<Uint8List>? _stream;
  StreamSubscription<RecordState>? _state;

  void start(Stream<Uint8List> stream) {
    _stream = stream.listen(
      _append,
      onError: (Object _) => _failed(),
      onDone: _failed,
    );
    _state = recorder.onStateChanged().listen((state) {
      if (state == RecordState.pause) _failed();
    });
  }

  void _append(Uint8List chunk) {
    var offset = 0;
    while (active && offset < chunk.length) {
      final size = (chunk.length - offset).clamp(0, _frame.length - _filled);
      _frame.setRange(_filled, _filled + size, chunk, offset);
      _filled += size;
      offset += size;
      if (_filled == _frame.length) {
        _filled = 0;
        _latest = Uint8List.fromList(_frame);
        if (!_sending) unawaited(_feed());
      }
    }
  }

  Future<void> _feed() async {
    _sending = true;
    try {
      while (active && _latest != null) {
        final pcm = _latest!;
        _latest = null;
        var accepted = false;
        try {
          accepted = (await send(pcm))['fed'] == true;
        } catch (_) {
          // A later audio frame can recover from a transient rejected request.
        }
        if (!active) return;
        _rejected = accepted ? 0 : _rejected + 1;
        if (_rejected >= 4) _failed();
      }
    } finally {
      _sending = false;
    }
  }

  void _failed() {
    if (!active) return;
    discard();
    onFailure();
  }

  void discard() {
    active = false;
    _latest = null;
  }

  Future<void> close() async {
    discard();
    try {
      await _stream?.cancel();
      await _state?.cancel();
    } finally {
      await recorder.dispose();
    }
  }
}
