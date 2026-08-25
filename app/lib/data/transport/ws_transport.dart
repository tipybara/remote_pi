// WebSocket-based PeerTransport.
//
// Flow per connection:
//   1. Connect to relay WS
//   2. Ed25519 challenge-response (hello → challenge → auth)
//   3. After auth, two parallel streams of inbound frames:
//        - envelope frames `{peer, ct}` → decoded to the peer queue
//        - control frames (top-level `type`, no `peer`) → control stream
//      Outbound `subscribe_presence` / `presence_check` go raw too.
//
// `peer` is standard base64 of the destination's Ed25519 pubkey (matches
// the relay registry, populated from the peer's hello). `ct` is base64 of
// the inner-envelope bytes (plain JSON post-rollback, see plano 06).

import 'dart:async';
import 'dart:convert';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../pairing/pair_request_flow.dart';

class WsTransportError implements Exception {
  final String message;
  const WsTransportError(this.message);

  @override
  String toString() => 'WsTransportError: $message';
}

class WsTransport implements PeerTransport, IControlLink {
  final WebSocketChannel _ws;
  final _queue = _MsgQueue();
  final _controlController =
      StreamController<ControlInbound>.broadcast();

  WsTransport._(this._ws);

  // Connect, authenticate with relay, and return a ready transport.
  static Future<WsTransport> connect({
    required String relayUrl,
    required String peerPubkey, // base64 standard or url — destination peer
    required SimpleKeyPair ed25519Key, // this device's Ed25519 long-term key
  }) async {
    // Plan-18 follow-up — set a WS-level pingInterval (RFC 6455
    // control frames). This keeps the TCP connection alive through
    // NAT / corporate proxies that aggressively close idle sockets,
    // and surfaces a dead WS as `onDone` / `onError` instead of
    // letting it silently linger until the next user action. The
    // protocol-level Ping/Pong handled by ConnectionManager covers
    // app↔Pi liveness; this one covers app↔relay TCP liveness.
    // Accept http(s) URLs in the user-facing form but always speak
    // ws(s) on the wire — IOWebSocketChannel rejects http schemes.
    final WebSocketChannel ws = IOWebSocketChannel.connect(
      Uri.parse(toWsRelayUrl(relayUrl)),
      pingInterval: const Duration(seconds: 20),
    );
    final transport = WsTransport._(ws);

    final challengeCompleter = Completer<Map<String, dynamic>>();
    bool authDone = false;

    final sub = ws.stream.listen(
      (raw) {
        // Volume probe: log every frame the relay pushes onto this
        // socket so we can spot firehose patterns (e.g. presence
        // churn, repeated room snapshots) by counting prefix
        // occurrences — body kept compact so the log stays grep-able
        // even when the relay is chatty.
        final rawStr = raw is String ? raw : raw.toString();
        if (!authDone) {
          debugPrint('[ws-in] bytes=${rawStr.length} stage=preauth');
          try {
            challengeCompleter.complete(
              jsonDecode(raw as String) as Map<String, dynamic>,
            );
          } catch (e) {
            if (!challengeCompleter.isCompleted) {
              challengeCompleter.completeError(e);
            }
          }
          return;
        }
        try {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          // Envelope: {peer, room?, ct} → enqueue payload bytes.
          if (frame.containsKey('peer') && frame.containsKey('ct')) {
            final bytes = _b64Decode(frame['ct'] as String);
            final senderRoom = frame['room'] as String?;
            // Plan-18 follow-up — DEMUX inbound by sender room.
            // SessionRepository is singleton; without this guard,
            // AgentChunks for a chat the user just left bleed into
            // the chat they're now viewing. When senderRoom doesn't
            // match the currently-addressed Pi cwd, drop the payload.
            // Legacy Pis without `room` route unconditionally.
            //
            // Plan 61 Phase 3 — the machine control room is exempt. It is not
            // a chat: it only ever emits `action_ok` / `action_error` for
            // workspace/session RPCs, so it cannot bleed conversation state
            // into the active session. Without this exemption every reply from
            // the gateway would be dropped as a room mismatch, since the app's
            // active room is whichever chat the user has open.
            //
            // Plan 62 spec 03 T5 — so is the answer to an RPC we addressed at
            // this room via `sendToRoom` (Home's rename targets a session the
            // user is NOT chatting in). The exemption is per correlation id,
            // not per room: exactly the one frame we are waiting for gets
            // through, and the room's AgentChunks stay out.
            if (senderRoom != null &&
                senderRoom != transport._activeRoom &&
                senderRoom != kControlRoomId &&
                !transport._claimsAwaitedReply(bytes, senderRoom)) {
              debugPrint(
                '[ws-in] bytes=${rawStr.length} kind=envelope '
                'sender_room=$senderRoom DROPPED (room-mismatch)',
              );
              return;
            }
            debugPrint(
              '[ws-in] bytes=${rawStr.length} kind=envelope '
              'ct.bytes=${bytes.length}',
            );
            transport._queue.add(bytes);
            return;
          }
          // Control: top-level `type` only → presence stream.
          final ctrl = ControlInbound.tryFromJson(frame);
          if (ctrl != null && !transport._controlController.isClosed) {
            debugPrint(
              '[ws-in] bytes=${rawStr.length} kind=control '
              'type=${frame['type']}',
            );
            transport._controlController.add(ctrl);
            return;
          }
          // Anything else: unknown shape — drop silently.
          debugPrint('[ws-in] bytes=${rawStr.length} kind=unknown DROPPED');
        } catch (e) {
          debugPrint(
            '[ws-in] bytes=${rawStr.length} kind=malformed DROPPED err=$e',
          );
        }
      },
      onError: (e) {
        if (!challengeCompleter.isCompleted) challengeCompleter.completeError(e);
        transport._queue.error(e);
      },
      onDone: () {
        if (!challengeCompleter.isCompleted) {
          challengeCompleter.completeError(const WsTransportError('WS closed during auth'));
        }
        transport._queue.close();
        if (!transport._controlController.isClosed) {
          transport._controlController.close();
        }
      },
    );

    try {
      // 1. Hello (standard base64 — matches relay registry format).
      // Plan 17: app is a client (no cwd) and always announces itself
      // on the canonical 'main' room. Pi-side hellos include their own
      // room_id (one per cwd) AND room_meta; that's not our concern here.
      final pub = await ed25519Key.extractPublicKey();
      ws.sink.add(jsonEncode({
        'type': 'hello',
        'pubkey': base64.encode(pub.bytes),
        'room_id': 'main',
      }));

      // 2. Challenge
      final ch = await challengeCompleter.future;
      if (ch['type'] != 'challenge') {
        throw WsTransportError('Expected challenge, got ${ch['type']}');
      }
      final nonce = _b64Decode(ch['nonce'] as String);

      // 3. Auth
      final sig = await Ed25519().sign(nonce, keyPair: ed25519Key);
      ws.sink.add(jsonEncode({
        'type': 'auth',
        'sig': base64.encode(sig.bytes),
      }));
      authDone = true;

      transport._peerPubkey = _normalizeToStandard(peerPubkey);
      transport._sub = sub;
      return transport;
    } catch (e) {
      await sub.cancel();
      await ws.sink.close();
      rethrow;
    }
  }

  String _peerPubkey = '';
  StreamSubscription? _sub;

  /// Active target room on the Pi side. Plan 17: set via
  /// `setActiveRoom`, defaults to 'main' when unset. The outer envelope
  /// embeds this so the Pi can route the inner message to the right
  /// per-cwd session.
  String _activeRoom = 'main';

  /// Override the destination room (Pi side). The app remains on the
  /// 'main' room itself (that's what we sent in `hello.room_id`).
  void setActiveRoom(String room) {
    if (room == _activeRoom) {
      return;
    }
    _activeRoom = room;
  }

  @override
  Future<void> send(Uint8List data) async {
    _ws.sink.add(jsonEncode({
      'peer': _peerPubkey,
      'room': _activeRoom,
      'ct': base64.encode(data),
    }));
  }

  /// Plan 61 Phase 2 — address ONE frame at a specific room without moving
  /// the active target.
  ///
  /// Renaming a session from Home targets whichever session the user
  /// long-pressed, which is usually NOT the one they are chatting in.
  /// Re-pointing [setActiveRoom] to send it would silently move the user's
  /// conversation to another cwd — precisely the class of jump plan 61 exists
  /// to stop. This leaves `_activeRoom` alone.
  Future<void> sendToRoom(Uint8List data, String room) async {
    _rememberAwaitedReply(data, room);
    _ws.sink.add(jsonEncode({
      'peer': _peerPubkey,
      'room': room,
      'ct': base64.encode(data),
    }));
  }

  // ---- Room-addressed RPC correlation (plan 62 spec 03 T5) ----------------

  /// Outbound request id → the room it was addressed at, plus when. An entry
  /// buys exactly ONE inbound frame past the room demux; see the listener.
  final Map<String, _AwaitedReply> _awaitedReplies = {};

  /// Comfortably longer than the 15 s `ActionsRepository` RPC timeout, so a
  /// reply that never comes is evicted rather than pinning the map open.
  static const Duration _awaitedReplyTtl = Duration(minutes: 1);

  void _rememberAwaitedReply(Uint8List data, String room) {
    final id = _jsonStringField(data, 'id');
    if (id == null) return;
    final cutoff = DateTime.now().subtract(_awaitedReplyTtl);
    _awaitedReplies.removeWhere((_, v) => v.sentAt.isBefore(cutoff));
    _awaitedReplies[id] = _AwaitedReply(room: room, sentAt: DateTime.now());
  }

  /// True when [payload] is the answer to an RPC this transport addressed at
  /// [senderRoom]. Consumes the correlation id — a reply arrives once, so a
  /// later frame reusing the id cannot ride the same exemption.
  bool _claimsAwaitedReply(Uint8List payload, String senderRoom) {
    if (_awaitedReplies.isEmpty) return false;
    final inReplyTo = _jsonStringField(payload, 'in_reply_to');
    if (inReplyTo == null) return false;
    final awaited = _awaitedReplies[inReplyTo];
    if (awaited == null || awaited.room != senderRoom) return false;
    _awaitedReplies.remove(inReplyTo);
    return true;
  }

  @override
  Future<Uint8List> receive() => _queue.next();

  // ---- IControlLink --------------------------------------------------------

  @override
  Stream<ControlInbound> get controlFrames => _controlController.stream;

  @override
  void sendControl(Map<String, dynamic> json) {
    _ws.sink.add(jsonEncode(json));
  }

  // -------------------------------------------------------------------------

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await _ws.sink.close();
    _queue.close();
    if (!_controlController.isClosed) await _controlController.close();
  }
}

// ---------------------------------------------------------------------------

class _AwaitedReply {
  final String room;
  final DateTime sentAt;
  const _AwaitedReply({required this.room, required this.sentAt});
}

// Reads one top-level string field out of a plain-JSON inner payload.
// The transport is otherwise opaque to message content; this peek exists
// only to correlate a room-addressed RPC with its reply (spec 03 T5).
// Returns null for anything that isn't a JSON object with that string key.
String? _jsonStringField(List<int> bytes, String key) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) return null;
    final value = decoded[key];
    return value is String ? value : null;
  } catch (_) {
    return null;
  }
}

class _MsgQueue {
  final _buf = <Uint8List>[];
  final _waiters = <Completer<Uint8List>>[];
  bool _closed = false;

  void add(Uint8List msg) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(msg);
    } else if (!_closed) {
      _buf.add(msg);
    }
  }

  void error(Object e) {
    for (final w in _waiters) {
      w.completeError(e);
    }
    _waiters.clear();
    _closed = true;
  }

  void close() {
    for (final w in _waiters) {
      w.completeError(const WsTransportError('transport closed'));
    }
    _waiters.clear();
    _closed = true;
  }

  Future<Uint8List> next() {
    if (_closed) return Future.error(const WsTransportError('transport closed'));
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future;
  }
}

// Decodes standard or url-safe base64 (pads defensively).
Uint8List _b64Decode(String s) {
  final pad = (4 - s.length % 4) % 4;
  final padded = s + '=' * pad;
  try {
    return base64.decode(padded);
  } on FormatException {
    return base64Url.decode(padded);
  }
}

// Relay registry uses standard base64 (from each peer's hello). QR/storage
// may carry url-safe encoding — re-encode to standard so the relay matches.
String _normalizeToStandard(String pubkey) {
  try {
    final pad = (4 - pubkey.length % 4) % 4;
    final bytes = base64Url.decode(pubkey + '=' * pad);
    return base64.encode(bytes);
  } catch (_) {
    return pubkey;
  }
}
