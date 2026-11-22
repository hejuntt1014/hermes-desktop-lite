part of 'mobile_voice.dart';

extension MobileVoiceConversation on MobileVoice {
  bool stopWithPhrase(String text) {
    if (!callActive || !_endsCall(text)) return false;
    cancel();
    return true;
  }

  Future<void> converse({
    required Future<String?> Function(
      String text,
      bool interrupted,
      String? context,
    )
    submit,
    required Future<bool> Function() interrupt,
    required String Function(String) spokenText,
    required String delegationFailure,
    required List<Json> Function() liveHistory,
    required VoidCallback unavailable,
    required ValueChanged<String> onNotice,
    bool preferLive = false,
  }) async {
    if (_job != null || _disposed) return;
    final job = _begin(VoicePhase.opening);
    final call = _call = _VoiceCall(job);
    try {
      final engine = await job.untilCancelled(
        VoiceEngineStatus.read(
          gateway,
          profile,
        ).catchError((Object _) => const VoiceEngineStatus()),
      );
      if (engine == null || job.cancelled.isCompleted) return;
      // GPT-Live is the default engine: used whenever the gateway can run it,
      // unless the user explicitly chose speech-to-text.
      if (engine.liveAvailable && (engine.liveSelected || preferLive)) {
        call.live = true;
        if (await _runLive(
          call,
          liveHistory(),
          submit,
          interrupt,
          spokenText,
          delegationFailure,
        )) {
          return;
        }
        call.live = false;
      }
      if (job.cancelled.isCompleted) return;
      // Only an explicit GPT-Live choice is worth a notice when it falls back.
      if (engine.liveSelected) unavailable();
      var transcript = await _listen(call, job, onNotice);
      var interrupted = false;
      while (transcript != null && !job.cancelled.isCompleted) {
        if (_endsCall(transcript)) return;
        _transcribed(user: true, text: transcript);
        _setPhase(VoicePhase.waiting);
        final response = submit(transcript, interrupted, null);
        final duringReply = call.interruptInput = _VoiceJob();
        final followup = _listen(call, duringReply, onNotice, waiting: true);
        final ({String? reply, String? input})? first;
        try {
          first = await job.untilCancelled(
            Future.any([
              response.then((reply) => (reply: reply, input: null)),
              followup.then((input) => (reply: null, input: input)),
            ]),
          );
        } finally {
          duringReply.cancel();
          call.interruptInput = null;
        }
        if (first == null || job.cancelled.isCompleted) return;
        if (first.input case final next?) {
          if (_endsCall(next)) return;
          final stopped = await job.untilCancelled(interrupt());
          if (stopped == null) return;
          interrupted = stopped;
          if (await job.untilCancelled(response) == null) return;
          transcript = next;
          continue;
        }
        await followup;
        if (first.reply == null) return;
        final reply = spokenText(first.reply!);
        if (reply.isNotEmpty) _transcribed(user: false, text: reply);
        if (call.speaker && reply.isNotEmpty && !job.cancelled.isCompleted) {
          final playback = call.playback = _VoiceJob();
          try {
            await _speak(job, reply, playback: playback);
          } on Exception catch (failure) {
            if (!job.cancelled.isCompleted && !playback.cancelled.isCompleted) {
              onNotice(failure is GatewayError ? failure.message : '无法播放语音');
            }
          } finally {
            call.playback = null;
          }
        }
        interrupted = false;
        transcript = await _listen(call, job, onNotice);
      }
    } catch (e) {
      if (!job.cancelled.isCompleted) {
        error = e is GatewayError ? e.message : '语音对话已中断';
      }
    } finally {
      // The microphone can still be releasing if the reply and stop arrived together.
      call.stopHint?.cancel();
      final capture = call.capture;
      capture?.stop(false);
      await capture?.released.future;
      _call = null;
      _end();
    }
  }

  Future<String?> _listen(
    _VoiceCall call,
    _VoiceJob input,
    ValueChanged<String> onNotice, {
    bool waiting = false,
  }) async {
    while (!input.cancelled.isCompleted && !call.job.cancelled.isCompleted) {
      if (call.captureResumed case final resumed?) {
        await input.untilCancelled(resumed.future);
        continue;
      }
      if (!waiting) _setPhase(VoicePhase.listening);
      if (call.muted) {
        await input.untilCancelled(call.unmute!.future);
        continue;
      }
      final muteRevision = call.muteRevision;
      final pcm = await _captureUtterance(call, input);
      if (input.cancelled.isCompleted || call.job.cancelled.isCompleted) {
        return null;
      }
      if (pcm == null || muteRevision != call.muteRevision) continue;
      // Keep a finished utterance if the connection drops while audio is releasing.
      var resumed = call.captureResumed;
      while (resumed != null) {
        await input.untilCancelled(resumed.future);
        if (input.cancelled.isCompleted || call.job.cancelled.isCompleted) {
          return null;
        }
        resumed = call.captureResumed;
      }
      if (muteRevision != call.muteRevision) continue;
      if (!waiting) _setPhase(VoicePhase.transcribing);
      try {
        final text = await _transcribe(input, _speechWav(pcm));
        if (text != null && muteRevision == call.muteRevision) return text;
      } on Exception catch (failure) {
        if (!input.cancelled.isCompleted &&
            !call.job.cancelled.isCompleted &&
            muteRevision == call.muteRevision) {
          onNotice(failure is GatewayError ? failure.message : '无法录音或转写');
        }
      }
    }
    return null;
  }

  Future<Uint8List?> _captureUtterance(_VoiceCall call, _VoiceJob input) async {
    final capture = call.capture = _VoiceCapture();
    final recorder = AudioRecorder();
    StreamSubscription<Uint8List>? frames;
    StreamSubscription<RecordState>? states;
    try {
      if (!call.micGranted) {
        _setPhase(VoicePhase.opening);
        final permitted = await recorder.hasPermission();
        if (input.cancelled.isCompleted || call.job.cancelled.isCompleted) {
          return null;
        }
        if (!permitted) throw GatewayError('请在系统设置中允许使用麦克风');
        call.micGranted = true;
      }
      if (input.cancelled.isCompleted || capture.done.isCompleted) return null;
      final audio = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );
      if (input.cancelled.isCompleted || capture.done.isCompleted) return null;
      capture.started = true;
      _setPhase(phase == VoicePhase.waiting ? phase : VoicePhase.listening);
      final detector = _UtteranceDetector();
      frames = audio.listen(
        (chunk) {
          level.value = _pcmLevel(chunk);
          if (!capture.done.isCompleted && detector.add(chunk)) {
            capture.stop(true);
          }
        },
        onError: (Object _) => capture.fail(),
        onDone: capture.fail,
      );
      states = recorder.onStateChanged().listen((state) {
        if (state == RecordState.pause) capture.fail();
      });
      final accepted = await input.untilCancelled(capture.done.future);
      if (accepted == null && !input.cancelled.isCompleted) {
        throw GatewayError('录音已中断');
      }
      if (!input.cancelled.isCompleted && accepted == true) {
        return detector.take();
      }
      return null;
    } finally {
      capture.stop(false);
      level.value = 0;
      try {
        await frames?.cancel();
        await states?.cancel();
        await recorder.dispose();
      } finally {
        if (identical(call.capture, capture)) {
          call.capture = null;
          _setPhase(phase);
        }
        capture.released.complete();
      }
    }
  }

  void toggleCallMute() {
    final call = _call;
    if (call == null || call.job.cancelled.isCompleted) return;
    if (call.unmute case final unmute?) {
      call.unmute = null;
      unmute.complete();
    } else {
      call.unmute = Completer<void>();
      call.muteRevision++;
      call.capture?.stop(false);
    }
    call.livePeer?.updateMicrophone();
    _setPhase(phase);
  }

  void toggleCallSpeaker() {
    final call = _call;
    if (call == null || call.job.cancelled.isCompleted) return;
    call.speaker = !call.speaker;
    if (!call.speaker) call.playback?.cancel();
    call.livePeer?.updateSpeaker();
    _setPhase(phase);
  }

  void finishUtterance() {
    _call?.capture?.stop(true);
    _call?.livePeer?.finishUtterance();
  }
}

class _VoiceCall {
  _VoiceCall(this.job);
  final _VoiceJob job;
  bool micGranted = false;

  /// The call runs on GPT-Live rather than speech-to-text.
  bool live = false;
  bool speaker = true;
  int muteRevision = 0;
  Completer<void>? unmute;
  Completer<void>? captureResumed;
  _VoiceCapture? capture;
  _VoiceJob? interruptInput;
  _VoiceJob? playback;
  _LivePeer? livePeer;
  Timer? stopHint;
  bool get muted => unmute != null;
}

class _VoiceCapture {
  final done = Completer<bool?>();
  final released = Completer<void>();
  bool started = false;

  void stop(bool transcribe) {
    if (!done.isCompleted) done.complete(transcribe);
  }

  void fail() {
    if (!done.isCompleted) done.complete(null);
  }
}

class _UtteranceDetector {
  // 20 ms of 16 kHz mono PCM, with 300 ms of lead-in and 800 ms of trailing silence.
  static const _frameBytes = 640;
  final _frame = Uint8List(_frameBytes);
  final _leadIn = ListQueue<Uint8List>(15);
  final _sample = BytesBuilder(copy: false);
  int _filled = 0, _voiced = 0, _quiet = 0;

  bool add(Uint8List chunk) {
    var offset = 0;
    while (offset < chunk.length) {
      final remaining = (chunk.length - offset).clamp(0, _frameBytes - _filled);
      _frame.setRange(_filled, _filled + remaining, chunk, offset);
      _filled += remaining;
      offset += remaining;
      if (_filled != _frameBytes) continue;
      _filled = 0;
      if (_completeFrame()) return true;
    }
    return false;
  }

  bool _completeFrame() {
    final data = ByteData.sublistView(_frame);
    var energy = 0;
    for (var offset = 0; offset < _frameBytes; offset += 2) {
      final sample = data.getInt16(offset, Endian.little);
      energy += sample * sample;
    }
    final loud = energy > 0.014 * 0.014 * 32768 * 32768 * (_frameBytes ~/ 2);
    final frame = Uint8List.fromList(_frame);
    if (_sample.isEmpty) {
      if (_leadIn.length == 15) _leadIn.removeFirst();
      _leadIn.addLast(frame);
      _voiced = loud ? _voiced + 1 : 0;
      if (_voiced >= 3) _takeLeadIn();
      return false;
    }
    _sample.add(frame);
    _quiet = loud ? 0 : _quiet + 1;
    return _quiet >= 40 || _sample.length >= 16000 * 2 * 45;
  }

  void _takeLeadIn() {
    while (_leadIn.isNotEmpty) {
      _sample.add(_leadIn.removeFirst());
    }
  }

  Uint8List take() {
    _takeLeadIn();
    if (_filled > 1) {
      _sample.add(Uint8List.sublistView(_frame, 0, _filled & ~1));
    }
    return _sample.takeBytes();
  }
}

Uint8List _speechWav(Uint8List pcm) {
  final bytes = Uint8List(44 + pcm.length);
  final header = ByteData.sublistView(bytes);
  void u16(int at, int value) => header.setUint16(at, value, Endian.little);
  void u32(int at, int value) => header.setUint32(at, value, Endian.little);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  u32(4, 36 + pcm.length);
  bytes.setRange(8, 16, 'WAVEfmt '.codeUnits);
  u32(16, 16);
  u16(20, 1);
  u16(22, 1);
  u32(24, 16000);
  u32(28, 32000);
  u16(32, 2);
  u16(34, 16);
  bytes.setRange(36, 40, 'data'.codeUnits);
  u32(40, pcm.length);
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}

bool _endsCall(String transcript) {
  final phrase = transcript
      .toLowerCase()
      .trim()
      .replaceAll(
        RegExp(r'^\s*(?:(?:hey hermes|hermes|okay|ok|hey)[\s,，]+)|[.!?。！？]+$'),
        '',
      )
      .trim();
  return {
    'stop',
    'stop listening',
    'stop it',
    'stop please',
    'please stop',
    'stop stop',
    'that is all',
    "that's all",
    'never mind',
    'nevermind',
    'end conversation',
    'end the conversation',
    'goodbye',
    'good bye',
    'bye',
    'cancel',
    '停止',
    '结束对话',
    '停止对话',
  }.contains(phrase);
}
