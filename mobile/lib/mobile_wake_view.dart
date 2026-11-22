import 'package:material_ui/material_ui.dart';

import 'gateway.dart';
import 'mobile_locale.dart';
import 'mobile_wake.dart';

Future<bool?> showWakeSettings(BuildContext context, MobileWake wake) {
  final status = wake.status();
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: FutureBuilder<Json>(
          future: status,
          builder: (context, snapshot) {
            final data = snapshot.data;
            final available =
                data?['available'] == true && data?['capture'] == 'client';
            final phrase = data?['phrase'] as String?;
            final failure = snapshot.error;
            final message = failure is GatewayError
                ? failure.message
                : snapshot.hasError || data?['available'] == false
                ? '网关语音唤醒不可用'
                : data != null && !available
                ? '网关需要启用客户端麦克风'
                : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Text(
                    context.tr('语音唤醒'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.hearing_rounded),
                  title: Text(context.tr('前台监听唤醒词')),
                  subtitle: Text(context.tr('监听时，麦克风音频会发送到当前网关。')),
                  value: wake.enabled,
                  onChanged: wake.enabled || available
                      ? (value) => Navigator.of(context).pop(value)
                      : null,
                ),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const LinearProgressIndicator(minHeight: 2),
                if (message != null || phrase?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(15, 6, 15, 0),
                    child: Text(
                      message != null
                          ? context.tr(message)
                          : context.strings.format('唤醒词：{phrase}', {
                              'phrase': phrase!,
                            }),
                    ),
                  ),
                if (wake.enabled && available && wake.error != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(context.tr('重试')),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class WakeIndicator extends StatelessWidget {
  const WakeIndicator({
    super.key,
    required this.wake,
    required this.onSettings,
  });

  final MobileWake wake;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: wake,
    builder: (context, _) {
      if (!wake.enabled ||
          !wake.listening && !wake.starting && wake.error == null) {
        return const SizedBox.shrink();
      }
      final colors = Theme.of(context).colorScheme;
      final caption = wake.error != null
          ? context.tr(wake.error!)
          : wake.starting
          ? context.tr('正在启动语音唤醒…')
          : context.strings.format('监听唤醒词 · {phrase}', {
              'phrase': wake.phrase ?? 'Hey Hermes',
            });
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: TextButton.icon(
            onPressed: onSettings,
            icon: Icon(
              wake.error == null
                  ? Icons.hearing_rounded
                  : Icons.error_outline_rounded,
              size: 16,
            ),
            label: Text(caption),
            style: TextButton.styleFrom(
              foregroundColor: wake.error == null
                  ? colors.onSurfaceVariant
                  : colors.error,
            ),
          ),
        ),
      );
    },
  );
}
