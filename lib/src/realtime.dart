import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'errors.dart';

/// A row change: `insert`, `update` or `delete`, as this subscriber may read it.
///
/// The subscriber's row-level security decides which changes they receive.
class PlexivoChange {
  /// Creates a change of [type] on [table], with the new [record] and the [old] row.
  PlexivoChange(this.type, this.table, this.record, this.old);

  /// Reads a change from a realtime message.
  factory PlexivoChange.fromJson(Map<String, dynamic> j) => PlexivoChange(
        (j['type'] ?? j['event'] ?? '').toString(),
        (j['table'] ?? '').toString(),
        j['record'] == null ? null : Map<String, dynamic>.from(j['record'] as Map),
        j['old'] == null ? null : Map<String, dynamic>.from(j['old'] as Map),
      );

  /// What happened: `insert`, `update` or `delete`.
  final String type;

  /// The table that changed.
  final String table;

  /// The row after the change, or null for a delete.
  final Map<String, dynamic>? record;

  /// The row before the change, when the server sent it; otherwise null.
  final Map<String, dynamic>? old;
}

/// A message broadcast to a room.
class PlexivoBroadcast {
  /// Creates a broadcast named [event] carrying [payload].
  PlexivoBroadcast(this.event, this.payload);

  /// The event name the sender chose, such as `cursor`.
  final String event;

  /// The message the sender attached.
  final Map<String, dynamic> payload;
}

/// Who is in a room: a full list, or the joins and leaves since the last one.
class PlexivoPresence {
  /// Creates a presence update of kind [event] with its [state].
  PlexivoPresence(this.event, this.state);

  /// `presence_state` for everyone present now, or `presence_diff` for joins and leaves.
  final String event;

  /// The presence data, as the server sent it.
  final Map<String, dynamic> state;
}

/// What a realtime channel needs from the client: where to connect, and as whom.
///
/// [PlexivoClient] implements it.
abstract class RealtimeHost {
  /// The database's Data API URL; the socket connects to the same host.
  String get apiUrl;

  /// The project key sent when connecting.
  String get publishableKey;

  /// The signed-in user's access token, or null when signed out.
  ///
  /// Read each time the channel connects or reconnects.
  String? get accessToken;
}

/// Where a [PlexivoRealtimeChannel] is in its life.
enum PlexivoChannelStatus {
  /// Created, not yet subscribed.
  idle,

  /// Connecting and joining for the first time.
  connecting,

  /// Joined: changes, broadcasts and presence are flowing.
  joined,

  /// The connection dropped or the server ended the channel; it is rejoining on its own.
  reconnecting,

  /// The server refused the join (for example `table_not_exposed` or `sign_in_required`); it does not retry.
  refused,

  /// Unsubscribed.
  closed,
}

/// A realtime channel over a WebSocket: row changes, broadcast and presence.
///
/// Create one with [PlexivoClient.channel], then [subscribe]. Topics:
///
/// - `changes:<table>`: row changes you may read, with an optional [filter]
///   such as `status=eq.open`.
/// - `room:<name>`: broadcast and presence for everyone who joins.
///   `room:private:<name>` is for signed-in users only.
/// - `graphql`: live GraphQL queries (see [PlexivoClient.graphqlSubscribe]).
/// - `<table>`: the original per-user starter channel, such as `items`.
///
/// ```dart
/// final feed = db.channel('changes:orders', 'status=eq.open')..subscribe();
/// feed.changes.listen((c) => print('${c.type} ${c.record}'));
/// feed.errors.listen((reason) => print('realtime: $reason'));
///
/// final room = db.channel('room:lobby', null, {'name': 'Asha'})..subscribe();
/// room.on('cursor').listen((p) => print(p['x']));
/// room.presence.listen((p) => print(p.state));
/// await room.ready();
/// room.sendBroadcast('cursor', {'x': 10});
///
/// await feed.unsubscribe();
/// ```
///
/// It works signed out too, where the rows or room allow it. It stays joined
/// by itself: when the connection drops, or the server ends the channel
/// because the access token expired, it refreshes the session if needed and
/// rejoins, retrying after 1, 2, 4, 8, 16, then every 30 seconds. Before the
/// token expires it reconnects with a fresh one. A join the server refuses is
/// reported on [errors] and not retried. Watch [statusChanges] for each step.
class PlexivoRealtimeChannel {
  /// Creates a channel on [topic] (without the `realtime:` prefix).
  ///
  /// Prefer [PlexivoClient.channel]. See [filter], [presenceMeta] and
  /// [clientId]. [refreshSession] renews the signed-in session when its
  /// access token has expired; [PlexivoClient.channel] passes one.
  PlexivoRealtimeChannel(this._host, String topic, {this.filter, this.presenceMeta, this.clientId, Future<Object?> Function()? refreshSession})
      : _topic = 'realtime:$topic',
        _refreshSession = refreshSession;

  final RealtimeHost _host;
  final String _topic;
  final Future<Object?> Function()? _refreshSession;

  /// The row filter for a `changes:<table>` topic, such as `status=eq.open`.
  ///
  /// Null receives every change you may read.
  final String? filter;

  /// What this client shares about itself in a room, such as `{'name': 'Asha'}`.
  ///
  /// Null joins without presence.
  final Map<String, dynamic>? presenceMeta;

  /// An optional id sent as `client_id` when joining; null sends none.
  final String? clientId;

  _Connection? _conn;
  Timer? _reconnect;
  var _active = false;
  var _joined = false;
  var _everJoined = false;
  String? _refusal;
  var _reconnectAttempt = 0;
  var _ref = 1;
  var _status = PlexivoChannelStatus.idle;
  final _joinWaiters = <Completer<void>>[];
  final _graphql = <String, void Function(Map<String, dynamic>)>{};

  final _changes = StreamController<PlexivoChange>.broadcast();
  final _broadcasts = StreamController<PlexivoBroadcast>.broadcast();
  final _presence = StreamController<PlexivoPresence>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _statuses = StreamController<PlexivoChannelStatus>.broadcast();

  /// Row changes on `changes:<table>` and the starter channel.
  Stream<PlexivoChange> get changes => _changes.stream;

  /// Every broadcast in a room. Use [on] for one event.
  Stream<PlexivoBroadcast> get broadcasts => _broadcasts.stream;

  /// Presence updates in a room: who is here, who joined and who left.
  Stream<PlexivoPresence> get presence => _presence.stream;

  /// Join refusals and server notices, as reason codes.
  ///
  /// For example `table_not_exposed`, `sign_in_required` or `token_expired`
  /// (the channel then rejoins with a fresh token by itself).
  Stream<String> get errors => _errors.stream;

  /// Where the channel is now: connecting, joined, reconnecting, refused or closed.
  PlexivoChannelStatus get status => _status;

  /// Each change of [status], as it happens.
  ///
  /// ```dart
  /// feed.statusChanges.listen((s) => setState(() => online = s == PlexivoChannelStatus.joined));
  /// ```
  Stream<PlexivoChannelStatus> get statusChanges => _statuses.stream;

  /// Whether the channel is joined now.
  bool get isJoined => _joined;

  /// The payloads of broadcasts named [event].
  Stream<Map<String, dynamic>> on(String event) => broadcasts.where((b) => b.event == event).map((b) => b.payload);

  void _setStatus(PlexivoChannelStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_statuses.isClosed) _statuses.add(s);
  }

  /// Connects and joins, and returns this channel for chaining.
  ///
  /// Calling it again while subscribed does nothing. Watch [errors] for
  /// refusals and [statusChanges] for reconnects.
  PlexivoRealtimeChannel subscribe() {
    if (_active) return this;
    _active = true;
    _connect();
    return this;
  }

  /// Completes once the channel has joined, at once if it already has.
  ///
  /// If the server refuses the join, it completes with a [PlexivoException]
  /// whose `code` is the reason (`table_not_exposed`, `sign_in_required`), and
  /// [errors] reports the reason too.
  Future<void> ready() {
    if (_joined) return Future.value();
    final refused = _refusal;
    if (refused != null) return Future.error(_refused(refused));
    final c = Completer<void>();
    _joinWaiters.add(c);
    return c.future;
  }

  PlexivoException _refused(String reason) => PlexivoException(403, reason, message: 'Realtime refused to join $_topic: $reason');

  /// Drops the current connection and lets the channel reconnect and rejoin, as after a network drop.
  ///
  /// Useful when the device changes network or the app returns from the
  /// background. Does nothing when not subscribed.
  void reconnect() {
    final c = _conn;
    if (c == null) return;
    c.ws.sink.close();
  }

  Future<void> _connect() async {
    if (!_active || _refusal != null) return;
    _setStatus(_everJoined ? PlexivoChannelStatus.reconnecting : PlexivoChannelStatus.connecting);
    await _freshToken(force: false);
    if (!_active || _refusal != null || _conn != null) return;
    final api = Uri.parse(_host.apiUrl);
    final project = api.pathSegments.where((s) => s.isNotEmpty).last;
    final token = _host.accessToken;
    final socketUri = Uri(
      scheme: api.scheme == 'https' ? 'wss' : 'ws',
      host: api.host,
      port: api.hasPort ? api.port : null,
      path: '/client-data/socket/websocket',
      queryParameters: {
        'vsn': '2.0.0',
        'project': project,
        'apikey': _host.publishableKey,
        if (token != null) 'access_token': token,
      },
    );
    final WebSocketChannel ws;
    try {
      ws = WebSocketChannel.connect(socketUri);
    } catch (_) {
      _scheduleReconnect(refresh: true);
      return;
    }
    final conn = _Connection(ws, token);
    _conn = conn;
    conn.sub = ws.stream.listen((event) => _onFrame(conn, event), onDone: () => _lost(conn), onError: (_) => _lost(conn));
    try {
      await ws.ready;
    } catch (_) {
      // Refused at the door: often an access token that has just expired.
      _lost(conn, refresh: true);
      return;
    }
    if (!identical(_conn, conn)) return;
    final ref = _send(conn, _topic, 'phx_join', {
      if (clientId != null) 'client_id': clientId,
      if (filter != null) 'filter': filter,
      if (presenceMeta != null) 'presence': presenceMeta,
    });
    conn.replies[ref] = Completer<Map<String, dynamic>>()..future.then((reply) => _onJoinReply(conn, reply), onError: (_) {});
    conn.heartbeat = Timer.periodic(const Duration(seconds: 25), (_) => _send(conn, 'phoenix', 'heartbeat', {}));
  }

  void _onJoinReply(_Connection conn, Map<String, dynamic> reply) {
    if (!identical(_conn, conn)) return;
    if (reply['status'] == 'ok') {
      _joined = true;
      _everJoined = true;
      _reconnectAttempt = 0;
      _setStatus(PlexivoChannelStatus.joined);
      for (final w in _joinWaiters) {
        if (!w.isCompleted) w.complete();
      }
      _joinWaiters.clear();
      _scheduleTokenRenewal(conn);
      return;
    }
    final reason = ((reply['response'] as Map?)?['reason'] ?? 'join_refused').toString();
    if (!_errors.isClosed) _errors.add(reason);
    if (reason == 'unavailable') {
      // The database is briefly out of reach: try again later.
      _lost(conn);
      return;
    }
    _refusal = reason;
    final error = _refused(reason);
    for (final w in _joinWaiters) {
      if (!w.isCompleted) w.completeError(error);
    }
    _joinWaiters.clear();
    _conn = null;
    conn.close();
    _setStatus(PlexivoChannelStatus.refused);
  }

  void _onFrame(_Connection conn, Object? event) {
    if (!identical(_conn, conn)) return;
    final List<dynamic> frame;
    try {
      frame = jsonDecode(event.toString()) as List<dynamic>;
    } catch (_) {
      return;
    }
    if (frame.length != 5) return;
    final ref = frame[1]?.toString();
    final name = frame[3]?.toString();
    final payload = frame[4] is Map ? Map<String, dynamic>.from(frame[4] as Map) : <String, dynamic>{};
    if (name == 'phx_reply' && ref != null && conn.replies.containsKey(ref)) {
      conn.replies.remove(ref)!.complete(payload);
      return;
    }
    if (frame[2] != _topic) return;
    switch (name) {
      case 'postgres_changes':
      case 'change':
        if (!_changes.isClosed) _changes.add(PlexivoChange.fromJson(payload));
      case 'broadcast':
        if (!_broadcasts.isClosed) {
          _broadcasts.add(PlexivoBroadcast(payload['event']?.toString() ?? '', Map<String, dynamic>.from(payload['payload'] as Map? ?? {})));
        }
      case 'presence_state':
      case 'presence_diff':
        if (!_presence.isClosed) _presence.add(PlexivoPresence(name!, payload));
      case 'graphql':
        _graphql[payload['id']]?.call(Map<String, dynamic>.from(payload['payload'] as Map));
      case 'system':
        if (payload['status'] == 'token_expired') {
          if (!_errors.isClosed) _errors.add('token_expired');
          // The server ends the channel next: rejoin at once with a fresh token.
          _lost(conn, refresh: true, immediate: true);
        }
      case 'phx_close':
      case 'phx_error':
        // The server ended this channel; the socket may still be open.
        _lost(conn);
    }
  }

  /// The connection [conn] is gone: tidy up and, unless unsubscribed or refused, come back.
  void _lost(_Connection conn, {bool refresh = false, bool immediate = false}) {
    if (!identical(_conn, conn)) return;
    _conn = null;
    conn.close();
    _joined = false;
    if (!_active || _refusal != null) return;
    _setStatus(_everJoined ? PlexivoChannelStatus.reconnecting : PlexivoChannelStatus.connecting);
    _scheduleReconnect(refresh: refresh, immediate: immediate, staleToken: conn.token);
  }

  void _scheduleReconnect({bool refresh = false, bool immediate = false, String? staleToken}) {
    if (!_active || _refusal != null || _reconnect?.isActive == true) return;
    final delay = immediate ? Duration.zero : Duration(seconds: const [1, 2, 4, 8, 16, 30][_reconnectAttempt.clamp(0, 5)]);
    _reconnectAttempt++;
    _reconnect = Timer(delay, () async {
      if (refresh) await _freshToken(force: true, staleToken: staleToken);
      await _connect();
    });
  }

  /// Renews the session when its access token has expired (or [force] and it is still [staleToken]).
  Future<void> _freshToken({required bool force, String? staleToken}) async {
    final refresh = _refreshSession;
    final token = _host.accessToken;
    if (refresh == null || token == null) return;
    final exp = _expiry(token);
    final soon = exp != null && exp.isBefore(DateTime.now().add(const Duration(seconds: 2)));
    if (!soon && !(force && (staleToken == null || staleToken == token))) return;
    try {
      await refresh();
    } catch (_) {
      if (!_errors.isClosed) _errors.add('refresh_failed');
    }
  }

  /// Before the token [conn] joined with expires, reconnects with a fresh one, so no change is missed.
  void _scheduleTokenRenewal(_Connection conn) {
    final token = conn.token;
    if (token == null || _refreshSession == null) return;
    final exp = _expiry(token);
    if (exp == null) return;
    final issued = _issuedAt(token);
    final life = issued == null ? const Duration(hours: 1) : exp.difference(issued);
    var margin = Duration(milliseconds: life.inMilliseconds ~/ 5);
    if (margin > const Duration(seconds: 30)) margin = const Duration(seconds: 30);
    if (margin < const Duration(seconds: 1)) margin = const Duration(seconds: 1);
    var wait = exp.subtract(margin).difference(DateTime.now());
    if (wait.isNegative) wait = Duration.zero;
    conn.renewal = Timer(wait, () async {
      if (!identical(_conn, conn)) return;
      if (_host.accessToken == conn.token) await _freshToken(force: true, staleToken: conn.token);
      if (identical(_conn, conn) && _host.accessToken != conn.token) _lost(conn, immediate: true);
    });
  }

  /// Broadcasts [event] with [payload] to everyone in the room.
  ///
  /// Throws a [StateError] when the channel is not subscribed.
  void sendBroadcast(String event, [Map<String, dynamic> payload = const {}]) {
    final c = _conn;
    if (!_active || c == null) throw StateError('Realtime channel is not connected');
    _send(c, _topic, 'broadcast', {'event': event, 'payload': payload});
  }

  /// Sends [event] with [payload] on this channel and returns the server's reply.
  ///
  /// Fails with a `TimeoutException` after 10 seconds without a reply, which is
  /// also what happens when the channel is not connected.
  Future<Map<String, dynamic>> push(String event, Map<String, dynamic> payload) {
    final completer = Completer<Map<String, dynamic>>();
    final c = _conn;
    if (c != null) {
      final ref = _send(c, _topic, event, payload);
      c.replies[ref] = completer;
    }
    return completer.future.timeout(const Duration(seconds: 10));
  }

  /// Routes live GraphQL results for subscription [id] to [handler].
  ///
  /// Used by [PlexivoClient.graphqlSubscribe].
  void onGraphql(String id, void Function(Map<String, dynamic>) handler) => _graphql[id] = handler;

  String _send(_Connection conn, String topic, String event, Map<String, dynamic> payload) {
    final ref = '${_ref++}';
    if (event == 'phx_join') conn.joinRef = ref;
    try {
      conn.ws.sink.add(jsonEncode([topic == _topic ? conn.joinRef : null, ref, topic, event, payload]));
    } catch (_) {
      // A closed sink: the reconnect path takes over.
    }
    return ref;
  }

  /// Leaves, closes the connection and closes every stream.
  ///
  /// The channel cannot be subscribed again; create a new one.
  Future<void> unsubscribe() async {
    _active = false;
    _reconnect?.cancel();
    final c = _conn;
    _conn = null;
    _joined = false;
    if (c != null) {
      _send(c, _topic, 'phx_leave', {});
      await c.close();
    }
    _setStatus(PlexivoChannelStatus.closed);
    await _changes.close();
    await _broadcasts.close();
    await _presence.close();
    await _errors.close();
    await _statuses.close();
  }
}

/// One WebSocket connection of a channel, with what belongs to it.
class _Connection {
  _Connection(this.ws, this.token);
  final WebSocketChannel ws;
  final String? token;
  String? joinRef;
  StreamSubscription<dynamic>? sub;
  Timer? heartbeat;
  Timer? renewal;
  final replies = <String, Completer<Map<String, dynamic>>>{};

  Future<void> close() async {
    heartbeat?.cancel();
    renewal?.cancel();
    for (final r in replies.values) {
      if (!r.isCompleted) r.completeError(StateError('Realtime connection closed'));
    }
    replies.clear();
    final s = sub;
    sub = null;
    try {
      await ws.sink.close();
    } catch (_) {}
    await s?.cancel();
  }
}

Map<String, dynamic>? _claims(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final decoded = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } catch (_) {
    return null;
  }
}

DateTime? _time(Object? seconds) => seconds is num ? DateTime.fromMillisecondsSinceEpoch((seconds * 1000).toInt()) : null;
DateTime? _expiry(String token) => _time(_claims(token)?['exp']);
DateTime? _issuedAt(String token) => _time(_claims(token)?['iat']);
