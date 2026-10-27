import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

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
/// It works signed out too, where the rows or room allow it, and reconnects on
/// its own.
class PlexivoRealtimeChannel {
  /// Creates a channel on [topic] (without the `realtime:` prefix).
  ///
  /// Prefer [PlexivoClient.channel]. See [filter], [presenceMeta] and
  /// [clientId].
  PlexivoRealtimeChannel(this._host, String topic, {this.filter, this.presenceMeta, this.clientId}) : _topic = 'realtime:$topic';

  final RealtimeHost _host;
  final String _topic;

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

  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnect;
  var _active = false;
  var _joined = false;
  var _reconnectAttempt = 0;
  var _ref = 1;
  final _replies = <String, Completer<Map<String, dynamic>>>{};
  final _joinWaiters = <Completer<void>>[];
  final _graphql = <String, void Function(Map<String, dynamic>)>{};

  final _changes = StreamController<PlexivoChange>.broadcast();
  final _broadcasts = StreamController<PlexivoBroadcast>.broadcast();
  final _presence = StreamController<PlexivoPresence>.broadcast();
  final _errors = StreamController<String>.broadcast();

  /// Row changes on `changes:<table>` and the starter channel.
  Stream<PlexivoChange> get changes => _changes.stream;

  /// Every broadcast in a room. Use [on] for one event.
  Stream<PlexivoBroadcast> get broadcasts => _broadcasts.stream;

  /// Presence updates in a room: who is here, who joined and who left.
  Stream<PlexivoPresence> get presence => _presence.stream;

  /// Join refusals and server notices, as reason codes.
  ///
  /// For example `table_not_exposed`, `sign_in_required` or `token_expired`.
  Stream<String> get errors => _errors.stream;

  /// The payloads of broadcasts named [event].
  Stream<Map<String, dynamic>> on(String event) => broadcasts.where((b) => b.event == event).map((b) => b.payload);

  /// Connects and joins, and returns this channel for chaining.
  ///
  /// Calling it again while subscribed does nothing. After a drop the channel
  /// reconnects after 1, 2, 4, then every 8 seconds, with the current access
  /// token. Watch [errors] for refusals.
  PlexivoRealtimeChannel subscribe() {
    if (_active) return this;
    _active = true;
    _connect();
    return this;
  }

  /// Completes once the channel has joined, at once if it already has.
  ///
  /// If the server refuses the join, it does not complete: [errors] reports the
  /// reason.
  Future<void> ready() {
    if (_joined) return Future.value();
    final c = Completer<void>();
    _joinWaiters.add(c);
    return c.future;
  }

  void _connect() {
    if (!_active) return;
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
    final channel = WebSocketChannel.connect(socketUri);
    _socket = channel;
    channel.ready.then((_) {
      if (!_active || !identical(_socket, channel)) return;
      _reconnectAttempt = 0;
      final ref = _send(_topic, 'phx_join', {
        if (clientId != null) 'client_id': clientId,
        if (filter != null) 'filter': filter,
        if (presenceMeta != null) 'presence': presenceMeta,
      });
      _replies[ref] = Completer<Map<String, dynamic>>()
        ..future.then((reply) {
          if (reply['status'] == 'ok') {
            _joined = true;
            for (final w in _joinWaiters) {
              if (!w.isCompleted) w.complete();
            }
            _joinWaiters.clear();
          } else {
            _errors.add(((reply['response'] as Map?)?['reason'] ?? 'join_refused').toString());
          }
        });
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) => _send('phoenix', 'heartbeat', {}));
    }).catchError((_) => _scheduleReconnect());
    _subscription = channel.stream.listen((event) {
      final frame = jsonDecode(event.toString()) as List<dynamic>;
      if (frame.length != 5) return;
      final ref = frame[1]?.toString();
      final name = frame[3]?.toString();
      final payload = frame[4] is Map ? Map<String, dynamic>.from(frame[4] as Map) : <String, dynamic>{};
      if (name == 'phx_reply' && ref != null && _replies.containsKey(ref)) {
        _replies.remove(ref)!.complete(payload);
        return;
      }
      if (frame[2] != _topic) return;
      if (name == 'postgres_changes' || name == 'change') _changes.add(PlexivoChange.fromJson(payload));
      if (name == 'broadcast') {
        _broadcasts.add(PlexivoBroadcast(payload['event']?.toString() ?? '', Map<String, dynamic>.from(payload['payload'] as Map? ?? {})));
      }
      if (name == 'presence_state' || name == 'presence_diff') _presence.add(PlexivoPresence(name!, payload));
      if (name == 'graphql') _graphql[payload['id']]?.call(Map<String, dynamic>.from(payload['payload'] as Map));
      if (name == 'system' && payload['status'] == 'token_expired') _errors.add('token_expired');
    }, onDone: _scheduleReconnect, onError: (_) => _scheduleReconnect());
  }

  /// Broadcasts [event] with [payload] to everyone in the room.
  ///
  /// Throws a [StateError] when the channel is not subscribed.
  void sendBroadcast(String event, [Map<String, dynamic> payload = const {}]) {
    if (!_active || _socket == null) throw StateError('Realtime channel is not connected');
    _send(_topic, 'broadcast', {'event': event, 'payload': payload});
  }

  /// Sends [event] with [payload] on this channel and returns the server's reply.
  ///
  /// Fails with a `TimeoutException` after 10 seconds without a reply, which is
  /// also what happens when the channel is not connected.
  Future<Map<String, dynamic>> push(String event, Map<String, dynamic> payload) {
    final completer = Completer<Map<String, dynamic>>();
    final ref = _send(_topic, event, payload);
    _replies[ref] = completer;
    return completer.future.timeout(const Duration(seconds: 10));
  }

  /// Routes live GraphQL results for subscription [id] to [handler].
  ///
  /// Used by [PlexivoClient.graphqlSubscribe].
  void onGraphql(String id, void Function(Map<String, dynamic>) handler) => _graphql[id] = handler;

  String _send(String topic, String event, Map<String, dynamic> payload) {
    final ref = '${_ref++}';
    _socket?.sink.add(jsonEncode(['1', ref, topic, event, payload]));
    return ref;
  }

  void _scheduleReconnect() {
    _heartbeat?.cancel();
    _joined = false;
    if (!_active || _reconnect?.isActive == true) return;
    final seconds = 1 << _reconnectAttempt.clamp(0, 3);
    _reconnectAttempt++;
    _reconnect = Timer(Duration(seconds: seconds), _connect);
  }

  /// Leaves, closes the connection and closes every stream.
  ///
  /// The channel cannot be subscribed again; create a new one.
  Future<void> unsubscribe() async {
    _active = false;
    _heartbeat?.cancel();
    _reconnect?.cancel();
    await _subscription?.cancel();
    await _socket?.sink.close();
    await _changes.close();
    await _broadcasts.close();
    await _presence.close();
    await _errors.close();
  }
}
