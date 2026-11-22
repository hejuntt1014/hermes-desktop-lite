import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import 'gateway.dart';

part 'mobile_voice_conversation.dart';
part 'mobile_voice_live.dart';

enum VoicePhase {
  idle,
  opening,
  recording,
  listening,
  transcribing,
  waiting,
  preparing,
  playing,
}

class MobileVoice extends ChangeNotifier {
  MobileVoice(this.gateway, this.profile);

  final Gateway gateway;
  final String profile;
  VoicePhase phase = VoicePhase.idle;
  String? error;
  bool reconnecting = false;
  String? _nextSpeech;
  _VoiceJob? _job;
  bool _disposed = false;
  _VoiceCall? _call;

  /// Microphone level, 0 to 1, while dictating or listening in a call.
  final level = ValueNotifier<double>(0);

  /// What the call last heard from the user and what it is saying back.
  String heard = '', said = '';

  /// When the current dictation started recording, for its timer.
  DateTime? recordingSince;

  bool get inCall => _call != null;
  bool get liveCall => _call?.live == true;
  bool get readingReply =>
      _job != null &&
      !inCall &&
      (phase == VoicePhase.preparing || phase == VoicePhase.playing);
  bool get callActive => _call?.job.cancelled.isCompleted == false;
  bool get muted => _call?.muted == true;
  bool get callSpeaker => _call?.speaker == true;
  bool get showStopHint =>
      callActive &&
      !reconnecting &&
      !muted &&
      phase == VoicePhase.listening &&
      _call?.stopHint?.isActive == true;
  bool get canFinishUtterance =>
      !muted &&
      (_call?.livePeer?.ready == true ||
          !reconnecting && _call?.capture?.started == true);

  Future<String?> dictate() async {
    if (_job != null || _disposed) return null;
    final job = _begin(VoicePhase.opening);
    try {
      final audio = await _record(job);
      if (audio == null || job.cancelled.isCompleted) return null;
      final transcript = await _transcribe(job, audio);
      if (!job.cancelled.isCompleted && transcript == null) {
        throw GatewayError('未听到清晰的语音');
      }
      return transcript;
    } catch (e) {
      if (!job.cancelled.isCompleted) {
        error = e is GatewayError ? e.message : '无法录音或转写';
      }
      return null;
    } finally {
      _end();
    }
  }

  Future<String?> _transcribe(_VoiceJob job, Uint8List audio) async {
    if (audio.length < 3244) return null;
    final encoded = await job.untilCancelled(compute(base64Encode, audio));
    if (encoded == null || job.cancelled.isCompleted) return null;
    final data = await job.untilCancelled(
      _voiceRequest('transcribe', {
        'data_url': 'data:audio/wav;base64,$encoded',
        'mime_type': 'audio/wav',
      }),
    );
    if (data == null) return null;
    final value = data['transcript'];
    if (value is! String) throw GatewayError('语音请求失败');
    final transcript = value.trim();
    return transcript.isEmpty ? null : transcript;
  }

  Future<Uint8List?> _record(_VoiceJob job) async {
    final recorder = AudioRecorder();
    Directory? scratch;
    StreamSubscription<RecordStop>? stops;
    StreamSubscription<Amplitude>? amplitude;
    try {
      final permitted = await recorder.hasPermission();
      if (job.cancelled.isCompleted) return null;
      if (!permitted) throw GatewayError('请在系统设置中允许使用麦克风');
      final cache = await getTemporaryDirectory();
      scratch = await cache.createTemp('hermes-dictation-');
      if (job.cancelled.isCompleted) return null;
      final interrupted = Completer<void>();
      stops = recorder.onStopped().listen((_) {
        if (phase == VoicePhase.recording &&
            !job.finishCapture.isCompleted &&
            !interrupted.isCompleted) {
          interrupted.complete();
        }
      });
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: '${scratch.path}${Platform.pathSeparator}speech.wav',
      );
      if (job.cancelled.isCompleted) return null;
      amplitude = recorder
          .onAmplitudeChanged(const Duration(milliseconds: 70))
          .listen((sample) => level.value = _decibelLevel(sample.current));
      recordingSince = DateTime.now();
      _setPhase(VoicePhase.recording);
      final accepted = await job.untilCancelled(
        Future.any([
          job.finishCapture.future.then((_) => true),
          interrupted.future.then((_) => false),
        ]).timeout(const Duration(minutes: 2), onTimeout: () => true),
      );
      if (accepted == null || job.cancelled.isCompleted) return null;
      if (!accepted) throw GatewayError('录音已中断');
      _setPhase(VoicePhase.transcribing);
      final path = await recorder.stop();
      return path == null ? Uint8List(0) : await File(path).readAsBytes();
    } finally {
      await stops?.cancel();
      await amplitude?.cancel();
      recordingSince = null;
      level.value = 0;
      try {
        await recorder.dispose();
      } finally {
        if (scratch != null) await scratch.delete(recursive: true);
      }
    }
  }

  void finishDictation() {
    final job = _job;
    if (phase == VoicePhase.recording &&
        job != null &&
        !job.finishCapture.isCompleted) {
      job.finishCapture.complete();
    }
  }

  Future<void> speak(String text) async {
    if (_disposed || text.isEmpty) return;
    if (readingReply) {
      _nextSpeech = text;
      _job!.cancel();
      return;
    }
    if (_job != null) return;
    String? next = text;
    try {
      while (next != null && !_disposed) {
        _nextSpeech = null;
        final job = _begin(VoicePhase.preparing);
        try {
          await _speak(job, next);
        } catch (e) {
          if (!job.cancelled.isCompleted) {
            error = e is GatewayError ? e.message : '无法播放语音';
          }
        }
        next = _nextSpeech;
      }
    } finally {
      _nextSpeech = null;
      _end();
    }
  }

  Future<void> _speak(_VoiceJob job, String text, {_VoiceJob? playback}) async {
    final output = playback ?? job;
    _setPhase(VoicePhase.preparing);
    final result = await output.untilCancelled(
      _voiceRequest('speak', {'text': text}),
    );
    if (result == null || output.cancelled.isCompleted) return;
    final url = result['data_url'];
    if (url is! String || !url.startsWith('data:audio/')) {
      throw GatewayError('网关未返回语音音频');
    }
    final data = await output.untilCancelled(compute(_readSpeech, url));
    if (data == null || output.cancelled.isCompleted) return;
    await _playClip(output, data);
  }

  Future<void> _playClip(
    _VoiceJob job,
    ({String mime, Uint8List bytes}) data,
  ) async {
    final cache = await getTemporaryDirectory();
    final scratch = await cache.createTemp('hermes-speech-');
    try {
      final suffix = switch (data.mime) {
        'audio/wav' => 'wav',
        'audio/ogg' => 'ogg',
        'audio/flac' => 'flac',
        _ => 'mp3',
      };
      final audio = File(
        '${scratch.path}${Platform.pathSeparator}reply.$suffix',
      );
      await audio.writeAsBytes(data.bytes);
      if (job.cancelled.isCompleted) return;
      final player = AudioPlayer();
      final completed = Completer<bool>();
      void finish(bool ok) {
        if (!completed.isCompleted) completed.complete(ok);
      }

      // Listen before starting to catch the completion of short clips.
      final events = player.onPlayerComplete.listen(
        (_) => finish(true),
        onError: (Object _) => finish(false),
      );
      try {
        await player.setAudioContext(
          AudioContextConfig(focus: AudioContextConfigFocus.duckOthers).build(),
        );
        if (job.cancelled.isCompleted) return;
        await player.setSource(
          DeviceFileSource(audio.path, mimeType: data.mime),
        );
        if (job.cancelled.isCompleted) return;
        await player.resume();
        if (job.cancelled.isCompleted) return;
        _setPhase(VoicePhase.playing);
        if (await job.untilCancelled(completed.future) == false) {
          throw GatewayError('无法播放语音');
        }
      } finally {
        await events.cancel();
        await player.dispose();
      }
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  Future<Json> _voiceRequest(String route, Json body) async {
    try {
      final reply = await gateway.audio(route, profile, body);
      if (reply['ok'] != true) throw GatewayError('语音请求失败');
      return reply;
    } on GatewayError catch (e) {
      if ({404, 405, 501}.contains(e.status)) {
        throw GatewayError('网关未提供此语音功能', e.status);
      }
      rethrow;
    } on TimeoutException {
      throw GatewayError('语音请求超时');
    }
  }

  _VoiceJob _begin(VoicePhase next) {
    final job = _job = _VoiceJob();
    error = null;
    _setPhase(next);
    return job;
  }

  void _end() {
    _job = null;
    level.value = 0;
    heard = '';
    said = '';
    _setPhase(VoicePhase.idle);
  }

  /// Records what the call heard or is saying; a new user turn clears the
  /// previous reply so the two lines always belong together.
  void _transcribed({required bool user, required String text}) {
    if (user) {
      if (heard.isEmpty || said.isNotEmpty) said = '';
      heard = text;
    } else {
      said = text;
    }
    if (!_disposed) notifyListeners();
  }

  void _setPhase(VoicePhase next) {
    phase = next;
    if (_call case final call?
        when next == VoicePhase.listening &&
            !call.job.cancelled.isCompleted &&
            call.stopHint == null) {
      call.stopHint = Timer(const Duration(seconds: 7), () {
        if (!_disposed) notifyListeners();
      });
    }
    if (!_disposed) notifyListeners();
  }

  void dismissError() {
    error = null;
    if (!_disposed) notifyListeners();
  }

  void updateConnection({required bool recovering, String? failure}) {
    if (failure != null) {
      error = failure;
      cancel();
    }
    if (reconnecting == recovering && failure == null) return;
    reconnecting = recovering;
    if (_call case final call?) {
      if (recovering) {
        call.captureResumed ??= Completer<void>();
        call.capture?.stop(false);
      } else {
        final waiting = call.captureResumed;
        call.captureResumed = null;
        waiting?.complete();
      }
    }
    if (!_disposed) notifyListeners();
  }

  void cancel() {
    _nextSpeech = null;
    _call?.stopHint?.cancel();
    _call?.interruptInput?.cancel();
    _call?.playback?.cancel();
    _job?.cancel();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    level.dispose();
    super.dispose();
  }
}

/// Maps a recorder level in dBFS onto 0 to 1, treating -50 dB as silence.
double _decibelLevel(double decibels) =>
    decibels.isFinite ? ((decibels + 50) / 50).clamp(0.0, 1.0) : 0;

/// Level of a 16-bit little-endian PCM chunk, on the same 0 to 1 scale.
double _pcmLevel(Uint8List chunk) {
  if (chunk.length < 2) return 0;
  final data = ByteData.sublistView(chunk);
  var energy = 0.0;
  final samples = chunk.length ~/ 2;
  for (var offset = 0; offset < samples * 2; offset += 2) {
    final sample = data.getInt16(offset, Endian.little) / 32768;
    energy += sample * sample;
  }
  final rms = math.sqrt(energy / samples);
  return rms <= 0 ? 0 : _decibelLevel(20 * math.log(rms) / math.ln10);
}

class _VoiceJob {
  final cancelled = Completer<void>();
  final finishCapture = Completer<void>();

  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }

  Future<T?> untilCancelled<T>(Future<T> work) =>
      Future.any<T?>([work, cancelled.future.then<T?>((_) => null)]);
}

({String mime, Uint8List bytes}) _readSpeech(String url) {
  final data = UriData.parse(url);
  if (!data.isBase64) throw const FormatException('Invalid audio response');
  return (mime: data.mimeType, bytes: data.contentAsBytes());
}
