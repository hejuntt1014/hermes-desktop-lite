import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import 'protocol.dart';
import 'history.dart';

part 'gateway_files.dart';

typedef Json = Map<String, dynamic>;
typedef PromptImage = ({String path, String? mime, String? dataUrl});

Future<dynamic> _decodeResponseJson(Uint8List data) =>
    Isolate.run(() => jsonDecode(utf8.decode(data)));

enum GatewayLink { idle, online, reconnecting, offline, signIn }

class GatewayError implements Exception {
  GatewayError(this.message, [this.status]) : code = null, data = null;
  GatewayError.rpc(this.message, this.code, this.data) : status = null;
  final int? code;
  final Json? data;
  final int? status;
  final String message;
  @override
  String toString() => message;
}

class GatewayDisconnected extends GatewayError {
  GatewayDisconnected() : super('网关连接中断');
}

class GatewayResponseTooLarge extends GatewayError {
  GatewayResponseTooLarge() : super('网关返回的内容过大');
}

class Gateway {
  Gateway(String address, this.token, {this._browserSuccessText})
    : base = parseAddress(address);
  final Uri base;
  final String token;
  final String Function()? _browserSuccessText;
  static const _loginBrowser = MethodChannel('hermes_lite/login_browser');
  Json? session;
  Future<void> Function(Json session)? onSession;
  Future<void>? _refreshing;
  void Function()? _abortLogin;

  Future<void> _accept(Json reply) async {
    if (reply['access_token'] is! String) throw GatewayError('网关未返回登录凭据');
    final next = {
      for (final k in [
        'access_token',
        'refresh_token',
        'expires_at',
        'provider',
      ])
        k: reply[k],
    };
    session = next;
    await onSession?.call(next);
  }

  Future<void> _refresh() async {
    if ((session?['refresh_token'] as String?)?.isNotEmpty != true) {
      throw GatewayError('登录已过期，请重新登录', 401);
    }
    final reply = await _request(
      'auth/native/refresh',
      body: {
        'refresh_token': session!['refresh_token'],
        'provider': session!['provider'] ?? '',
      },
    );
    await _accept(reply as Json);
  }

  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final _events = StreamController<Json>.broadcast();
  Completer<void>? _socketReady;
  final _pending = <int, Completer<Json>>{};
  WebSocket? _socket;
  int _sequence = 0;
  GatewayLink link = GatewayLink.idle;
  int _connectionRevision = 0;
  int get connectionRevision => _connectionRevision;
  String replayEpoch = '';
  Future<void>? _connecting;
  Timer? _retryTimer;
  ({WebSocket socket, Future<void> check})? _foregroundProbe;
  bool _everOnline = false;
  bool _retryUntilFirstConnection = false;
  int _failures = 0;
  bool get usable => link == GatewayLink.online || link == GatewayLink.idle;
  bool canonical = false;
  bool changeEvents = false;
  bool clarifyBatch = false;
  String? version;
  final _interactions = <Object, Json>{};

  Iterable<Json> get pendingInteractionRequests => _interactions.values;

  void rememberInteractionRequest(Json frame) {
    final id = frame['id'];
    if ((id is int || id is String) &&
        {'approval', 'clarify'}.contains(frame['method']) &&
        frame['params'] is Json) {
      _interactions[id] = frame;
    }
  }

  void replyToInteraction(Object id, Json result) {
    if (closed ||
        link != GatewayLink.online ||
        _socket?.readyState != WebSocket.open ||
        !_interactions.containsKey(id)) {
      throw GatewayError('这个交互请求已结束');
    }
    _socket!.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
    _interactions.remove(id);
  }

  bool closed = false;
  Stream<Json> get events => _events.stream;

  static Uri parseAddress(String value) {
    final text = value.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'http://$text');
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw GatewayError('请输入有效的网关地址');
    }
    return uri.replace(path: uri.path.replaceFirst(RegExp(r'/*$'), '/'));
  }

  Future<Json> api(
    String path, {
    Map<String, String>? query,
    Json? body,
    String? method,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await _ensureFreshSession();
    return await _request(
      path,
      query: query,
      body: body,
      method: method,
      timeout: timeout,
    ) as Json;
  }

  Future<Json> audio(String route, String profile, Json body) async {
    await _ensureFreshSession();
    final reply = await _request(
      'api/audio/$route',
      query: {'profile': profile},
      body: body,
      timeout: const Duration(seconds: 90),
      maxResponseBytes: 48 * 1024 * 1024,
    );
    if (reply is! Json) throw GatewayError('语音请求失败');
    return reply;
  }

  Future<List<Json>> apiRows(String path, {Map<String, String>? query}) async {
    await _ensureFreshSession();
    final rows = await _request(path, query: query);
    if (rows is! List) throw GatewayError('网关未返回列表');
    return rows.cast<Json>();
  }

  Future<Json> readConversationPage(
    String path, {
    required Map<String, String> query,
    Duration timeout = const Duration(seconds: 30),
    bool backgroundDecode = false,
    FileTransferControl? control,
    int? maxResponseBytes,
    void Function(int)? onResponseBytes,
  }) async {
    control?.throwIfCancelled();
    final authorized = _ensureFreshSession();
    await (control?._waitFor(authorized) ?? authorized);
    for (var attempt = 0; ; attempt++) {
      control?.throwIfCancelled();
      if (closed) throw GatewayDisconnected();
      try {
        return await _request(
          path,
          query: query,
          timeout: timeout,
          backgroundDecode: backgroundDecode,
          control: control,
          maxResponseBytes: maxResponseBytes,
          onResponseBytes: onResponseBytes,
        ) as Json;
      } on TimeoutException {
        throw GatewayError('网关请求超时');
      } catch (error) {
        if (error is! HttpException && error is! SocketException) rethrow;
        if (attempt != 0 || closed) throw GatewayDisconnected();
        // A pooled connection may close as this read is being sent.
        await Future<void>.delayed(const Duration(milliseconds: 180));
      }
    }
  }

  Future<void> _ensureFreshSession() async {
    final expiry = session?['expires_at'];
    if (expiry is num &&
        expiry <= DateTime.now().millisecondsSinceEpoch / 1000 + 30) {
      await _renewSession();
    }
  }

  Future<void> _renewSession() async {
    final refresh = _refreshing ??= _refresh();
    try {
      await refresh;
    } finally {
      if (identical(refresh, _refreshing)) _refreshing = null;
    }
  }

  Future<HttpClientRequest> _openHttp(
    String method,
    String path,
    Map<String, String>? query,
  ) async {
    final uri = base.resolve(path).replace(queryParameters: query);
    final req = await _http.openUrl(method, uri);
    req.followRedirects = false;
    if (session != null && !path.startsWith('auth/native/')) {
      req.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${session!['access_token']}",
      );
    } else if (token.isNotEmpty) {
      req.headers.set('X-Hermes-Session-Token', token);
    }
    return req;
  }

  Future<HttpClientResponse> _checked(
    HttpClientResponse res,
    Duration timeout, {
    bool closeErrorBody = false,
  }) async {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      if (closeErrorBody) {
        await res.listen(null).cancel();
      } else {
        await res.drain<void>().timeout(timeout);
      }
      throw GatewayError('网关请求失败（HTTP ${res.statusCode}）', res.statusCode);
    }
    return res;
  }

  Future<dynamic> _request(
    String path, {
    Map<String, String>? query,
    Json? body,
    String? method,
    Duration timeout = const Duration(seconds: 30),
    int? maxResponseBytes,
    bool backgroundDecode = false,
    FileTransferControl? control,
    void Function(int)? onResponseBytes,
  }) async {
    final opening = _openHttp(
      method ?? (body == null ? 'GET' : 'POST'),
      path,
      query,
    );
    final req = control == null
        ? await opening
        : await control._waitFor(
            opening.then((request) {
              if (control.cancelled) {
                request.abort(const FileTransferCancelled());
                throw const FileTransferCancelled();
              }
              return request;
            }),
          );
    if (control?.cancelled == true) {
      req.abort(const FileTransferCancelled());
      throw const FileTransferCancelled();
    }
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final headers = req.close().timeout(timeout);
    final response = control == null
        ? await headers
        : await control._waitFor(
            headers.then((response) async {
              if (control.cancelled) {
                await response.listen(null).cancel();
                throw const FileTransferCancelled();
              }
              return response;
            }),
            stop: () => req.abort(const FileTransferCancelled()),
          );
    final res = await _checked(
      response,
      timeout,
      closeErrorBody: control != null,
    );
    if (maxResponseBytes != null && res.contentLength > maxResponseBytes) {
      await res.listen(null).cancel();
      throw GatewayResponseTooLarge();
    }
    if (maxResponseBytes != null ||
        backgroundDecode ||
        control != null ||
        onResponseBytes != null) {
      final bytes = BytesBuilder(copy: false);
      final chunks = StreamIterator(res.timeout(timeout));
      Future<void>? closing;
      Future<void> closeBody() => closing ??= chunks.cancel();
      Future<void> collect() async {
        while (await chunks.moveNext()) {
          control?.throwIfCancelled();
          final chunk = chunks.current;
          if (maxResponseBytes != null &&
              bytes.length + chunk.length > maxResponseBytes) {
            throw GatewayResponseTooLarge();
          }
          bytes.add(chunk);
        }
      }

      try {
        final collecting = collect();
        await (control?._waitFor(
              collecting,
              stop: () {
                unawaited(closeBody().catchError((Object _) {}));
              },
            ) ??
            collecting);
      } finally {
        await closeBody();
      }
      control?.throwIfCancelled();
      final data = bytes.takeBytes();
      onResponseBytes?.call(data.length);
      final decoded = _decodeResponseJson(data);
      return control?._waitFor(decoded) ?? decoded;
    }
    return jsonDecode(
      await res.transform(utf8.decoder).join().timeout(timeout),
    );
  }

  Future<bool> openLoginPage(Uri uri) async {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    final outcome = await _loginBrowser.invokeMethod<String>(
      'open',
      uri.toString(),
    );
    if (outcome == 'cancelled') throw GatewayError('已取消浏览器登录');
    if (Platform.isAndroid && outcome == 'unavailable') {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return outcome == 'closed';
  }

  Future<void> _login() async {
    final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${listener.port}/callback';
    final state = const Uuid().v4();
    final verifier = (const Uuid().v4() + const Uuid().v4()).replaceAll(
      '-',
      '',
    );
    final uri = base
        .resolve('auth/native/authorize')
        .replace(
          queryParameters: {
            'redirect_uri': redirect,
            'state': state,
            'code_challenge_method': 'S256',
            'code_challenge': base64Url
                .encode(sha256.convert(utf8.encode(verifier)).bytes)
                .replaceAll('=', ''),
          },
        );
    final result = Completer<String>();
    listener.listen((req) async {
      final q = req.uri.queryParameters;
      if (req.method == 'GET' &&
          req.uri.path == '/callback' &&
          q['state'] == state &&
          !result.isCompleted) {
        if (q['code']?.isNotEmpty == true) {
          req.response.headers.contentType = ContentType(
            'text',
            'plain',
            charset: 'utf-8',
          );
          req.response.write(
            _browserSuccessText?.call() ?? '可以返回 Hermes Lite。',
          );
          result.complete(q['code']);
        } else {
          result.completeError(GatewayError('登录未获授权'));
        }
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    try {
      if (closed) throw GatewayDisconnected();
      _abortLogin = () {
        if (!result.isCompleted) result.completeError(GatewayDisconnected());
      };
      final browser = () async {
        if (Platform.isAndroid && await _passwordOnlyGateway()) {
          if (closed || result.isCompleted) throw GatewayDisconnected();
          final location = await _loginBrowser.invokeMethod<String>(
            'password',
            uri.toString(),
          );
          if (location == 'cancelled') throw GatewayError('已取消浏览器登录');
          final callback = Uri.tryParse(location ?? '');
          final code = callback?.queryParameters['code'];
          if (callback == null ||
              callback.scheme != 'http' ||
              callback.host != '127.0.0.1' ||
              callback.port != listener.port ||
              callback.path != '/callback' ||
              callback.userInfo.isNotEmpty ||
              callback.queryParameters['state'] != state ||
              code == null ||
              code.isEmpty) {
            throw GatewayError('登录未获授权');
          }
          return code;
        }
        if (closed || result.isCompleted) throw GatewayDisconnected();
        final opened = await openLoginPage(uri);
        if (!opened) throw GatewayError('无法打开登录页面');
        return result.future;
      }();
      final code = await Future.any([result.future, browser]).timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw GatewayError('浏览器登录超时'),
      );
      final reply = await api(
        'auth/native/token',
        body: {'code': code, 'code_verifier': verifier},
      );
      await _accept(reply);
    } finally {
      _abortLogin = null;
      await listener.close(force: true);
      if (Platform.isIOS || Platform.isAndroid) {
        await _loginBrowser.invokeMethod<void>('close', uri.toString());
      }
    }
  }

  Future<bool> _passwordOnlyGateway() async {
    try {
      final info = await _request('api/auth/providers',
          timeout: const Duration(seconds: 5), maxResponseBytes: 65536);
      final providers = info is Json ? info['providers'] : null;
      return providers is List && providers.isNotEmpty &&
          providers.every((p) => p is Json && p['supports_password'] == true);
    } on Exception {
      // Older gateways may only expose the browser authorization endpoint.
      return false;
    }
  }

  Future<void> connect({bool allowBrowser = true}) =>
      _connect(allowBrowser: allowBrowser);

  Future<void> verifyConnection() async {
    final socket = _socket;
    if (closed || socket == null || link != GatewayLink.online) {
      throw link == GatewayLink.signIn
          ? GatewayError('请重新登录网关', 401)
          : GatewayDisconnected();
    }
    try {
      await _rpc(socket, 'ping', {}, const Duration(seconds: 5));
    } on GatewayError catch (failure) {
      if (failure.code != -32601) rethrow;
    }
    await _ensureFreshSession();
    await _request(
      'api/sessions',
      query: {'limit': '1'},
      timeout: const Duration(seconds: 10),
    );
    if (!identical(_socket, socket)) throw GatewayDisconnected();
  }

  Future<void> _connect({required bool allowBrowser}) {
    if (closed) return Future.error(GatewayDisconnected());
    if (link == GatewayLink.online) return Future.value();
    final current = _connecting;
    if (current != null) return current;
    final attempt = _establish(allowBrowser: allowBrowser);
    _connecting = attempt;
    return attempt.whenComplete(() {
      if (identical(_connecting, attempt)) _connecting = null;
    });
  }

  void _link(GatewayLink next, {bool resumed = false}) {
    if (closed || link == next && !resumed) return;
    link = next;
    _connectionRevision++;
    _events.add({
      'type': 'client.connection',
      'payload': {'state': next.name, 'resumed': resumed},
    });
  }

  Future<void> _establish({required bool allowBrowser}) async {
    await _ensureFreshSession();
    Future<dynamic> statusRequest() =>
        _request('api/status', timeout: const Duration(seconds: 10));
    dynamic status;
    try {
      status = await statusRequest();
    } on GatewayError catch (error) {
      if (error.status != 401 || token.isNotEmpty || session == null) rethrow;
      await _renewSession();
      status = await statusRequest();
    }
    final reportedVersion = status['version'];
    if (reportedVersion is String && reportedVersion.isNotEmpty) {
      version = reportedVersion;
    }
    final query = <String, String>{};
    if (token.isEmpty) {
      if (status['auth_required'] == false) {
        throw GatewayError('此网关需要访问令牌', 401);
      }
      if (session == null) {
        if (!allowBrowser) throw GatewayError('请重新登录网关', 401);
        await _login();
      }
      try {
        query['ticket'] =
            (await api('api/auth/ws-ticket', body: {}))['ticket'] as String;
      } on GatewayError catch (e) {
        if (e.status != 401 || session == null) rethrow;
        await _renewSession();
        query['ticket'] =
            (await api('api/auth/ws-ticket', body: {}))['ticket'] as String;
      }
    } else {
      query['token'] = token;
    }
    if (closed) throw GatewayDisconnected();
    final uri = base
        .resolve('api/ws')
        .replace(
          scheme: base.scheme == 'https' ? 'wss' : 'ws',
          queryParameters: query,
        );
    final upstream = WebSocket.connect(uri.toString(), customClient: _http);
    final WebSocket socket;
    try {
      socket = await upstream.timeout(const Duration(seconds: 18));
    } on TimeoutException {
      unawaited(
        upstream.then<void>((late) async {
          await late.close();
        }, onError: (Object _) {}),
      );
      throw GatewayError('无法连接网关 WebSocket');
    } on WebSocketException catch (e) {
      final denied = RegExp(
        r'status code[: ]+(401|403)\b',
        caseSensitive: false,
      ).hasMatch(e.message);
      throw GatewayError('无法连接网关 WebSocket', denied ? 401 : null);
    } catch (_) {
      throw GatewayError('无法连接网关 WebSocket');
    }
    if (closed) {
      unawaited(socket.close());
      throw GatewayDisconnected();
    }
    final ready = Completer<void>();
    final waiting = ready.future.timeout(const Duration(seconds: 18));
    _socket = socket;
    _socketReady = ready;
    canonical = false;
    changeEvents = false;
    clarifyBatch = false;
    replayEpoch = '';
    socket.pingInterval = const Duration(seconds: 20);
    socket.listen(
      (raw) {
        if (identical(_socket, socket)) _frame(raw);
      },
      onDone: () => _socketLost(socket),
      onError: (Object _) => _socketLost(socket),
    );
    try {
      await waiting;
      try {
        final capabilities = await _rpc(socket, 'client.capabilities', {
          'server_requests': true,
        }, const Duration(seconds: 3));
        clarifyBatch =
            canonical && capabilities['canonical_clarify_batch'] == true;
      } on GatewayError {
        if (!identical(_socket, socket)) rethrow;
      } on TimeoutException {
        if (!identical(_socket, socket)) throw GatewayDisconnected();
      }
      if (closed || !identical(_socket, socket)) throw GatewayDisconnected();
      final resumed = _everOnline;
      _everOnline = true;
      _retryUntilFirstConnection = false;
      _failures = 0;
      _link(GatewayLink.online, resumed: resumed);
    } catch (_) {
      if (identical(_socket, socket)) _dropSocket(socket);
      rethrow;
    }
  }

  void _dropSocket(WebSocket socket, [GatewayError? failure]) {
    if (!identical(_socket, socket)) return;
    _socket = null;
    final error = failure ?? GatewayDisconnected();
    final ready = _socketReady;
    _socketReady = null;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    for (final call in _pending.values) {
      if (!call.isCompleted) call.completeError(error);
    }
    _pending.clear();
    _interactions.clear();
    unawaited(socket.close());
  }

  void _socketLost(WebSocket socket) {
    if (closed || !identical(_socket, socket)) return;
    final online = link == GatewayLink.online;
    final denied = {1008, 4401, 4403}.contains(socket.closeCode);
    _dropSocket(socket, denied ? GatewayError('请重新登录网关', 401) : null);
    if (!online) return;
    if (denied) {
      _link(GatewayLink.signIn);
    } else {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (closed) return;
    if (_failures >= 6 && !_retryUntilFirstConnection) {
      _link(GatewayLink.offline);
      return;
    }
    _link(GatewayLink.reconnecting);
    final scale = _failures < 4 ? _failures : 4;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: 1 << scale), _reconnect);
  }

  Future<void> _reconnect() async {
    if (closed ||
        link == GatewayLink.online ||
        link == GatewayLink.signIn ||
        _connecting != null) {
      return;
    }
    _retryTimer?.cancel();
    _link(GatewayLink.reconnecting);
    try {
      await _connect(allowBrowser: false);
    } catch (e) {
      if (closed) return;
      if (e is GatewayError && {401, 403}.contains(e.status)) {
        _link(GatewayLink.signIn);
      } else {
        _failures++;
        _scheduleRetry();
      }
    }
  }

  Future<void> retry({bool restart = false}) async {
    if (closed || link == GatewayLink.signIn || _connecting != null) return;
    _failures = 0;
    final socket = _socket;
    if (restart && link == GatewayLink.online && socket != null) {
      _link(GatewayLink.reconnecting);
      _dropSocket(socket);
    }
    await _reconnect();
  }

  Future<void> restoreSavedConnection() {
    _retryUntilFirstConnection = true;
    return retry();
  }

  Future<void> foreground({Duration backgrounded = Duration.zero}) async {
    if (closed || !_everOnline) return;
    final socket = _socket;
    if (link != GatewayLink.online || socket == null) {
      if (link == GatewayLink.online) _link(GatewayLink.reconnecting);
      await retry();
      return;
    }
    if (_foregroundProbe case final probe?
        when identical(probe.socket, socket)) {
      await probe.check;
      return;
    }
    final timeout = backgrounded >= const Duration(seconds: 40)
        ? const Duration(seconds: 2)
        : const Duration(seconds: 4);
    final check = _checkForegroundSocket(socket, timeout);
    _foregroundProbe = (socket: socket, check: check);
    try {
      await check;
    } finally {
      if (identical(_foregroundProbe?.check, check)) _foregroundProbe = null;
    }
  }

  Future<void> _checkForegroundSocket(
    WebSocket socket,
    Duration timeout,
  ) async {
    try {
      await _rpc(socket, 'ping', {}, timeout);
    } on GatewayDisconnected {
      _socketLost(socket);
      await _reconnect();
    } on TimeoutException {
      _socketLost(socket);
      await _reconnect();
    } on GatewayError {
      // A received RPC error also confirms the transport is responding.
    }
  }

  void _frame(dynamic raw) {
    if (raw is! String || closed) return;
    final dynamic value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (value is! Json) return;
    if (value['method'] == 'event' && value['params'] is Json) {
      final event = value['params'] as Json;
      if (event['type'] == 'gateway.ready') {
        canonical = event['payload']?['session_authority'] == true;
        changeEvents = event['payload']?['change_events'] == true;
        replayEpoch = event['payload']?['replay_epoch'] as String? ?? '';
        final ready = _socketReady;
        if (ready != null && !ready.isCompleted) ready.complete();
      }
      if (event['type'] == 'request.cancel') {
        final payload = event['payload'];
        if (payload is Json) _interactions.remove(payload['id']);
      }
      _events.add(event);
    } else if (value['method'] is String && value['id'] != null) {
      rememberInteractionRequest(value);
      final request = _interactions[value['id']];
      if (request != null) {
        final params = request['params'] as Json;
        _events.add({
          'type': 'client.interaction',
          'session_id': params['session_id'] ?? params['gateway_session_id'],
          'profile': params['profile'],
          'payload': request,
        });
      } else {
        _socket!.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': value['id'],
            'error': {'code': -32601, 'message': 'Unsupported client request'},
          }),
        );
      }
    } else if (value['id'] is int && value['method'] == null) {
      final pending = _pending.remove(value['id']);
      if (pending == null) return;
      if (value['error'] != null) {
        pending.completeError(
          GatewayError.rpc(
            value['error']['message']?.toString() ?? '网关操作失败',
            value['error']['code'] as int?,
            value['error']['data'] is Json
                ? value['error']['data'] as Json
                : null,
          ),
        );
      } else {
        pending.complete(
          value['result'] is Json ? value['result'] as Json : {},
        );
      }
    }
  }

  Future<Json> call(
    String method,
    Json params, {
    Duration timeout = const Duration(seconds: 45),
  }) {
    final socket = _socket;
    if (closed || link != GatewayLink.online || socket == null) {
      return Future.error(GatewayDisconnected());
    }
    return _rpc(socket, method, params, timeout);
  }

  Future<Json> _rpc(
    WebSocket socket,
    String method,
    Json params,
    Duration timeout, {
    bool backgroundEncode = false,
    void Function()? onDispatched,
    FileTransferControl? control,
  }) async {
    control?.throwIfCancelled();
    if (!identical(_socket, socket) || socket.readyState != WebSocket.open) {
      throw GatewayDisconnected();
    }
    final id = ++_sequence;
    final frame = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };
    final encoded = backgroundEncode
        ? await Isolate.run(() => jsonEncode(frame))
        : jsonEncode(frame);
    control?.throwIfCancelled();
    if (!identical(_socket, socket) || socket.readyState != WebSocket.open) {
      throw GatewayDisconnected();
    }
    final pending = _pending[id] = Completer<Json>();
    try {
      try {
        socket.add(encoded);
      } on StateError {
        _pending.remove(id);
        _socketLost(socket);
        throw GatewayDisconnected();
      }
      control?._follow(() {
        if (!pending.isCompleted) {
          pending.completeError(const FileTransferCancelled());
        }
      });
      onDispatched?.call();
      return await pending.future.timeout(timeout);
    } finally {
      control?._follow(null);
      _pending.remove(id);
    }
  }

  Json promptParams(
    String session,
    String profile,
    String text, {
    String? path,
    String? mime,
    String? dataUrl,
    List<PromptImage> images = const [],
  }) {
    final pictures = [
      if (path != null) (path: path, mime: mime, dataUrl: dataUrl),
      ...images,
    ];
    return {
      'session_id': session,
      'profile': profile,
      if (canonical) 'submission_id': const Uuid().v4(),
      if (clarifyBatch) 'clarify_batch': true,
      'text': pictures.isEmpty || canonical
          ? text
          : [
              {'type': 'text', 'text': text},
              for (final picture in pictures)
                {
                  'type': 'image_url',
                  'image_url': {'url': picture.dataUrl},
                },
            ],
      if (pictures.isNotEmpty && canonical)
        'attachments': [
          for (final picture in pictures)
            {'path': picture.path, 'mime': picture.mime},
        ],
    };
  }

  Future<Json> openSession(
    String profile,
    String? id, {
    bool paged = false,
    Json? launch,
  }) {
    final args = sessionParams(
      create: id == null,
      canonical: canonical,
      key: id ?? const Uuid().v4(),
      paged: id != null && paged,
    );
    return call(id == null ? 'session.create' : 'session.resume', {
      ...args,
      if (id == null) ...?launch,
      'profile': profile,
    });
  }

  Future<HistoryPage> historyPage(
    String profile,
    String id,
    int offset, {
    FileTransferControl? control,
  }) async {
    // One overlapping record is needed to join adjacent chat pages.
    for (var size = 80; size > 2; size ~/= 2) {
      try {
        return await _historyPage(
          profile,
          id,
          offset,
          size,
          control: control,
          maxResponseBytes: 8 * 1024 * 1024,
        );
      } on GatewayResponseTooLarge {
        control?.throwIfCancelled();
      }
    }
    return _historyPage(profile, id, offset, 2, control: control);
  }

  Future<HistoryPage> historyTail(String profile, String id) =>
      _historyPage(profile, id, 0, 1, inlineImages: false);

  Future<HistoryPage> _historyPage(
    String profile,
    String id,
    int offset,
    int pageSize, {
    bool inlineImages = true,
    int? maxResponseBytes,
    FileTransferControl? control,
  }) async {
    final page = await readConversationPage(
      'api/sessions/${Uri.encodeComponent(id)}/messages',
      timeout: Duration(seconds: inlineImages ? 30 : 8),
      maxResponseBytes: maxResponseBytes,
      control: control,
      query: {
        'profile': profile,
        'limit': '$pageSize',
        'offset': '$offset',
        'order': 'latest',
        'include_compacted': 'true',
        if (!inlineImages) 'inline_images': 'false',
      },
    );
    final pagination = page['pagination'];
    final rows = page['messages'];
    if (rows is! List ||
        (!inlineImages && rows.length > pageSize) ||
        (page['profile'] != null && page['profile'] != profile) ||
        (pagination is Json &&
            (pagination['offset'] != null && pagination['offset'] != offset ||
                pagination['order'] != null &&
                    pagination['order'] != 'latest'))) {
      throw GatewayError('网关返回的历史页不匹配');
    }
    final limit = pagination is Json
        ? pagination['limit'] as int? ?? pageSize
        : pageSize;
    return HistoryPage(
      sessionId: page['session_id'] as String? ?? id,
      rows: rows.cast<Json>(),
      offset: offset,
      nextOffset: limit > 0 && rows.length >= limit ? offset + limit - 1 : null,
    );
  }

  Future<Json?> mutationSnapshot(String id, String profile) async {
    Json snapshot;
    try {
      snapshot = await api(
        'api/sessions/${Uri.encodeComponent(id)}/mutation-snapshot',
        query: {'profile': profile},
      );
    } on GatewayError catch (e) {
      if ({404, 405, 501}.contains(e.status)) return null;
      rethrow;
    }
    if (snapshot['session_id'] != id ||
        snapshot['exists'] != true ||
        snapshot['runtime_revision'] is! int ||
        snapshot['runtime_generation'] is! int) {
      throw GatewayError('无法读取会话版本');
    }
    return snapshot;
  }

  Future<void> patchSession(String id, String profile, Json changes) async {
    final snapshot = await mutationSnapshot(id, profile);
    await api(
      'api/sessions/${Uri.encodeComponent(id)}',
      method: 'PATCH',
      body: {
        ...changes,
        'profile': profile,
        if (snapshot != null) ...{
          'request_id': const Uuid().v4(),
          'expected_revision': snapshot['runtime_revision'],
          'expected_generation': snapshot['runtime_generation'],
        },
      },
    );
  }

  Future<void> deleteSession(String id, String profile) async {
    final snapshot = await mutationSnapshot(id, profile);
    await api(
      'api/sessions/${Uri.encodeComponent(id)}',
      method: 'DELETE',
      query: {
        'profile': profile,
        if (snapshot != null) ...{
          'request_id': const Uuid().v4(),
          'expected_revision': '${snapshot['runtime_revision']}',
          'expected_generation': '${snapshot['runtime_generation']}',
        },
      },
    );
  }

  void close() {
    if (closed) return;
    closed = true;
    _abortLogin?.call();
    _retryTimer?.cancel();
    if (_socket case final socket?) _dropSocket(socket);
    _http.close(force: true);
    _events.close();
  }
}
