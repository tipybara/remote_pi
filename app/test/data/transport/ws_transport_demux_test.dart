// Plan 62 spec 03 T5 — inbound demux by sender room.
//
// The transport drops envelopes whose sender room isn't the active one so
// AgentChunks from a chat the user just left can't bleed into the chat
// they're viewing. But `sendToRoom` addresses ONE frame at an arbitrary
// room (Home's rename does exactly that), and the reply comes back stamped
// with THAT room — the relay rewrites the envelope with the sender conn's
// room id (`relay/src/handlers/peer.rs:394`). Without an exemption for a
// room we're actively awaiting a reply from, the RPC's own answer is
// discarded and the caller sees a spurious 15s timeout.
//
// These tests drive a real loopback WebSocket through the full
// hello → challenge → auth handshake so the demux is exercised where it
// actually lives (inside `WsTransport.connect`'s frame listener).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/transport/ws_transport.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal stand-in for the relay: answers `hello` with a `challenge`,
/// swallows `auth`, records outbound envelopes and can push inbound ones.
class _FakeRelay {
  late final HttpServer _server;
  WebSocket? _socket;

  final _envelopes = StreamController<Map<String, dynamic>>.broadcast();
  final _received = <Map<String, dynamic>>[];

  int get port => _server.port;
  String get url => 'ws://127.0.0.1:$port';
  List<Map<String, dynamic>> get received => _received;

  static Future<_FakeRelay> start() async {
    final relay = _FakeRelay();
    relay._server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(relay._accept());
    return relay;
  }

  Future<void> _accept() async {
    await for (final req in _server) {
      final ws = await WebSocketTransformer.upgrade(req);
      _socket = ws;
      ws.listen((dynamic raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        _received.add(frame);
        switch (frame['type']) {
          case 'hello':
            ws.add(
              jsonEncode({
                'type': 'challenge',
                'nonce': base64.encode(List<int>.filled(32, 7)),
              }),
            );
          case 'auth':
            break;
          default:
            _envelopes.add(frame);
        }
      }, onError: (_) {}, cancelOnError: false);
    }
  }

  /// Waits for the app to send an envelope addressed at [room].
  Future<Map<String, dynamic>> nextEnvelopeTo(String room) => _envelopes.stream
      .firstWhere((e) => e['room'] == room)
      .timeout(const Duration(seconds: 5));

  /// Pushes an inbound envelope stamped as coming FROM [room], the way the
  /// relay rewrites it before forwarding.
  void pushFrom(String room, Map<String, dynamic> inner) {
    _socket!.add(
      jsonEncode({
        'peer': base64.encode(List<int>.filled(32, 3)),
        'room': room,
        'ct': base64.encode(utf8.encode(jsonEncode(inner))),
      }),
    );
  }

  Future<void> stop() async {
    await _socket?.close();
    await _envelopes.close();
    await _server.close(force: true);
  }
}

Future<WsTransport> _connect(_FakeRelay relay) async {
  final key = await Ed25519().newKeyPair();
  return WsTransport.connect(
    relayUrl: relay.url,
    peerPubkey: base64.encode(List<int>.filled(32, 3)),
    ed25519Key: key,
  );
}

Map<String, dynamic> _decode(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

void main() {
  late _FakeRelay relay;
  late WsTransport transport;

  setUp(() async {
    relay = await _FakeRelay.start();
    transport = await _connect(relay);
  });

  tearDown(() async {
    await transport.close();
    await relay.stop();
  });

  group('WsTransport inbound demux', () {
    test(
      'a sendToRoom reply from a NON-active, non-ctrl room is delivered',
      () async {
        transport.setActiveRoom('room-A');

        // Home renames a session the user is NOT chatting in.
        await transport.sendToRoom(
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'type': 'session_rename',
                'id': 'act_rename_1',
                'display_name': 'renamed',
              }),
            ),
          ),
          'room-B',
        );
        await relay.nextEnvelopeTo('room-B');

        // The Pi answers from room-B, which is not the active room.
        relay.pushFrom('room-B', {
          'type': 'action_ok',
          'in_reply_to': 'act_rename_1',
          'action': 'session_rename',
        });

        final got = await transport.receive().timeout(
          const Duration(seconds: 3),
        );
        expect(_decode(got)['type'], 'action_ok');
        expect(_decode(got)['in_reply_to'], 'act_rename_1');
      },
    );

    test('an unsolicited frame from another room is still dropped', () async {
      transport.setActiveRoom('room-A');

      // Chunk from a chat the user just left — the bleed the demux exists
      // to stop. It carries an `in_reply_to` we never addressed at room-C.
      relay.pushFrom('room-C', {
        'type': 'agent_chunk',
        'in_reply_to': 'cli_from_another_chat',
        'text': 'leaked',
      });
      // ...followed by a legitimate frame from the active room.
      relay.pushFrom('room-A', {
        'type': 'agent_done',
        'in_reply_to': 'cli_mine',
      });

      final got = await transport.receive().timeout(
        const Duration(seconds: 3),
      );
      expect(
        _decode(got)['type'],
        'agent_done',
        reason: 'the room-C chunk must not reach the queue',
      );
    });

    test('a reply from a room whose RPC already answered is dropped', () async {
      transport.setActiveRoom('room-A');
      await transport.sendToRoom(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'type': 'session_rename',
              'id': 'act_rename_2',
              'display_name': 'renamed',
            }),
          ),
        ),
        'room-B',
      );
      await relay.nextEnvelopeTo('room-B');

      relay.pushFrom('room-B', {
        'type': 'action_ok',
        'in_reply_to': 'act_rename_2',
        'action': 'session_rename',
      });
      final first = await transport.receive().timeout(
        const Duration(seconds: 3),
      );
      expect(_decode(first)['in_reply_to'], 'act_rename_2');

      // The correlation id is spent: a late chunk from room-B reusing it
      // must not ride the exemption back in.
      relay.pushFrom('room-B', {
        'type': 'agent_chunk',
        'in_reply_to': 'act_rename_2',
        'text': 'leaked',
      });
      relay.pushFrom('room-A', {
        'type': 'agent_done',
        'in_reply_to': 'cli_mine',
      });

      final second = await transport.receive().timeout(
        const Duration(seconds: 3),
      );
      expect(_decode(second)['type'], 'agent_done');
    });

    test('the ctrl room stays exempt without any outstanding RPC', () async {
      transport.setActiveRoom('room-A');
      relay.pushFrom(kControlRoomId, {
        'type': 'action_ok',
        'in_reply_to': 'act_ctrl',
        'action': 'machine_sessions',
      });

      final got = await transport.receive().timeout(
        const Duration(seconds: 3),
      );
      expect(_decode(got)['in_reply_to'], 'act_ctrl');
    });

    test('a frame from the active room is delivered', () async {
      transport.setActiveRoom('room-A');
      relay.pushFrom('room-A', {
        'type': 'agent_done',
        'in_reply_to': 'cli_mine',
      });

      final got = await transport.receive().timeout(
        const Duration(seconds: 3),
      );
      expect(_decode(got)['type'], 'agent_done');
    });
  });
}
