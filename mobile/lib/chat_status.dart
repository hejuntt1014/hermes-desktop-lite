part of 'chat.dart';

extension _ChatStatus on _ChatPageState {
  void updateContextUsage(Json wire) {
    final known = contextMeter.value;
    final source = wire['usage'] is Json ? wire['usage'] as Json : wire;
    final model = source['model'] ?? wire['model'];
    if (model is String &&
        model.isNotEmpty &&
        currentModel != null &&
        model != currentModel) {
      return;
    }
    final next = ContextMeterDisplay.fromWire(source, known: known);
    if (next != null && next != known) contextMeter.value = next;
  }

  void updateContextModel(String? model) {
    if (model == null || model.isEmpty || model == currentModel) return;
    currentModel = model;
    contextMeter.value = null;
  }

  Future<bool> refreshContextUsage() {
    final existing = contextReading;
    if (existing != null) return existing;
    final request = readContextUsage();
    contextReading = request;
    return request.whenComplete(() {
      if (identical(contextReading, request)) contextReading = null;
    });
  }

  Future<bool> readContextUsage() async {
    final sid = runtime;
    if (sid == null || !gatewayReady || busy || running || hydrating) {
      return false;
    }
    final revision = linkRevision;
    final generation = modelControls?.version?.generation;
    final sequence = seq;
    try {
      final data = await widget.gateway.call('session.context_breakdown', {
        'session_id': sid,
        'profile': widget.profile,
      }, timeout: const Duration(seconds: 15));
      if (!mounted ||
          sid != runtime ||
          running ||
          linkRevision != revision ||
          modelControls?.version?.generation != generation ||
          seq != sequence) {
        return false;
      }
      updateContextUsage(data);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> refreshSessionApproval() async {
    final gateway = widget.gateway;
    final sid = runtime;
    final profile = widget.profile;
    if (!gateway.canonical || !gateway.usable || sid == null) return;
    final revision = linkRevision;
    try {
      final result = await gateway.call('config.get', {
        'session_id': sid,
        'profile': profile,
        'key': 'yolo',
      }, timeout: const Duration(seconds: 8));
      final bypass = switch (result['value']) {
        '1' || true => true,
        '0' || false => false,
        _ => null,
      };
      if (mounted &&
          identical(widget.gateway, gateway) &&
          widget.profile == profile &&
          sid == runtime &&
          revision == linkRevision &&
          bypass != null) {
        sessionApprovalBypass.value = bypass;
      }
    } catch (_) {
      // Keep the value from the conversation snapshot when the read fails.
    }
  }

  Future<void> openSessionStatus() {
    draftFocus.unfocus();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => SessionStatusSheet(
        gateway: widget.gateway,
        profile: widget.profile,
        contextMeter: contextMeter,
        sessionApprovalBypass: runtime == null ? null : sessionApprovalBypass,
        refreshSessionApproval: runtime == null ? null : refreshSessionApproval,
        refreshContext: runtime == null ? null : refreshContextUsage,
      ),
    );
  }
}
