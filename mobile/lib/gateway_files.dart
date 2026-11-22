part of 'gateway.dart';

class FileTransferCancelled implements Exception {
  const FileTransferCancelled();
}

class FileTransferControl {
  bool _cancelled = false;
  void Function()? _stop;
  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _stop?.call();
  }

  void _follow(void Function()? stop) {
    _stop = stop;
    if (_cancelled) stop?.call();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const FileTransferCancelled();
  }

  Future<T> _waitFor<T>(Future<T> work, {void Function()? stop}) async {
    final cancelled = Completer<T>();
    final result = Future.any([work, cancelled.future]);
    _follow(() {
      stop?.call();
      cancelled.completeError(const FileTransferCancelled());
    });
    try {
      return await result;
    } finally {
      _follow(null);
    }
  }
}

typedef FileTransferProgress = void Function(int received, int? total);

enum UploadPhase { preparing, sending, confirming }

enum AttachmentTransport { automatic, base64 }

typedef UploadProgress = ({UploadPhase phase, int? sent, int? total});
typedef UploadProgressCallback = void Function(UploadProgress progress);

const preparingUpload = (phase: UploadPhase.preparing, sent: null, total: null);

class _UploadReporter {
  _UploadReporter(this.callback);

  final UploadProgressCallback? callback;
  final Stopwatch _clock = Stopwatch()..start();

  void sending(int sent, int total) {
    if (callback == null || sent != 0 && _clock.elapsedMilliseconds < 100) {
      return;
    }
    _clock.reset();
    callback!((phase: UploadPhase.sending, sent: sent, total: total));
  }

  void confirming([int? total]) => callback?.call((
    phase: UploadPhase.confirming,
    sent: total,
    total: total,
  ));
}

String attachmentName(XFile file) {
  final name = file.name
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[\x00-\x1f]'), '_')
      .trim();
  return name.isEmpty ? '附件' : name;
}

Future<void> _encodeAttachmentInBackground((XFile, SendPort) input) async {
  final (file, reply) = input;
  final encoded = await file
      .openRead()
      .cast<List<int>>()
      .transform(base64.encoder)
      .join();
  Isolate.exit(reply, encoded);
}

Future<String> _encodeAttachment(
  XFile file,
  FileTransferControl? control,
) async {
  final port = ReceivePort();
  final reply = Completer<String>();
  // The worker can finish or be cancelled before spawn returns its isolate.
  reply.future.ignore();
  final listener = port.listen((message) {
    if (reply.isCompleted) return;
    if (message is String) {
      reply.complete(message);
    } else {
      reply.completeError(GatewayError('无法读取附件'));
    }
  });
  Isolate? worker;
  try {
    control?._follow(() {
      worker?.kill(priority: Isolate.immediate);
      if (!reply.isCompleted)
        reply.completeError(const FileTransferCancelled());
    });
    control?.throwIfCancelled();
    worker = await Isolate.spawn(
      _encodeAttachmentInBackground,
      (file, port.sendPort),
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    control?.throwIfCancelled();
    return await reply.future;
  } finally {
    control?._follow(null);
    worker?.kill(priority: Isolate.immediate);
    await listener.cancel();
    port.close();
  }
}

extension GatewayFiles on Gateway {
  Future<Json?> _stageFile(
    XFile file,
    String profile, {
    required bool canonical,
    required _UploadReporter report,
    FileTransferControl? control,
  }) async {
    const timeout = Duration(minutes: 5);
    final boundary = 'hermes-${const Uuid().v4()}';
    // A chosen filename is metadata, never a multipart header or server path.
    final name = attachmentName(file).replaceAll(RegExp(r'[\r\n"\\\x00]'), '_');
    final start = utf8.encode(
      '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$name"\r\n'
      'Content-Type: application/octet-stream\r\n\r\n',
    );
    final end = ascii.encode('\r\n--$boundary--\r\n');
    final length = await file.length();
    try {
      return await _postUpload(
        'api/chat/file-upload',
        profile: profile,
        contentType: ContentType(
          'multipart',
          'form-data',
          parameters: {'boundary': boundary},
        ),
        content: file.openRead(),
        length: length,
        prefix: start,
        suffix: end,
        timeout: timeout,
        report: report,
        control: control,
      );
    } on GatewayError catch (e) {
      if ({404, 405, 501}.contains(e.status)) return null;
      if (e.status == 413) {
        if (!canonical) return null;
        throw GatewayError('附件超过网关允许的大小', 413);
      }
      rethrow;
    }
  }

  Future<Json> _postUpload(
    String endpoint, {
    required String profile,
    required ContentType contentType,
    required Stream<List<int>> content,
    required int length,
    List<int> prefix = const [],
    List<int> suffix = const [],
    required Duration timeout,
    required _UploadReporter report,
    FileTransferControl? control,
  }) async {
    control?.throwIfCancelled();
    await _ensureFreshSession();
    control?.throwIfCancelled();
    final request = await _openHttp('POST', endpoint, {'profile': profile});
    try {
      control?._follow(() => request.abort(const FileTransferCancelled()));
      control?.throwIfCancelled();
      request.headers.contentType = contentType;
      request.contentLength = prefix.length + length + suffix.length;
      request.add(prefix);
      report.sending(0, length);
      var sent = 0;
      await request
          .addStream(
            content.map((chunk) {
              sent += chunk.length;
              report.sending(sent, length);
              return chunk;
            }),
          )
          .timeout(timeout);
      control?.throwIfCancelled();
      request.add(suffix);
      final headers = request.close().timeout(timeout);
      report.confirming(length);
      final response = await _checked(await headers, timeout);
      final chunks = StreamIterator(
        response.transform(utf8.decoder).timeout(timeout),
      );
      control?._follow(
        () => unawaited(chunks.cancel().catchError((Object _) {})),
      );
      final body = StringBuffer();
      try {
        while (await chunks.moveNext()) {
          control?.throwIfCancelled();
          body.write(chunks.current);
        }
        control?.throwIfCancelled();
        return jsonDecode(body.toString()) as Json;
      } finally {
        await chunks.cancel();
      }
    } catch (_) {
      request.abort();
      control?.throwIfCancelled();
      rethrow;
    } finally {
      control?._follow(null);
    }
  }

  Future<Json> uploadComposerImage(
    String dataUrl, {
    required String filename,
    required String profile,
    UploadProgressCallback? progress,
    FileTransferControl? control,
  }) async {
    control?.throwIfCancelled();
    final json = await Isolate.run(
      () =>
          utf8.encode(jsonEncode({'filename': filename, 'data_url': dataUrl})),
    );

    Stream<List<int>> chunks() async* {
      const blockSize = 64 * 1024;
      for (var offset = 0; offset < json.length; offset += blockSize) {
        final end = (offset + blockSize).clamp(0, json.length);
        yield Uint8List.sublistView(json, offset, end);
      }
    }

    return _postUpload(
      'api/chat/image-upload',
      profile: profile,
      contentType: ContentType.json,
      content: chunks(),
      length: json.length,
      timeout: const Duration(seconds: 30),
      report: _UploadReporter(progress),
      control: control,
    );
  }

  Future<String> attachFile(
    XFile file, {
    required String sessionId,
    required String profile,
    AttachmentTransport transport = AttachmentTransport.automatic,
    UploadProgressCallback? progress,
    FileTransferControl? control,
  }) async {
    final socket = _socket;
    if (closed || link != GatewayLink.online || socket == null) {
      throw GatewayDisconnected();
    }
    final canonical = this.canonical;
    final report = _UploadReporter(progress);
    final staged = transport == AttachmentTransport.automatic
        ? await _stageFile(
            file,
            profile,
            canonical: canonical,
            report: report,
            control: control,
          )
        : null;
    control?.throwIfCancelled();
    if (!identical(_socket, socket)) throw GatewayDisconnected();
    final path = staged?['path'];
    final receipt = staged?['staged_upload'];
    final scope = {
      'session_id': sessionId,
      'profile': profile,
      'name': attachmentName(file),
    };
    final Json response;
    if (path is String && path.isNotEmpty) {
      response = await _rpc(
        socket,
        'file.attach',
        {
          ...scope,
          if (canonical && receipt is Json)
            'staged_upload': receipt
          else
            'path': path,
        },
        const Duration(seconds: 45),
        control: control,
      );
    } else if (staged == null) {
      progress?.call(preparingUpload);
      final encoded = await _encodeAttachment(file, control);
      response = await _rpc(
        socket,
        'file.attach',
        {...scope, 'data_url': 'data:application/octet-stream;base64,$encoded'},
        const Duration(minutes: 5),
        backgroundEncode: true,
        onDispatched: report.confirming,
        control: control,
      );
    } else {
      throw GatewayError('网关未返回上传文件的位置');
    }
    final ref = response['ref_text'];
    if (response['attached'] != true ||
        ref is! String ||
        !ref.startsWith('@file:') ||
        ref.contains('\n') ||
        ref.contains('\r')) {
      throw GatewayError('网关未返回附件引用');
    }
    return ref;
  }

  Future<void> downloadFile(
    String remotePath,
    File destination, {
    String? sessionId,
    required String profile,
    int? maxBytes,
    FileTransferControl? control,
    FileTransferProgress? progress,
  }) async {
    const timeout = Duration(seconds: 30);
    await _ensureFreshSession();
    control?.throwIfCancelled();
    final request = await _openHttp('GET', 'api/fs/download', {
      'path': remotePath,
      'session_id': ?sessionId,
      'profile': profile,
    });
    try {
      final headers = request.close().timeout(timeout);
      control?._follow(() => request.abort(const FileTransferCancelled()));
      final response = await _checked(await headers, timeout);
      final total =
          response.contentLength >= 0 &&
              response.compressionState !=
                  HttpClientResponseCompressionState.decompressed
          ? response.contentLength
          : null;
      final source = StreamIterator(response.timeout(timeout));
      var reading = false;
      Future<void>? stopping;
      Future<void> cancelStream() => stopping ??= reading
          ? source.cancel().then<void>((_) {})
          : response.listen(null).cancel();
      control?._follow(
        () => unawaited(cancelStream().catchError((Object _) {})),
      );
      try {
        control?.throwIfCancelled();
        if (maxBytes != null && total != null && total > maxBytes) {
          throw GatewayError('文件超过预览大小限制，请下载查看');
        }
        progress?.call(0, total);
        final output = await destination.open(mode: FileMode.write);
        var received = 0;
        try {
          control?.throwIfCancelled();
          reading = true;
          while (await source.moveNext()) {
            control?.throwIfCancelled();
            final chunk = source.current;
            received += chunk.length;
            if (maxBytes != null && received > maxBytes) {
              throw GatewayError('文件超过预览大小限制，请下载查看');
            }
            await output.writeFrom(chunk);
            progress?.call(received, total);
          }
          control?.throwIfCancelled();
        } finally {
          await output.close();
        }
      } finally {
        await cancelStream();
      }
    } catch (_) {
      request.abort();
      if (await destination.exists()) await destination.delete();
      rethrow;
    } finally {
      control?._stop = null;
    }
  }
}
