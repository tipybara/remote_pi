import 'dart:async';

import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter/foundation.dart';

import 'mesh_blob.dart';
import 'mesh_client.dart';
import 'mesh_envelope.dart';

/// Orchestrates publish + pull-and-apply of the Owner's mesh blob
/// against the relay's `/mesh` endpoint. Sits between the
/// [PairingStorage] (local cache) and the [MeshClient] (network).
///
/// Single source of truth for the Owner's membership is the relay
/// (plan/24); the local storage is a hydrated cache. Mutations:
///   1. write through to local storage immediately (UI responsiveness)
///   2. publish in background; on conflict/failure, the next
///      [pullAndApply] reconciles.
///
/// Reads: [pullOnDemand] runs at boot, WS reconnect, deep links;
/// [startPolling] keeps the cache fresh while the app is in foreground.
class MeshSyncService extends ChangeNotifier {
  final MeshClient _client;
  final OwnerIdentityBridge _ownerBridge;
  final PairingStorage _storage;

  /// Last version we observed locally — used as the `since` query
  /// parameter on subsequent fetches so the relay can short-circuit
  /// to 304. Reset to 0 when the Owner key changes (sync drift).
  int _lastVersion = 0;

  /// True while a publish is in flight. Used by mutation paths to
  /// avoid stampeding the relay; the queued change is picked up by
  /// the next fetch loop instead.
  bool _publishing = false;

  /// Revocation tombstones: `remote_epk`s (base64 **standard**, the
  /// blob alphabet) the user removed and whose absence is therefore
  /// authoritative over anything the relay still says.
  ///
  /// Exists because "relay is source of truth" and "revoke" are in
  /// direct conflict for the duration of a revoke publish: the 409
  /// retry re-fetches, and the apply of that fetch would write the
  /// just-revoked peer back into local storage — which the retry then
  /// re-reads and re-publishes, silently un-revoking (spec 06 T8). A
  /// tombstone makes that write impossible instead of merely
  /// improbable: [_replaceLocalCacheWith] refuses to materialise a
  /// tombstoned member, and [_publishOnce] refuses to serialise one.
  ///
  /// Lifetime: until the relay ACKs a publish that carried it (the
  /// revoke is now the relay's own state, so no fetch can contradict
  /// it), or until the user pairs that machine again — a live local
  /// record outranks a stale tombstone, otherwise a re-pair in the
  /// same session could never be published. In-memory only: a revoke
  /// that never reached the relay before the app was killed still
  /// loses to the relay's blob on the next cold start, exactly as it
  /// did before.
  final Set<String> _revoked = <String>{};

  Timer? _pollTimer;
  bool _disposed = false;

  /// Last observed [updatedAt] from the relay. Surfaced so the UI can
  /// render "last synced ... ago" if it wants to.
  int? lastUpdatedAt;

  MeshSyncService(this._client, this._ownerBridge, this._storage);

  int get lastVersion => _lastVersion;

  // -------------------------------------------------------------------------
  // Pull
  // -------------------------------------------------------------------------

  /// One-shot fetch + apply. Called from boot, WS reconnection, deep
  /// links. Returns `true` if the local cache now reflects a
  /// successfully-verified relay version (including 304 "we're up to
  /// date" and 404 "relay never had data"); `false` on failure.
  Future<bool> pullOnDemand() async {
    final pk = _ownerBridge.currentOwnerPk;
    if (pk == null) {
      return false;
    }
    final hash = await MeshClient.ownerPkHash(pk);
    final result = await _client.fetch(
      hash,
      since: _lastVersion > 0 ? _lastVersion : null,
    );
    switch (result) {
      case MeshFetchOk(envelope: final env, version: final v, updatedAt: final u):
        final applied = await _applyVerified(env, expectedOwnerPk: pk);
        if (applied) {
          _lastVersion = v;
          lastUpdatedAt = u;
          notifyListeners();
          return true;
        }
        return false;
      case MeshFetchNotModified():
        return true;
      case MeshFetchNotFound():
        return true;
      case MeshFetchFailure():
        return false;
    }
  }

  /// Verify the envelope, parse, and overwrite the local storage with
  /// the relay's view. Returns `false` when verification fails or the
  /// embedded owner_pk doesn't match the one we expected — those are
  /// silent drops (we do not touch the cache).
  Future<bool> _applyVerified(
    MeshEnvelope env, {
    required Uint8List expectedOwnerPk,
  }) async {
    final ok = await MeshBlob.verifyEnvelope(env);
    if (!ok) {
      return false;
    }
    final blob = MeshBlob.fromCanonicalBytes(env.blob);
    if (!_bytesEqual(blob.ownerPk, expectedOwnerPk)) {
      return false;
    }
    await _replaceLocalCacheWith(blob);
    return true;
  }

  /// Overwrite local peers + nicknames with what the relay says.
  /// Implements the "relay is source of truth" contract from plan/24:
  /// any peer in the local cache but absent from `blob.members` is
  /// removed; renamed nicknames propagate; relay_url updates.
  ///
  /// Uses the **silent** variants of save/delete so the mutation hook
  /// (which republishes) does not fire. Otherwise every pull would
  /// loop into a publish, and any tiny diff (timestamp precision,
  /// reordering) would round-trip back to the relay. Worse: a race
  /// between the apply-phase intermediate states and a concurrent
  /// `publish()` could observe an empty PairingStorage and ship
  /// members=[] — the bug reproduced by the user, where pi-extension
  /// self-revoked after the app silently published v2 empty.
  Future<void> _replaceLocalCacheWith(MeshBlob blob) async {
    final existing = {
      for (final p in await _storage.listPeers()) p.remoteEpk: p,
    };
    final keep = <String>{};
    for (final m in blob.members) {
      if (_revoked.contains(toStandardB64(m.remoteEpk))) {
        // Revoked locally, still listed by the relay — our version of
        // this member simply hasn't landed yet (or lost the race and is
        // about to be re-published). Leaving it out of `keep` also
        // removes any local record, so the revoke can't come back
        // through the retry that follows a 409.
        continue;
      }
      keep.add(m.remoteEpk);
      final prev = existing[m.remoteEpk];
      final next = PeerRecord(
        remoteEpk: m.remoteEpk,
        sessionName: prev?.sessionName ?? m.nickname ?? 'remote_pi',
        relayUrl: m.relayUrl,
        pairedAt: m.pairedAt,
        nickname: m.nickname,
        roomId: prev?.roomId,
      );
      if (prev == null || !_peerEqualsForMesh(prev, next)) {
        await _storage.savePeerSilent(next);
      }
    }
    for (final p in existing.values) {
      if (!keep.contains(p.remoteEpk)) {
        await _storage.deletePeerSilent(p.remoteEpk);
        await _storage.deleteRooms(p.remoteEpk);
      }
    }
  }

  /// Compare the mesh-controlled fields only — `sessionName` and
  /// `roomId` stay client-local and don't trigger a re-save when the
  /// relay version arrives unchanged.
  bool _peerEqualsForMesh(PeerRecord a, PeerRecord b) =>
      a.remoteEpk == b.remoteEpk &&
      a.relayUrl == b.relayUrl &&
      a.pairedAt == b.pairedAt &&
      a.nickname == b.nickname;

  // -------------------------------------------------------------------------
  // Publish
  // -------------------------------------------------------------------------

  /// Snapshot the current local peer list, bump version, sign, POST.
  /// Conflict (409) → re-fetch then publish again with the higher
  /// version. Network failure leaves the cache as-is — the next
  /// [pullAndApply] tick will reconcile (LWW from plan/24 § Q5).
  ///
  /// This is the additive/rename path (the [PairingStorage] mutation
  /// hook). It cannot express "remove a member": the empty-on-existing
  /// safety net below is not overridable from here, and any member the
  /// user revoked is filtered out regardless of what the local snapshot
  /// happens to contain. Removals go through [publishRevoke].
  Future<MeshPublishResult> publish() => _publishGuarded(const <String>{});

  /// Revoke [remoteEpk] and publish the membership that remains.
  ///
  /// Owns the local delete so a revoke cannot be half-performed: the
  /// tombstone is recorded before anything can be fetched, which is
  /// what makes the conflict retry safe (spec 06 T8). It is also the
  /// only door to publishing `members: []` on top of a non-zero
  /// version — that opt-out is *derived* from the tombstone instead of
  /// being a parameter, so no other caller can ask for it by mistake.
  ///
  /// Idempotent: deleting a peer that is already gone is a no-op, so
  /// the settings flow may (and does) delete locally first.
  Future<MeshPublishResult> publishRevoke(String remoteEpk) async {
    await _storage.deletePeerSilent(remoteEpk);
    return _publishGuarded({toStandardB64(remoteEpk)});
  }

  Future<MeshPublishResult> _publishGuarded(Set<String> revoking) async {
    // Record the tombstones BEFORE the in-flight check: a revoke that
    // loses the "already in flight" race must still be un-resurrectable
    // by the publish that is currently running, and by its refetch.
    _revoked.addAll(revoking);
    if (_publishing) {
      return const MeshPublishFailure('already in flight');
    }
    final pk = _ownerBridge.currentOwnerPk;
    if (pk == null) {
      return const MeshPublishFailure('owner pk not loaded');
    }
    _publishing = true;
    try {
      return await _publishOnce(pk, refetchOnConflict: true);
    } finally {
      _publishing = false;
    }
  }

  /// Derives the payload from CURRENT local storage every time it runs,
  /// including the retry after a 409 — a captured member list would be
  /// stale by exactly the mutation the conflict is telling us about.
  /// What survives across the retry is not the list but the *intent*:
  /// [_revoked] (see there) is what keeps the refetch in the middle from
  /// handing the revoked member back to us.
  Future<MeshPublishResult> _publishOnce(
    Uint8List pk, {
    required bool refetchOnConflict,
  }) async {
    final peers = await _storage.listPeers();
    // A tombstone asserts that the local ABSENCE of an epk is
    // authoritative. If it is present again, the user paired that
    // machine again and the assertion is void — drop it, otherwise a
    // re-pair in the same session could never be published. This is
    // the only way a tombstoned epk can be back in storage:
    // [_replaceLocalCacheWith] never writes one.
    _revoked.removeAll(peers.map((p) => toStandardB64(p.remoteEpk)));
    // What this publish asks the relay to forget. Captured here rather
    // than read again after the response, so a revoke recorded
    // mid-flight is not treated as ACKed by a POST it never rode in.
    final revoking = Set.of(_revoked);
    // Safety net (plan/24-fix-app-publish-race): never overwrite a
    // non-empty membership with members=[] unless we are *deliberately*
    // emptying it. "Deliberately" is not a caller-supplied flag any
    // more — it is the presence of a revoke tombstone, which only
    // [publishRevoke] can create. Everything else (mutation hook,
    // conflict retry) still gets refused, so a transient PairingStorage
    // state, an apply mid-flight or an Owner-key reset cannot
    // self-revoke pi-extension on every Pi the user owns.
    if (peers.isEmpty && _lastVersion > 0 && revoking.isEmpty) {
      return const MeshPublishFailure('refused empty-on-existing');
    }
    // Encoding gotcha: `PairingStorage.PeerRecord.remoteEpk` is whatever
    // the QR / pair_ok handed us — historically base64url (no padding).
    // The Pi-extension's self-revoke check compares `my_pubkey` (which
    // it formats as base64 STANDARD, matching `owner_pk` in the blob)
    // against the strings in `members[].remote_epk`. Mixing encodings
    // looks like "I'm not listed" → self-revoke. Normalise on the way
    // out so the blob is uniformly base64 standard, end-to-end.
    final members = peers
        .map((p) => MeshMember(
              remoteEpk: toStandardB64(p.remoteEpk),
              relayUrl: p.relayUrl,
              pairedAt: p.pairedAt,
              nickname: p.nickname,
            ))
        // Belt to the tombstone's braces: even if a peer reappeared in
        // storage between the check above and here, a revoked member is
        // never serialised into a signed blob.
        .where((m) => !revoking.contains(m.remoteEpk))
        .toList(growable: false);
    final nextVersion = _lastVersion + 1;
    final blob = MeshBlob(
      version: nextVersion,
      issuedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
      ownerPk: pk,
      members: members,
    );
    final keyPair = await _ownerBridge.requireKeyPair();
    final envelope = await blob.signWith(keyPair);
    final hash = await MeshClient.ownerPkHash(pk);
    final result = await _client.publish(hash, envelope);
    switch (result) {
      case MeshPublishOk(version: final v, updatedAt: final u):
        _lastVersion = v;
        lastUpdatedAt = u;
        // The relay now holds a blob that excludes these members, so no
        // future fetch can contradict the revoke — the tombstones have
        // done their job and must not outlive it (a stale one would
        // shadow a later re-pair until the next publish).
        _revoked.removeAll(revoking);
        notifyListeners();
        return result;
      case MeshPublishConflict():
        if (!refetchOnConflict) return result;
        // The refetch rewrites local storage with the relay's view.
        // That is safe for a revoke only because [_revoked] is still
        // set: the apply skips tombstoned members, so the re-read
        // below cannot see the peer we just removed.
        await pullOnDemand();
        return _publishOnce(pk, refetchOnConflict: false);
      case MeshPublishBadRequest():
        return result;
      case MeshPublishForbidden():
      case MeshPublishTooLarge():
      case MeshPublishFailure():
        return result;
    }
  }

  // -------------------------------------------------------------------------
  // Polling
  // -------------------------------------------------------------------------

  /// Begin periodic [pullOnDemand] every [interval] (default 60s, the
  /// Q1 value from plan/24). Idempotent — calling twice cancels the
  /// previous timer first.
  ///
  /// The host (typically the router or a top-level lifecycle observer)
  /// is responsible for stopping the polling when the app goes
  /// background and restarting it on resume.
  void startPolling({Duration interval = const Duration(seconds: 60)}) {
    stopPolling();
    _pollTimer = Timer.periodic(interval, (_) {
      // ignore: unawaited_futures
      pullOnDemand();
    });
  }

  void stopPolling() {
    if (_pollTimer != null) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  /// Reset the version watermark — used by the Owner-key-replaced
  /// path (sync drift in plan/23) so the next fetch is unconditional.
  ///
  /// Drops the revoke tombstones with it: they name peers of the
  /// *previous* Owner, whose pairings were just wiped wholesale. A new
  /// identity starts with no membership and nothing to un-revoke.
  void resetVersionWatermark() {
    _lastVersion = 0;
    lastUpdatedAt = null;
    _revoked.clear();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stopPolling();
    super.dispose();
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
