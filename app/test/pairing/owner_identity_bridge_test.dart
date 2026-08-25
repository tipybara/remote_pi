// Regression tests for OwnerIdentityBridge's watch listener — see
// plan/24-fix-app-publish-race (follow-up). The platform plugins
// emit their current blob the moment we subscribe, which used to
// race against boot()'s population of `_current` and trigger a
// spurious `wipeAll` of the freshly-loaded peer set.

import 'dart:async';
import 'dart:typed_data';

import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }
  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);
  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(_store);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<OwnerIdentity> _freshIdentity() async {
  final kp = await Ed25519().newKeyPair();
  final pub = await kp.extractPublicKey();
  final sk = await kp.extractPrivateKeyBytes();
  return OwnerIdentity(
    ownerPk: Uint8List.fromList(pub.bytes),
    ownerSk: Uint8List.fromList(sk),
  );
}

/// Reproduces the issue #39 shape: the pre-flight reports "unavailable"
/// (on iOS the old ubiquity-token check was ALWAYS false in App Store
/// builds) while the real read/write path works fine — iCloud Keychain
/// needs no entitlement.
class _FalsePreflightStore implements OwnerIdentityStore {
  final InMemoryOwnerIdentityStore _inner;
  _FalsePreflightStore(this._inner);

  @override
  Future<bool> isSyncAvailable() async => false;
  @override
  Future<OwnerIdentity?> load() => _inner.load();
  @override
  Future<void> save(OwnerIdentity identity) => _inner.save(identity);
  @override
  Future<void> delete() => _inner.delete();
  @override
  Stream<OwnerIdentity> watch() => _inner.watch();
}

/// Store whose `load()` answers a scripted sequence, so a test can make
/// the underlying sync item *change between two boot() calls* — the
/// shape of "iCloud pushed a restored key while the user sat on
/// /sync-required and tapped Check again" (spec 05 §10.8) — and count
/// how many times the bridge actually hit the platform.
class _ScriptedLoadStore implements OwnerIdentityStore {
  final List<OwnerIdentity?> _loads;
  final List<OwnerIdentity> saved = [];
  int loadCalls = 0;
  final _controller = StreamController<OwnerIdentity>.broadcast();

  _ScriptedLoadStore(this._loads);

  @override
  Future<bool> isSyncAvailable() async => true;
  @override
  Future<OwnerIdentity?> load() async {
    final value = _loads[loadCalls < _loads.length ? loadCalls : _loads.length - 1];
    loadCalls++;
    // Yield so two concurrent boot() calls can interleave here.
    await Future<void>.delayed(Duration.zero);
    return value;
  }

  @override
  Future<void> save(OwnerIdentity identity) async {
    saved.add(identity);
    _controller.add(identity);
  }

  @override
  Future<void> delete() async {}
  @override
  Stream<OwnerIdentity> watch() => _controller.stream;
}

void main() {
  group('OwnerIdentityBridge.boot — issue #39 (pre-flight must not gate)', () {
    test('boot succeeds when pre-flight is false but load/save work', () async {
      // Fresh install: no stored identity, pre-flight lies "unavailable".
      final store = _FalsePreflightStore(InMemoryOwnerIdentityStore());
      final bridge = OwnerIdentityBridge(
        store,
        PairingStorage(_FakeSecureStorage()),
      );

      final result = await bridge.boot();

      expect(result, isA<IdentityReady>());
      expect((result as IdentityReady).generated, isTrue);
      expect(bridge.currentOwnerPk, isNotNull);
    });

    test('boot loads an existing identity even with a false pre-flight',
        () async {
      final id = await _freshIdentity();
      final store = _FalsePreflightStore(InMemoryOwnerIdentityStore(initial: id));
      final bridge = OwnerIdentityBridge(
        store,
        PairingStorage(_FakeSecureStorage()),
      );

      final result = await bridge.boot();

      expect(result, isA<IdentityReady>());
      expect((result as IdentityReady).generated, isFalse);
      expect(bridge.currentOwnerPk, id.ownerPk);
    });

    test(
        'boot still gates when the real load/save path throws '
        'SyncUnavailable (Android Block Store parity)', () async {
      final store = InMemoryOwnerIdentityStore(syncAvailable: false);
      final bridge = OwnerIdentityBridge(
        store,
        PairingStorage(_FakeSecureStorage()),
      );

      final result = await bridge.boot();

      expect(result, isA<SyncUnavailableResult>());
      expect(bridge.currentOwnerPk, isNull);
    });
  });

  group('OwnerIdentityBridge.startWatching — initial emit race fix', () {
    test(
        'subscribing BEFORE boot() does NOT wipe peers (initial emit adopted '
        'silently)', () async {
      // Reproduce the production race: router calls startWatching
      // fire-and-forget before boot() has populated _current. The
      // store emits the existing blob immediately; without the fix
      // this would clear peers + trigger onReset.
      final id = await _freshIdentity();
      final store = InMemoryOwnerIdentityStore(initial: id);
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-precious',
        sessionName: 'pi',
        relayUrl: 'https://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));
      final bridge = OwnerIdentityBridge(store, storage);

      var resetCalls = 0;
      bridge.startWatching(onReset: () async => resetCalls++);

      // Force the initial-emit through the in-memory store. The
      // production iOS/Android plugins do this from onListen; the
      // in-memory fake exposes the same shape via a save() that
      // echoes through the broadcast controller.
      await store.save(id);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The peer survives — no wipe happened.
      final peers = await storage.listPeers();
      expect(peers, hasLength(1));
      expect(peers.single.remoteEpk, 'epk-precious');
      // No reset callback was invoked.
      expect(resetCalls, 0);
    });

    test(
        'after the initial emit was adopted, a *different* owner_pk DOES '
        'wipe + reset', () async {
      // Confirm the regression fix didn't soften the legitimate
      // "Owner key rotated via sync" path.
      final first = await _freshIdentity();
      final second = await _freshIdentity();
      final store = InMemoryOwnerIdentityStore(initial: first);
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-old',
        sessionName: 'pi',
        relayUrl: 'https://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));
      final bridge = OwnerIdentityBridge(store, storage);

      final resetCompleter = Completer<void>();
      bridge.startWatching(onReset: () async {
        if (!resetCompleter.isCompleted) resetCompleter.complete();
      });

      // First emit (initial) — adopted silently.
      await store.save(first);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await storage.listPeers(), hasLength(1),
          reason: 'initial emit must not wipe');

      // Now a real key rotation — different bytes. wipeAll fires.
      await store.save(second);
      await resetCompleter.future.timeout(const Duration(seconds: 1));
      expect(await storage.listPeers(), isEmpty,
          reason: 'real key rotation must wipe');
    });

    test('the wiping path also refreshes what boot() reports afterwards',
        () async {
      // The single-path invariant seen from the other side: once the
      // watch listener has swapped the Owner, a later boot() must
      // report the NEW identity — otherwise "boot() caches" would
      // pin the app to a key the sync surface no longer holds.
      final first = await _freshIdentity();
      final second = await _freshIdentity();
      final store = InMemoryOwnerIdentityStore(initial: first);
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = OwnerIdentityBridge(store, storage);
      await bridge.boot();
      expect(bridge.currentOwnerPk, first.ownerPk);

      final resetCompleter = Completer<void>();
      bridge.startWatching(onReset: () async {
        if (!resetCompleter.isCompleted) resetCompleter.complete();
      });
      await store.save(second);
      await resetCompleter.future.timeout(const Duration(seconds: 1));

      final result = await bridge.boot();
      expect((result as IdentityReady).identity.ownerPk, second.ownerPk);
      expect(bridge.currentOwnerPk, second.ownerPk);
    });

    test('same-pk re-emit after adoption is a noop (no wipe, no reset)',
        () async {
      final id = await _freshIdentity();
      final store = InMemoryOwnerIdentityStore(initial: id);
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-stable',
        sessionName: 'pi',
        relayUrl: 'https://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));
      final bridge = OwnerIdentityBridge(store, storage);
      var resets = 0;
      bridge.startWatching(onReset: () async => resets++);

      await store.save(id); // initial-emit adoption
      await store.save(id); // same-pk echo — must be ignored
      await store.save(id);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await storage.listPeers(), hasLength(1));
      expect(resets, 0);
    });
  });

  // -------------------------------------------------------------------------
  // plan/62-specs/05-identity-keychain.md §10.8 — boot() is documented
  // idempotent and must actually be. The Owner key is the root of trust:
  // the ONLY path allowed to swap it is the watch listener, because that
  // is where peers/rooms are wiped. A boot() that re-reads the platform
  // item can otherwise replace `_current` behind a peer set that was
  // paired against the previous identity.
  // -------------------------------------------------------------------------

  group('OwnerIdentityBridge.boot — idempotence (spec 05 §10.8)', () {
    test(
        'an item that changed between calls cannot swap the Owner behind '
        'the peer set', () async {
      final first = await _freshIdentity();
      final second = await _freshIdentity();
      final store = _ScriptedLoadStore([first, second]);
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = OwnerIdentityBridge(store, storage);

      await bridge.boot();
      // Paired against `first` — these handles only mean anything to it.
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-of-first',
        sessionName: 'pi',
        relayUrl: 'https://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));

      // /sync-required's "Check again" (sync_required_page.dart:27) and
      // the router's re-`load()` both call boot() a second time.
      final result = await bridge.boot();

      expect(bridge.currentOwnerPk, first.ownerPk,
          reason: 'boot() must be a cache read — the identity may only '
              'change through the watch path, which wipes');
      expect((result as IdentityReady).identity.ownerPk, first.ownerPk);
      expect(store.loadCalls, 1, reason: 'no second platform read');
      final peers = await storage.listPeers();
      expect(peers.map((p) => p.remoteEpk), ['epk-of-first'],
          reason: 'peers must never outlive the identity they were '
              'paired against');
    });

    test('a load() that momentarily misses cannot rotate the Owner key',
        () async {
      // Worst shape of the same defect: the second boot() sees `null`
      // (keychain hiccup / item not yet re-synced) and the old body
      // generated AND SAVED a brand-new keypair — silently rotating the
      // root of trust for every device on the account.
      final first = await _freshIdentity();
      final store = _ScriptedLoadStore([first, null]);
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = OwnerIdentityBridge(store, storage);

      await bridge.boot();
      final result = await bridge.boot();

      expect(store.saved, isEmpty,
          reason: 'a cached identity must never be overwritten on disk');
      expect(bridge.currentOwnerPk, first.ownerPk);
      expect((result as IdentityReady).generated, isFalse);
    });

    test('concurrent boot() calls generate exactly one identity', () async {
      // buildRouter fires `_BootState.load` (→ boot()) without awaiting
      // it, so a "Check again" tap can overlap it. Two generate+save
      // races leave the caller of the first boot holding a key the sync
      // surface no longer stores.
      final store = _ScriptedLoadStore([null]);
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = OwnerIdentityBridge(store, storage);

      final results = await Future.wait([bridge.boot(), bridge.boot()]);

      expect(store.saved, hasLength(1),
          reason: 'only one identity may ever be generated');
      final pks = results
          .map((r) => (r as IdentityReady).identity.ownerPk)
          .toList();
      expect(pks[0], pks[1]);
      expect(bridge.currentOwnerPk, pks[0]);
    });

    test('SyncUnavailable is NOT cached — Check again re-reads the platform',
        () async {
      final store = InMemoryOwnerIdentityStore(syncAvailable: false);
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = OwnerIdentityBridge(store, storage);

      expect(await bridge.boot(), isA<SyncUnavailableResult>());
      // User flips iCloud Keychain on and taps "Check again".
      store.syncAvailable = true;
      final result = await bridge.boot();

      expect(result, isA<IdentityReady>());
      expect(bridge.currentOwnerPk, isNotNull);
    });
  });
}
