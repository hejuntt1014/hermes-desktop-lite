import 'package:material_ui/material_ui.dart';

import 'gateway.dart';
import 'mobile_locale.dart';
import 'transcript_match_view.dart';
import 'transcript_navigation.dart';
import 'transcript_search.dart';

Future<TranscriptMatchExcerpt?> chooseTranscriptOccurrence(
  BuildContext context, {
  required TranscriptNavigation navigation,
  required MessageAddress address,
  required String query,
}) => showModalBottomSheet<TranscriptMatchExcerpt>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) =>
      _OccurrenceSheet(navigation: navigation, address: address, query: query),
);

class _OccurrenceSheet extends StatefulWidget {
  const _OccurrenceSheet({
    required this.navigation,
    required this.address,
    required this.query,
  });

  final TranscriptNavigation navigation;
  final MessageAddress address;
  final String query;

  @override
  State<_OccurrenceSheet> createState() => _OccurrenceSheetState();
}

class _OccurrenceSheetState extends State<_OccurrenceSheet> {
  final excerpts = <TranscriptMatchExcerpt>[];
  FileTransferControl? _reading;
  TranscriptOccurrenceCursor? _cursor;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reading?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _reading?.cancel();
    final control = FileTransferControl();
    setState(() {
      _reading = control;
      _error = null;
    });
    bool current() => mounted && identical(_reading, control);
    try {
      final row = await widget.navigation.readRow(
        widget.address,
        inlineImages: false,
        stillOpen: current,
        control: control,
      );
      if (!current()) return;
      if (row == null) throw GatewayError('目标消息已不可见');
      final cursor = await TranscriptOccurrenceCursor.read(row, widget.query);
      if (!current()) return;
      setState(() {
        _cursor = cursor;
        excerpts.addAll(cursor.nextPage());
      });
    } catch (error) {
      if (current()) setState(() => _error = error.toString());
    } finally {
      if (current()) setState(() => _reading = null);
    }
  }

  Widget _positions(BuildContext context) {
    if (_reading != null)
      return const Center(child: CircularProgressIndicator());
    if (_error case final message?) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.tr(message)),
            TextButton(onPressed: _load, child: Text(context.tr('重试'))),
          ],
        ),
      );
    }
    if (excerpts.isEmpty) {
      return Center(child: Text(context.tr('此消息没有匹配的内容')));
    }
    final more = _cursor?.hasMore == true;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: excerpts.length + (more ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == excerpts.length) {
          return Center(
            child: TextButton(
              onPressed: () =>
                  setState(() => excerpts.addAll(_cursor!.nextPage())),
              child: Text(context.tr('查看更多匹配')),
            ),
          );
        }
        final excerpt = excerpts[index];
        return ListTile(
          title: TranscriptMatchText(excerpt, maxLines: 3),
          trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 15),
          onTap: () => Navigator.pop(context, excerpt),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: FractionallySizedBox(
      heightFactor: .68,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Semantics(
              header: true,
              child: Text(
                context.tr('匹配位置'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          Expanded(child: _positions(context)),
        ],
      ),
    ),
  );
}
