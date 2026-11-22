part of 'chat.dart';

enum _QueueAction { edit, withdraw, check, retry, discard }

extension _ChatQueue on _ChatPageState {
  FollowupQueue? get queueStore {
    final id = widget.id ?? stored;
    return id == null
        ? null
        : FollowupQueue(widget.gateway, widget.profile, id);
  }

  bool get queuesDraft =>
      running ||
      queueDraining ||
      followups.isNotEmpty ||
      remoteFollowups.isNotEmpty;

  bool canSendBusyText(String text, {required bool hasAttachments}) =>
      runtime != null &&
      running &&
      !stopping &&
      !queueDraining &&
      !queueEditing &&
      followups.isEmpty &&
      remoteFollowups.isEmpty &&
      pendingInteractions.isEmpty &&
      !voice.callActive &&
      !hasAttachments &&
      text.isNotEmpty &&
      !text.startsWith('/');

  Future<Json?> sendBusyCorrection(
    String method,
    String session,
    int generation,
    String text,
  ) async {
    final Json reply;
    try {
      reply = await widget.gateway.call(method, {
        'session_id': session,
        'profile': widget.profile,
        'execution_generation': generation,
        'text': text,
      });
    } on GatewayError catch (error) {
      if (const {
        'execution_not_ready',
        'unsupported_control',
        'stale_generation',
      }.contains(error.data?['reason'])) {
        return null;
      }
      rethrow;
    }
    if (reply['voice_stopped'] == true) return reply;
    if (reply['execution_generation'] == generation) {
      if (reply['status'] == 'rejected' && reply['delivered'] == false) {
        return null;
      }
      if (const {'redirected', 'queued', 'steered'}.contains(reply['status'])) {
        return reply;
      }
    }
    throw GatewayError('网关未返回发送确认');
  }

  bool get queueCanDrain =>
      mounted &&
      queueLoaded &&
      gatewayReady &&
      !busy &&
      !running &&
      !loadingOlder &&
      !hydrating &&
      !slashPending &&
      !readOnly &&
      !queueDraining &&
      !queueEditing &&
      rewrite == null &&
      pendingInteractions.isEmpty &&
      unconfirmedSend == null &&
      modelStatus == null &&
      !applyingModelPreset &&
      remoteFollowups.isEmpty &&
      runtime != null;

  Future<(String, Json)?> prepareOutbound(
    String session,
    String caption,
    List<XFile> documents,
    List<XFile> photos, {
    String? queuedId,
    String? submissionId,
    FileTransferControl? control,
  }) async {
    control?.throwIfCancelled();
    final canonical = widget.gateway.canonical;
    final revision = linkRevision;
    bool current() => mounted && runtime == session && linkRevision == revision;
    // Drafts created by older builds can still mark a file as an inline photo.
    final documentInputs = [...documents];
    final photoInputs = <XFile>[];
    for (final photo in photos) {
      control?.throwIfCancelled();
      final supported = await isComposerPhoto(photo);
      if (!current()) return null;
      (supported ? photoInputs : documentInputs).add(photo);
    }
    if (photoInputs.length > composerPhotoLimit) {
      throw GatewayError('一次最多发送 10 张图片');
    }
    if (!canonical) {
      var encodedSize = 0;
      for (final photo in photoInputs) {
        final size = await photo.length();
        encodedSize += 4 * ((size + 2) ~/ 3) + 32;
        if (encodedSize > 32 * 1024 * 1024) {
          throw GatewayError('这组图片超过网关可接收的数据大小');
        }
      }
    }
    if (!current()) return null;
    final references = <String>[];
    final transport = appearance.attachmentTransport;
    final count = documentInputs.length + photoInputs.length;
    for (final (index, document) in documentInputs.indexed) {
      control?.throwIfCancelled();
      final progress = reportUpload(
        document,
        index + 1,
        count,
        current: current,
      );
      progress(preparingUpload);
      final reference = await widget.gateway.attachFile(
        document,
        sessionId: session,
        profile: widget.profile,
        transport: transport,
        progress: progress,
        control: control,
      );
      if (!current()) return null;
      references.add(reference);
    }
    final images = <PromptImage>[];
    final imageReferences = <String>[];
    for (final (index, photo) in photoInputs.indexed) {
      control?.throwIfCancelled();
      final progress = reportUpload(
        photo,
        documentInputs.length + index + 1,
        count,
        current: current,
      );
      progress(preparingUpload);
      final bytes = await photo.readAsBytes();
      final mime = imageMime(bytes);
      final url = 'data:$mime;base64,${await compute(base64Encode, bytes)}';
      control?.throwIfCancelled();
      if (!current()) return null;
      final upload = await widget.gateway.uploadComposerImage(
        url,
        filename: photo.name,
        profile: widget.profile,
        progress: progress,
        control: control,
      );
      if (!current()) return null;
      final path = upload['path'];
      if (path is! String ||
          path.isEmpty ||
          path.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw GatewayError('网关未返回原图路径');
      }
      final quote = path.contains(RegExp(r'\s'))
          ? ['"', "'", '`'].where((value) => !path.contains(value)).firstOrNull
          : '';
      if (quote == null) throw GatewayError('网关未返回原图路径');
      imageReferences.add('@image:$quote$path$quote');
      images.add((
        path: path,
        mime: upload['mime_type'] as String? ?? mime,
        dataUrl: canonical ? null : url,
      ));
    }
    final body = composeAttachedPrompt(caption, references, imageReferences);
    final params = widget.gateway.promptParams(
      session,
      widget.profile,
      body,
      images: images,
    );
    if (queuedId != null) params['queued'] = true;
    final retainedId = queuedId ?? submissionId;
    if (widget.gateway.canonical && retainedId != null) {
      params['submission_id'] = retainedId;
    }
    return (body, params);
  }

  Future<void> syncFollowupQueue(Json snapshot, List<Json> history) async {
    final store = queueStore;
    if (store == null) return;
    final remote = widget.gateway.canonical
        ? RemoteFollowup.parse(snapshot['pending'])
        : const <RemoteFollowup>[];
    try {
      var entries = await store.read();
      if (!mounted) return;
      await clearSubmittedComposer(
        entries.expand((entry) => entry.composerInputs),
      );
      if (!mounted) return;
      if (draftStamp != null &&
          entries.any(
            (entry) =>
                entry.draftStamp == draftStamp &&
                entry.text == draft.text.trim(),
          )) {
        draft.clear();
      }
      final confirmed = admittedSubmissionIds(snapshot, history);
      for (final row in entries.where((row) => row.request != null)) {
        if (confirmed.contains(row.id) ||
            await submissionCompletionFromReplay(snapshot, row) != null) {
          entries = await store.remove(row.id, allowStaged: true);
        }
      }
      if (!mounted) return;
      updateSlash(() {
        if (remote != null) remoteFollowups = remote;
        followups = entries;
        queueLoaded = true;
        queueError = null;
      });
    } catch (e) {
      if (mounted) updateSlash(() => queueError = '无法读取待发送消息');
    }
  }

  Future<void> enqueueFollowup(
    String original,
    List<XFile> documents,
    List<XFile> photos,
  ) async {
    final store = queueStore;
    if (store == null) return;
    updateSlash(() => busy = true);
    try {
      final QueuedSkill? skill;
      try {
        skill = await queuedSkill(
          original,
          hasAttachments: documents.isNotEmpty || photos.isNotEmpty,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(context.tr(e.toString()))));
        }
        return;
      }
      if (!mounted) return;
      final entries = await store.add(
        original.trim(),
        documents,
        null,
        pictures: photos,
        skill: skill,
        draftStamp: draft.text == original ? draftStamp : null,
        composerInputs: composerInputIds(documents, photos),
      );
      if (!mounted) return;
      await clearSubmittedComposer(
        const [],
        documents: documents,
        photos: photos,
      );
      if (!mounted) return;
      if (draft.text == original) draft.clear();
      updateSlash(() {
        followups = entries;
        queueLoaded = true;
        queueError = null;
        error = null;
      });
    } catch (e) {
      if (mounted) updateSlash(() => queueError = e.toString());
    } finally {
      if (mounted) {
        updateSlash(() => busy = false);
        scheduleFollowupDrain();
      }
    }
  }

  Future<QueuedSkill?> queuedSkill(
    String text, {
    required bool hasAttachments,
    QueuedSkill? previous,
  }) async {
    if (!text.trimLeft().startsWith('/')) return null;
    final skill = await skillForQueue(text, previous: previous);
    if (skill == null && !hasAttachments) {
      throw GatewayError('当前回复结束后可运行此命令');
    }
    return skill;
  }

  Future<({String prompt, String display})?> prepareQueuedSkill(
    String runtime,
    FollowupDraft entry, {
    required bool Function() stillAttached,
  }) async {
    final skill = entry.skill!;
    final service = SlashService(widget.gateway, widget.profile, runtime);
    try {
      final active = (await service.catalog()).entries[skill.name];
      if (!stillAttached()) return null;
      if (active == null || !active.skill) {
        throw GatewayError('当前会话里已找不到这项技能');
      }
      final directive = await service.run(active, skill.argument);
      return stillAttached() ? directive.promptFor(entry.text) : null;
    } catch (_) {
      if (!stillAttached()) return null;
      rethrow;
    }
  }

  void scheduleFollowupDrain() {
    scheduleTurnCheck();
    if (!queueCanDrain ||
        error != null ||
        queueError != null ||
        followups.isEmpty ||
        followups.first.uploadPaused ||
        followups.first.request != null) {
      return;
    }
    unawaited(drainFollowup());
  }

  Future<void> drainFollowup({bool retry = false}) async {
    if (!queueCanDrain || followups.isEmpty) return;
    final store = queueStore;
    if (store == null) return;
    final existing = store.currentDrain;
    if (existing != null) {
      updateSlash(() => queueDraining = true);
      try {
        await existing;
        final refreshed = await store.read();
        if (mounted) updateSlash(() => followups = refreshed);
      } catch (_) {
        if (mounted) updateSlash(() => queueError = '无法读取待发送消息');
      } finally {
        if (mounted) {
          updateSlash(() => queueDraining = false);
          scheduleFollowupDrain();
        }
      }
      return;
    }
    final current = followups.first;
    final session = runtime!;
    final revision = linkRevision;
    bool readyToSubmit() =>
        mounted &&
        linkRevision == revision &&
        runtime == session &&
        gatewayReady &&
        !running;
    if (current.request != null && (!retry || !canRetryFollowup(current))) {
      return;
    }
    if (current.uploadPaused && !retry) return;
    updateSlash(() {
      queueDraining = true;
      queueError = null;
      if (retry) error = null;
    });
    FileTransferControl? control;
    try {
      await store.drainOnce(() async {
        final entries = await store.read();
        final saved = entries.firstOrNull;
        if (!readyToSubmit()) return;
        if (saved == null || saved.id != current.id) {
          updateSlash(() => followups = entries);
          return;
        }
        if (saved.uploadPaused && !retry) return;
        final active = saved.uploadPaused
            ? await store.setUploadPaused(saved.id, false)
            : entries;
        final head = active.firstOrNull;
        if (!readyToSubmit() || head == null || head.id != current.id) return;
        if (saved.uploadPaused) updateSlash(() => followups = active);
        var request = head.request;
        var display = head.display ?? head.text;
        if (request == null) {
          final expanded = head.skill == null
              ? null
              : await prepareQueuedSkill(
                  session,
                  head,
                  stillAttached: readyToSubmit,
                );
          if (head.skill != null && expanded == null) return;
          final documents = await Future.wait(
            head.files.map((file) => store.source(head.id, file)),
          );
          final photos = await Future.wait(
            head.pictures.map((file) => store.source(head.id, file)),
          );
          if (!readyToSubmit()) return;
          control = beginUpload(documents, photos);
          final (String, Json)? prepared;
          try {
            prepared = await prepareOutbound(
              session,
              expanded?.prompt ?? head.text,
              documents,
              photos,
              queuedId: head.id,
              control: control,
            );
            control?.throwIfCancelled();
          } on FileTransferCancelled {
            // A second view may read the queue as soon as this drain unlocks.
            final List<FollowupDraft> paused;
            try {
              paused = await store.setUploadPaused(head.id, true);
            } catch (_) {
              throw GatewayError('无法保存上传暂停状态');
            }
            if (mounted) {
              updateSlash(() {
                followups = paused;
                queueError = '已取消上传';
              });
            }
            return;
          }
          endUpload(control);
          if (!readyToSubmit() || prepared == null) return;
          final (body, params) = prepared;
          request = params;
          display = expanded == null
              ? body
              : body.replaceFirst(expanded.prompt, expanded.display);
          final recorded = await store.stage(
            head,
            widget.gateway.canonical
                ? request
                : {'session_id': session, 'queued': true},
            display: expanded == null ? null : display,
            cursor: widget.gateway.canonical
                ? (epoch: sessionEpoch, sequence: seq)
                : null,
          );
          if (!readyToSubmit()) {
            final restored = await store.unstage(head.id);
            if (mounted) updateSlash(() => followups = restored);
            return;
          }
          updateSlash(() => followups = recorded);
        } else if (!retry || !canRetryFollowup(head)) {
          updateSlash(() => followups = entries);
          return;
        } else if (head.display == null) {
          if (request['text'] case final String body) display = body;
        }
        if (!readyToSubmit()) return;
        late final ChatRow echo;
        updateSlash(() => echo = addPendingEcho(display));
        final Json result;
        try {
          result = await widget.gateway.call('prompt.submit', request);
          if (!acceptedSubmission(result, request)) {
            throw GatewayError('网关未返回发送确认');
          }
        } catch (_) {
          if (mounted) updateSlash(() => removePendingEcho(echo));
          rethrow;
        }
        final queued = result['status'] == 'queued';
        if (mounted &&
            (queued ||
                result['status'] == 'terminal' ||
                result['voice_stopped'] == true)) {
          updateSlash(() {
            final removed = removePendingEcho(echo);
            if (queued && widget.gateway.canonical) {
              recordRemoteFollowup(result, display);
            } else if (queued && removed) {
              running = true;
            }
          });
        }
        final remaining = await store.remove(head.id, allowStaged: true);
        if (mounted) updateSlash(() => followups = remaining);
      });
    } catch (e) {
      final refreshed = await store.read().catchError((_) => followups);
      if (mounted) {
        updateSlash(() {
          queueError = e.toString();
          followups = refreshed;
        });
      }
    } finally {
      if (mounted) {
        endUpload(control);
        updateSlash(() => queueDraining = false);
        scheduleFollowupDrain();
      }
    }
  }

  bool canRetryFollowup(FollowupDraft entry) =>
      entry.request == null ||
      widget.gateway.canonical &&
          entry.request?['submission_id'] == entry.id &&
          entry.request?['session_id'] == runtime;

  void recordRemoteFollowup(Json receipt, String display) {
    final entry = RemoteFollowup({...receipt, 'text': display});
    if (entry.id.isEmpty || remoteFollowups.any((row) => row.id == entry.id)) {
      return;
    }
    remoteFollowups = [...remoteFollowups, entry]
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
  }

  Future<String?> askFollowupText(
    String original, {
    List<FollowupFile> attachments = const [],
  }) {
    var edited = original;
    return showDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setEditorState) {
          final theme = Theme.of(context);
          final canSave =
              edited != original &&
              (edited.isNotEmpty || attachments.isNotEmpty);
          return AlertDialog(
            scrollable: true,
            title: Text(context.tr('编辑待发送消息')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  initialValue: original,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 7,
                  onChanged: (text) =>
                      setEditorState(() => edited = text.trim()),
                  decoration: InputDecoration(hintText: context.tr('输入消息…')),
                ),
                if (attachments.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    context.strings.format('附件 {count} 个', {
                      'count': attachments.length,
                    }),
                    style: theme.textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  for (final attachment in attachments)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.attach_file_rounded,
                            size: 15,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              attachment.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(context.tr('取消')),
              ),
              FilledButton(
                onPressed: canSave ? () => Navigator.pop(dialog, edited) : null,
                child: Text(context.tr('保存')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> handleLocalFollowup(
    FollowupDraft entry,
    _QueueAction action,
  ) async {
    final store = queueStore;
    if (store == null) return;
    if (action == _QueueAction.check) {
      await requestSessionRecovery();
      return;
    }
    if (action == _QueueAction.retry) {
      await drainFollowup(retry: true);
      return;
    }
    if (queueEditing || queueDraining || store.currentDrain != null) return;
    updateSlash(() => queueEditing = true);
    try {
      final List<FollowupDraft> entries;
      if (action == _QueueAction.edit) {
        final updated = await askFollowupText(
          entry.text,
          attachments: [...entry.pictures, ...entry.files],
        );
        if (!mounted || updated == null || updated == entry.text) return;
        final QueuedSkill? skill;
        try {
          skill = await queuedSkill(
            updated,
            hasAttachments: entry.attachmentCount > 0,
            previous: entry.skill,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(context.tr(e.toString()))));
          }
          return;
        }
        if (!mounted) return;
        entries = await store.edit(entry.id, updated, skill: skill);
      } else {
        if (action == _QueueAction.discard) {
          final discard = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              title: Text(context.tr('移除待确认记录？')),
              content: Text(context.tr('如果网关已经收到消息，它仍会出现在会话里。')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: Text(context.tr('取消')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: Text(context.tr('移除')),
                ),
              ],
            ),
          );
          if (!mounted || discard != true) return;
        }
        entries = await store.remove(
          entry.id,
          allowStaged: action == _QueueAction.discard,
        );
      }
      if (mounted) {
        updateSlash(() {
          followups = entries;
          queueError = null;
        });
      }
    } catch (e) {
      if (mounted) updateSlash(() => queueError = e.toString());
    } finally {
      if (mounted) {
        updateSlash(() => queueEditing = false);
        scheduleFollowupDrain();
      }
    }
  }

  Future<void> handleRemoteFollowup(
    RemoteFollowup entry,
    _QueueAction action,
  ) async {
    final sid = runtime;
    if (sid == null || !gatewayReady || !queueActions.add(entry.id)) return;
    updateSlash(() {});
    try {
      final text = action == _QueueAction.edit
          ? await askFollowupText(entry.text)
          : null;
      if (!mounted || runtime != sid || !gatewayReady) return;
      if (action == _QueueAction.edit && (text == null || text == entry.text)) {
        return;
      }
      final result = await widget.gateway.call(
        text == null ? 'prompt.cancel' : 'prompt.replace_queued',
        {
          'session_id': sid,
          'profile': widget.profile,
          'admission_id': entry.id,
          if (text != null) ...{
            'submission_id': const Uuid().v4(),
            'text': text,
          },
        },
      );
      if (!mounted) return;
      updateSlash(() {
        remoteFollowups = remoteFollowups
            .where((row) => row.id != entry.id)
            .toList();
        if (text != null && result['status'] == 'queued') {
          recordRemoteFollowup(result, text);
        }
        queueError = null;
      });
      await requestSessionRecovery();
    } catch (e) {
      if (mounted) updateSlash(() => queueError = e.toString());
    } finally {
      if (mounted) updateSlash(() => queueActions.remove(entry.id));
    }
  }

  Widget followupPanel() {
    final total = followups.length + remoteFollowups.length;
    if (total == 0 && queueError == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 2),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (total > 0)
              TextButton(
                onPressed: () =>
                    updateSlash(() => queueExpanded = !queueExpanded),
                style: TextButton.styleFrom(
                  foregroundColor: colors.onSurface,
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  minimumSize: const Size(0, 44),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.schedule_rounded, size: 17),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        queueDraining
                            ? context.tr('正在处理待发送消息')
                            : context.strings.format('待发送 {total} 条', {
                                "total": total,
                              }),
                      ),
                    ),
                    Icon(
                      queueExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                  ],
                ),
              ),
            if (queueError case final message?)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  context.tr(message),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: colors.error),
                ),
              ),
            if (!queueLoaded && queueError != null)
              TextButton(
                onPressed: () => syncFollowupQueue({}, const []),
                child: Text(context.tr('重新读取队列')),
              ),
            if (queueExpanded &&
                total > 0 &&
                MediaQuery.viewInsetsOf(context).bottom == 0)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 175),
                child: ListView(
                  primary: false,
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 4),
                  children: [
                    for (final entry in remoteFollowups)
                      remoteFollowupRow(entry),
                    for (final entry in followups) localFollowupRow(entry),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget localFollowupRow(FollowupDraft entry) {
    final photos = entry.attachmentCount;
    final staged = entry.request != null;
    return ListTile(
      key: ValueKey(entry.id),
      dense: true,
      title: Text(
        entry.text.isEmpty ? context.tr('附件') : entry.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (entry.skill != null) context.tr('技能'),
          if (photos > 0)
            context.strings.format('附件 {count} 个', {'count': photos}),
          context.tr(
            staged
                ? '发送结果待确认'
                : entry.uploadPaused
                ? '已暂停上传'
                : '等待当前回复结束',
          ),
        ].join(' · '),
      ),
      trailing: PopupMenuButton<_QueueAction>(
        tooltip: context.tr('待发送消息操作'),
        enabled: !queueDraining && !queueEditing,
        onSelected: (action) => handleLocalFollowup(entry, action),
        itemBuilder: (_) => [
          if (staged && gatewayReady)
            PopupMenuItem(
              value: _QueueAction.check,
              child: Text(context.tr('核对会话')),
            ),
          if (followups.first.id == entry.id &&
              canRetryFollowup(entry) &&
              queueCanDrain &&
              (staged ||
                  entry.uploadPaused ||
                  queueError != null ||
                  error != null))
            PopupMenuItem(
              value: _QueueAction.retry,
              child: Text(context.tr('重试')),
            ),
          if (!staged) ...[
            PopupMenuItem(
              value: _QueueAction.edit,
              child: Text(context.tr('编辑')),
            ),
            PopupMenuItem(
              value: _QueueAction.withdraw,
              child: Text(context.tr('撤回')),
            ),
          ] else
            PopupMenuItem(
              value: _QueueAction.discard,
              child: Text(context.tr('移除记录')),
            ),
        ],
      ),
    );
  }

  Widget remoteFollowupRow(RemoteFollowup entry) => ListTile(
    key: ValueKey(entry.id),
    dense: true,
    title: Text(entry.text, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(context.tr('已在网关排队')),
    trailing: PopupMenuButton<_QueueAction>(
      tooltip: context.tr('网关排队消息操作'),
      enabled:
          widget.gateway.canonical &&
          gatewayReady &&
          !queueActions.contains(entry.id),
      onSelected: (action) => handleRemoteFollowup(entry, action),
      itemBuilder: (_) => [
        if (entry.canReplace)
          PopupMenuItem(
            value: _QueueAction.edit,
            child: Text(context.tr('编辑')),
          ),
        PopupMenuItem(
          value: _QueueAction.withdraw,
          child: Text(context.tr('撤回')),
        ),
      ],
    ),
  );
}
