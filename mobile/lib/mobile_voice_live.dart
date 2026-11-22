part of 'mobile_voice.dart';

class VoiceEngineStatus {
  const VoiceEngineStatus({
    this.supported = false,
    this.liveSelected = false,
    this.liveAvailable = false,
  });

  final bool supported, liveSelected, liveAvailable;

  static Future<VoiceEngineStatus> read(Gateway gateway, String profile) async {
    try {
      final result = await gateway.api(
        'api/audio/voice-live/status',
        query: {'profile': profile},
        timeout: const Duration(seconds: 6),
      );
      return VoiceEngineStatus(
        supported: result['ok'] == true,
        liveSelected: result['mode'] == 'gpt-live',
        liveAvailable: result['available'] == true,
      );
    } on GatewayError catch (error) {
      if ({404, 405, 501}.contains(error.status)) {
        return const VoiceEngineStatus();
      }
      rethrow;
    }
  }

  static Future<void> select(
    Gateway gateway,
    String profile, {
    required bool live,
  }) async {
    await gateway.call('config.set', {
      'profile': profile,
      'key': 'voice.voice_chat_mode',
      'value': live ? 'gpt-live' : 'chained',
    });
  }
}

typedef _LiveSubmit = Future<String?> Function(
  String text,
  bool interrupted,
  String? context,
);
typedef _LiveDelegate = ({String id, String prompt, String context});

extension _MobileLiveVoice on MobileVoice {
  /// Returns false when the call can start with the speech-to-text engine.
  Future<bool> _runLive(
    _VoiceCall call,
    List<Json> history,
    _LiveSubmit submit,
    Future<bool> Function() interrupt,
    String Function(String) spokenText,
    String delegationFailure,
  ) async {
    final transcript = _LiveTranscript();
    final delegations = _LiveDelegations(
      this,
      call,
      submit,
      interrupt,
      spokenText,
      delegationFailure,
    );
    var failures = 0;
    var everReady = false;
    while (!call.job.cancelled.isCompleted) {
      _setPhase(VoicePhase.opening);
      final attempt = _LivePeer(this, call, transcript, delegations);
      call.livePeer = attempt;
      final lifetime = Stopwatch()..start();
      try {
        await attempt.run([...history, ...transcript.seed()]);
        return true;
      } on _LiveStartUnavailable {
        if (!everReady && !attempt.ready) return false;
        rethrow;
      } on _LiveTransportLost catch (error) {
        everReady |= attempt.ready;
        if (lifetime.elapsed >= const Duration(minutes: 2)) failures = 0;
        if (++failures > 2) {
          if (!everReady) return false;
          throw GatewayError(error.message);
        }
      } finally {
        try {
          await attempt.close();
        } finally {
          call.livePeer = null;
        }
      }
      await call.job.untilCancelled(
        Future<void>.delayed(const Duration(milliseconds: 250)),
      );
    }
    return true;
  }
}

class _LiveStartUnavailable extends GatewayError {
  _LiveStartUnavailable(super.message, [super.status]);
}

class _LiveTransportLost implements Exception {
  const _LiveTransportLost(this.message);
  final String message;
}

class _LiveDelegations {
  _LiveDelegations(
    this.owner,
    this.call,
    this.submit,
    this.interrupt,
    this.spokenText,
    this.failureText,
  );

  final MobileVoice owner;
  final _VoiceCall call;
  final _LiveSubmit submit;
  final Future<bool> Function() interrupt;
  final String Function(String) spokenText;
  final String failureText;
  ({_LivePeer peer, _LiveDelegate work})? _queued;
  bool _delivering = false;
  Completer<void>? _ready;

  void peerReady() {
    _ready?.complete();
    _ready = null;
    owner._setPhase(_delivering ? VoicePhase.waiting : VoicePhase.listening);
  }

  void accept(_LivePeer peer, _LiveDelegate work) {
    _queued = (peer: peer, work: work);
    if (_delivering) {
      unawaited(interrupt());
    } else {
      unawaited(_deliver());
    }
  }

  Future<_LivePeer?> _waitForPeer() async {
    while (!call.job.cancelled.isCompleted) {
      final peer = call.livePeer;
      if (peer != null && peer.ready && peer._active) return peer;
      final ready = _ready ??= Completer<void>();
      await call.job.untilCancelled(ready.future);
    }
    return null;
  }

  Future<void> _deliver() async {
    _delivering = true;
    try {
      while (!call.job.cancelled.isCompleted && _queued != null) {
        final (:peer, :work) = _queued!;
        _queued = null;
        owner._setPhase(VoicePhase.waiting);
        String? reply;
        try {
          reply = await submit(work.prompt, false, work.context);
        } catch (_) {
          reply = failureText;
        }
        if (call.job.cancelled.isCompleted) return;
        if (reply == null) {
          call.job.cancel();
          return;
        }
        final chars = spokenText(reply)
            .replaceAll(RegExp(r'\s+'), ' ')
            .runes
            .take(12000)
            .toList();
        for (var offset = 0; offset < chars.length;) {
          final receiver = await _waitForPeer();
          if (receiver == null) return;
          // Delegation IDs belong to one realtime session. The new peer accepts
          // an unscoped commentary reply, as on desktop.
          final sent = await receiver._send({
            'type': 'session.commentary.append',
            'delegation_id': identical(receiver, peer) ? work.id : null,
            'content': String.fromCharCodes(chars.skip(offset).take(1500)),
          });
          if (sent) offset += 1500;
        }
      }
    } finally {
      _delivering = false;
      final peer = call.livePeer;
      if (peer != null && peer.ready && peer._active) {
        owner._setPhase(VoicePhase.listening);
      }
    }
  }
}

class _LivePeer {
  _LivePeer(this.owner, this.call, this.transcript, this.delegations);

  final MobileVoice owner;
  final _VoiceCall call;
  final _LiveTranscript transcript;
  final _LiveDelegations delegations;
  final _ended = Completer<Exception?>();
  final _gathered = Completer<void>();
  final _heard = <String>{};
  final _remoteTracks = <rtc.MediaStreamTrack>{};
  rtc.RTCPeerConnection? _peer;
  rtc.RTCDataChannel? _channel;
  rtc.MediaStream? _local;
  Timer? _starting, _reconnecting;
  bool _closed = false, _muted = false, ready = false;

  bool get _active =>
      !_closed && !_ended.isCompleted && !call.job.cancelled.isCompleted;

  Future<void> run(List<Json> history) async {
    final peer = _peer = await rtc.createPeerConnection({
      'iceServers': <Json>[],
    });
    if (!_active) return _throwEnd();
    peer.onConnectionState = _connectionChanged;
    peer.onIceGatheringState = (state) {
      if (state == rtc.RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !_gathered.isCompleted) {
        _gathered.complete();
      }
    };
    peer.onTrack = (event) {
      if (!_active || event.track.kind != 'audio') return;
      _remoteTracks.add(event.track);
      event.track.enabled = call.speaker;
    };
    final local = _local = await rtc.navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
    if (!_active) return _throwEnd();
    final tracks = local.getAudioTracks();
    if (tracks.isEmpty) throw GatewayError('无法打开麦克风');
    for (final track in tracks) {
      track.enabled = false;
      await peer.addTrack(track, local);
      if (!_active) return _throwEnd();
    }
    final channel = _channel = await peer.createDataChannel(
      'oai-events',
      rtc.RTCDataChannelInit(),
    );
    if (!_active) return _throwEnd();
    channel.onMessage = _message;
    channel.onDataChannelState = (state) {
      if (state == rtc.RTCDataChannelState.RTCDataChannelClosed) {
        _finish(const _LiveTransportLost('语音连接已断开'));
      }
    };
    await peer.setLocalDescription(await peer.createOffer());
    if (await peer.getIceGatheringState() ==
            rtc.RTCIceGatheringState.RTCIceGatheringStateComplete &&
        !_gathered.isCompleted) {
      _gathered.complete();
    }
    await call.job.untilCancelled(
      _gathered.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw const _LiveTransportLost('语音连接超时'),
      ),
    );
    if (!_active) return _throwEnd();
    final sdp = (await peer.getLocalDescription())?.sdp;
    if (sdp?.isNotEmpty != true) throw GatewayError('语音连接失败');
    if (!_active) return _throwEnd();
    final Json? result;
    try {
      result = await call.job.untilCancelled(
        owner._voiceRequest('voice-live/session', {
          'sdp': sdp,
          'history': history,
        }),
      );
    } on GatewayError catch (error) {
      if (!{404, 405, 501, 502, 503}.contains(error.status)) rethrow;
      throw _LiveStartUnavailable(error.message, error.status);
    }
    if (!_active || result == null) return _throwEnd();
    final transport = result['transport'];
    final answer = transport is Json ? transport['sdp'] : null;
    if (answer is! String || answer.isEmpty) {
      throw _LiveStartUnavailable('语音连接失败');
    }
    _starting = Timer(const Duration(seconds: 20), () {
      _finish(const _LiveTransportLost('语音连接超时'));
    });
    try {
      await peer.setRemoteDescription(
        rtc.RTCSessionDescription(answer, 'answer'),
      );
    } catch (_) {
      if (!_active) return _throwEnd();
      // A rejected SDP answer means the live service could not start.
      throw _LiveStartUnavailable('语音连接失败');
    }
    await _throwEnd();
  }

  Future<void> _throwEnd() async {
    final error = await call.job.untilCancelled(_ended.future);
    if (error != null) throw error;
  }

  void _connectionChanged(rtc.RTCPeerConnectionState state) {
    if (!_active) return;
    switch (state) {
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _finish(const _LiveTransportLost('语音连接已断开'));
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        _reconnecting ??= Timer(const Duration(seconds: 12), () {
          _finish(const _LiveTransportLost('语音连接恢复超时'));
        });
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _reconnecting?.cancel();
        _reconnecting = null;
      default:
        break;
    }
  }

  void _finish([Exception? error]) {
    if (!_ended.isCompleted) _ended.complete(error);
  }

  void _message(rtc.RTCDataChannelMessage message) {
    if (!_active) return;
    final Json? event;
    try {
      final parsed = jsonDecode(
        message.isBinary ? utf8.decode(message.binary) : message.text,
      );
      event = parsed is Json ? parsed : null;
    } on FormatException {
      return;
    }
    switch (event?['type']) {
      case 'session.started':
        if (ready) return;
        _starting?.cancel();
        ready = true;
        updateMicrophone();
        delegations.peerReady();
      case 'session.input_transcript.delta':
      case 'session.output_transcript.delta':
        if (event?['delta'] case final String text) {
          transcript.append(
            event!['type'] == 'session.input_transcript.delta',
            text,
          );
        }
      case 'session.delegation.created':
        final delegation = event?['delegation'];
        if (delegation case {'id': final String id}) {
          _accept(id);
        }
      case 'session.closed':
        _finish(GatewayError('语音服务已结束通话'));
      case 'error':
        final failure = event?['error'];
        if (failure is Json &&
            failure['code'] != 'context_injection_incomplete') {
          owner.error = '语音服务暂时无法完成操作';
          owner._setPhase(owner.phase);
        }
    }
  }

  void _accept(String id) {
    final prompt = transcript.lastPrompt;
    if (!ready || id.isEmpty || prompt == null || !_heard.add(id)) return;
    if (_heard.length > 128) _heard.remove(_heard.first);
    if (_endsCall(prompt)) {
      owner.cancel();
      return;
    }
    delegations.accept(this, (
      id: id,
      prompt: prompt,
      context: transcript.context(),
    ));
  }

  void updateMicrophone() {
    if (!_active) return;
    for (final track
        in _local?.getAudioTracks() ?? const <rtc.MediaStreamTrack>[]) {
      track.enabled = ready && !call.muted;
    }
    if (ready && _muted != call.muted) {
      _muted = call.muted;
      unawaited(
        _send({
          'type': _muted
              ? 'session.input_audio.mute'
              : 'session.input_audio.unmute',
        }),
      );
    }
  }

  void updateSpeaker() {
    if (!_active) return;
    for (final track in _remoteTracks) {
      track.enabled = call.speaker;
    }
  }

  void finishUtterance() {
    if (!ready || call.muted) return;
    unawaited(
      _send({
        'type': 'session.instructions.append',
        'delegation_id': null,
        'content':
            'The user has finished speaking. Respond now to what they said.',
      }),
    );
  }

  Future<bool> _send(Json event) async {
    if (!_active || !ready) return false;
    try {
      await _channel!.send(
        rtc.RTCDataChannelMessage(
          jsonEncode({'event_id': const Uuid().v4(), ...event}),
        ),
      );
      return true;
    } catch (_) {
      _finish(const _LiveTransportLost('语音连接已断开'));
      return false;
    }
  }

  Future<void> close() async {
    _closed = true;
    _starting?.cancel();
    _reconnecting?.cancel();
    final peer = _peer;
    final local = _local;
    final channel = _channel;
    channel?.onMessage = null;
    channel?.onDataChannelState = null;
    peer?.onTrack = null;
    peer?.onIceGatheringState = null;
    peer?.onConnectionState = null;
    try {
      if (local != null) {
        try {
          await Future.wait(local.getTracks().map((track) => track.stop()));
        } finally {
          await local.dispose();
        }
      }
    } finally {
      try {
        await channel?.close();
      } finally {
        await peer?.dispose();
      }
    }
  }
}

class _LiveTranscript {
  final _turns = <({bool user, String text})>[];

  void append(bool user, String delta) {
    final tail = _turns.lastOrNull;
    final previous = tail?.user == user ? _turns.removeLast().text : '';
    final runes = (previous + delta).runes.toList();
    _turns.add((
      user: user,
      text: String.fromCharCodes(
        runes.skip(runes.length > 8000 ? runes.length - 8000 : 0),
      ),
    ));
    if (_turns.length > 12) _turns.removeAt(0);
  }

  String? get lastPrompt => _turns.reversed
      .where((turn) => turn.user && turn.text.trim().isNotEmpty)
      .firstOrNull
      ?.text
      .trim();

  String context() => _turns
      .map(
        (turn) =>
            '${turn.user ? 'User' : 'Voice assistant'}: ${turn.text.trim()}',
      )
      .join('\n');

  Iterable<Json> seed() =>
      _turns.map((turn) => liveVoiceHistoryItem(turn.user, turn.text));
}

Json liveVoiceHistoryItem(bool user, String text) => {
  'type': 'message',
  'role': user ? 'user' : 'assistant',
  'content': [
    {'type': user ? 'input_text' : 'output_text', 'text': text},
  ],
};
