import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'mobile_locale.dart';
import 'mobile_voice.dart';
import 'ui_kit.dart';

/// Voice conversation as a floating glass bubble, so the chat stays in view.
/// Collapsed it is a pill with the orb, status, mute and hang up; tapping the
/// orb opens a card with what was heard, the reply and every control. It
/// can be dragged anywhere on screen.
class VoiceCallBubble extends StatefulWidget {
  const VoiceCallBubble({
    super.key,
    required this.voice,
    required this.bottomInset,
  });

  final MobileVoice voice;

  /// Space reserved at the bottom (the composer dock) to start above.
  final double bottomInset;

  @override
  State<VoiceCallBubble> createState() => _VoiceCallBubbleState();
}

class _VoiceCallBubbleState extends State<VoiceCallBubble> {
  Offset drag = Offset.zero;
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final voice = widget.voice;
    final media = MediaQuery.of(context);
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final width = expanded ? 300.0 : null;
        return Stack(
          children: [
            Positioned(
              right: (12 - drag.dx).clamp(
                8.0,
                media.size.width - (width ?? 220) - 8,
              ),
              bottom: (widget.bottomInset + 12 - drag.dy).clamp(
                media.padding.bottom + 8,
                media.size.height - media.padding.top - 140,
              ),
              child: GestureDetector(
                onPanUpdate: (details) => setState(() => drag += details.delta),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.bottomRight,
                  child: GlassSurface(
                    radius: expanded ? 28 : 32,
                    opacity: Theme.of(context).brightness == Brightness.dark
                        ? .82
                        : .88,
                    child: SizedBox(
                      width: width,
                      child: expanded
                          ? _expanded(context, voice)
                          : _collapsed(context, voice),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _orb(MobileVoice voice, double size) => GestureDetector(
    onTap: () => setState(() => expanded = !expanded),
    child: Semantics(
      button: true,
      label: context.tr(expanded ? '收起' : '展开'),
      child: _VoiceOrb(level: voice.level, mood: _moodOf(voice), size: size),
    ),
  );

  Widget _collapsed(BuildContext context, MobileVoice voice) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _orb(voice, 40),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 96),
          child: Semantics(
            liveRegion: true,
            child: Text(
              context.tr(_callStatus(voice)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _RoundButton(
          icon: voice.muted ? Icons.mic_off_rounded : Icons.mic_none_rounded,
          tooltip: context.tr(voice.muted ? '取消麦克风静音' : '静音麦克风'),
          active: voice.muted,
          onTap: voice.toggleCallMute,
        ),
        const SizedBox(width: 6),
        _RoundButton(
          icon: Icons.call_end_rounded,
          tooltip: context.tr('结束语音对话'),
          danger: true,
          onTap: voice.cancel,
        ),
      ],
    ),
  );

  Widget _expanded(BuildContext context, MobileVoice voice) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _orb(voice, 46),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        context.tr(_callStatus(voice)),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: voice.error != null ? colors.error : null,
                        ),
                      ),
                    ),
                    Text(
                      voice.liveCall ? 'GPT-Live' : context.tr('语音转文字'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: context.tr('收起'),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => expanded = false),
                icon: const Icon(Icons.close_fullscreen_rounded, size: 18),
              ),
            ],
          ),
          if (voice.heard.isNotEmpty || voice.said.isNotEmpty) ...[
            const SizedBox(height: 10),
            _Transcript(heard: voice.heard, said: voice.said),
          ],
          if (voice.showStopHint) ...[
            const SizedBox(height: 8),
            Text(
              context.tr('说「停止」即可结束通话'),
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _RoundButton(
                icon: voice.muted
                    ? Icons.mic_off_rounded
                    : Icons.mic_none_rounded,
                tooltip: context.tr(voice.muted ? '取消麦克风静音' : '静音麦克风'),
                active: voice.muted,
                onTap: voice.toggleCallMute,
              ),
              _RoundButton(
                icon: voice.callSpeaker
                    ? Icons.volume_up_rounded
                    : Icons.volume_off_rounded,
                tooltip: context.tr(voice.callSpeaker ? '关闭语音播放' : '开启语音播放'),
                active: !voice.callSpeaker,
                onTap: voice.toggleCallSpeaker,
              ),
              _RoundButton(
                icon: Icons.check_rounded,
                tooltip: context.tr('结束本轮收音'),
                onTap: voice.canFinishUtterance ? voice.finishUtterance : null,
              ),
              _RoundButton(
                icon: Icons.call_end_rounded,
                tooltip: context.tr('结束语音对话'),
                danger: true,
                onTap: voice.cancel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.active = false,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active, danger;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = danger
        ? const Color(0xffe5484d)
        : active
        ? colors.onSurface
        : colors.onSurface.withValues(alpha: .07);
    final foreground = danger
        ? Colors.white
        : active
        ? colors.surface
        : colors.onSurface;
    return Opacity(
      opacity: onTap == null ? .35 : 1,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: background,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox.square(
              dimension: 42,
              child: Icon(icon, color: foreground, size: 21),
            ),
          ),
        ),
      ),
    );
  }
}

String _callStatus(MobileVoice voice) {
  if (voice.error case final message?) return message;
  if (voice.reconnecting) return '正在恢复语音连接…';
  return switch (voice.phase) {
    VoicePhase.opening => '正在连接…',
    VoicePhase.listening => voice.muted ? '麦克风已静音' : '我在听',
    VoicePhase.recording => '我在听',
    VoicePhase.transcribing => '正在理解…',
    VoicePhase.waiting => '正在思考…',
    VoicePhase.preparing => '正在思考…',
    VoicePhase.playing => '正在说',
    VoicePhase.idle => '',
  };
}

enum _OrbMood { idle, listening, thinking, speaking }

_OrbMood _moodOf(MobileVoice voice) {
  if (voice.muted || voice.reconnecting) return _OrbMood.idle;
  return switch (voice.phase) {
    VoicePhase.listening || VoicePhase.recording => _OrbMood.listening,
    VoicePhase.transcribing ||
    VoicePhase.waiting ||
    VoicePhase.preparing ||
    VoicePhase.opening => _OrbMood.thinking,
    VoicePhase.playing => _OrbMood.speaking,
    VoicePhase.idle => _OrbMood.idle,
  };
}

/// Gradient orb: swells with the microphone while listening, swirls while
/// thinking and pulses in rhythm while speaking.
class _VoiceOrb extends StatefulWidget {
  const _VoiceOrb({required this.level, required this.mood, this.size = 200});

  final ValueListenable<double> level;
  final _OrbMood mood;
  final double size;

  @override
  State<_VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<_VoiceOrb>
    with SingleTickerProviderStateMixin {
  late final ticker = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();
  double smoothed = 0;

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([ticker, widget.level]),
        builder: (context, _) {
          final t = ticker.value * 2 * math.pi;
          // Ease the raw level so the orb breathes instead of jittering.
          smoothed += (widget.level.value - smoothed) * .25;
          final swell = switch (widget.mood) {
            _OrbMood.listening => .06 * math.sin(t * 3) + .22 * smoothed,
            _OrbMood.speaking => .09 * (math.sin(t * 9) * .5 + .5),
            _OrbMood.thinking => .04 * math.sin(t * 2),
            _OrbMood.idle => .02 * math.sin(t),
          };
          final scale = 1 + swell;
          final spin = widget.mood == _OrbMood.thinking ? t * 2 : t * .5;
          return SizedBox.square(
            dimension: widget.size * 1.3,
            child: Center(
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      transform: GradientRotation(spin),
                      colors: [
                        colors.primary,
                        const Color(0xff7fd4ff),
                        const Color(0xffc8b6ff),
                        colors.primary.withValues(alpha: .85),
                        colors.primary,
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: colors.primary.withValues(
                          alpha: .25 + .25 * smoothed,
                        ),
                        blurRadius: widget.size * (.3 + .2 * swell.abs()),
                        spreadRadius: widget.size * .02,
                      ),
                    ],
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // Soft highlight gives the orb its glassy depth.
                      gradient: RadialGradient(
                        center: const Alignment(-.35, -.4),
                        radius: .9,
                        colors: [
                          Colors.white.withValues(alpha: .55),
                          Colors.white.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({required this.heard, required this.said});

  final String heard, said;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: Column(
        children: [
          if (heard.isNotEmpty)
            Text(
              heard,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          if (said.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              said,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                height: 1.45,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The composer while dictating: cancel, a live waveform with the elapsed
/// time, and a confirm button that sends the recording for transcription.
class DictationBar extends StatefulWidget {
  const DictationBar({super.key, required this.voice});

  final MobileVoice voice;

  @override
  State<DictationBar> createState() => _DictationBarState();
}

class _DictationBarState extends State<DictationBar> {
  static const _bars = 36;
  final history = List<double>.filled(_bars, 0, growable: true);
  Timer? clock;

  @override
  void initState() {
    super.initState();
    widget.voice.level.addListener(sample);
    clock = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.voice.level.removeListener(sample);
    clock?.cancel();
    super.dispose();
  }

  void sample() {
    setState(() {
      history
        ..removeAt(0)
        ..add(widget.voice.level.value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final voice = widget.voice;
    final recording = voice.phase == VoicePhase.recording;
    final since = voice.recordingSince;
    final elapsed = since == null
        ? Duration.zero
        : DateTime.now().difference(since);
    final stamp =
        '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            tooltip: context.tr('取消'),
            onPressed: voice.cancel,
            icon: const Icon(Icons.close_rounded),
          ),
          Expanded(
            child: recording
                ? CustomPaint(
                    painter: _WavePainter(history, colors.onSurface),
                    child: const SizedBox.expand(),
                  )
                : Row(
                    children: [
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        context.tr(
                          voice.phase == VoicePhase.transcribing
                              ? '正在转写…'
                              : '正在打开麦克风…',
                        ),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
          ),
          if (recording)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                stamp,
                style: TextStyle(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          IconButton.filled(
            tooltip: context.tr('转写录音'),
            onPressed: recording ? voice.finishDictation : null,
            style: IconButton.styleFrom(
              backgroundColor: colors.onSurface,
              foregroundColor: colors.surface,
              minimumSize: const Size(40, 40),
            ),
            icon: const Icon(Icons.check_rounded, size: 21),
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.levels, this.color);

  final List<double> levels;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final count = levels.length;
    final gap = size.width / count;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.min(3.0, gap * .55);
    for (var i = 0; i < count; i++) {
      final level = levels[i];
      final height = math.max(3.0, size.height * .7 * level);
      final x = gap * (i + .5);
      paint.color = color.withValues(alpha: .25 + .65 * (i / count));
      canvas.drawLine(
        Offset(x, size.height / 2 - height / 2),
        Offset(x, size.height / 2 + height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}
