import { createHash } from "node:crypto";
import { describe, expect, test, vi } from "vitest";
import {
  ed25519Sign,
  generateEd25519Keypair,
  type Ed25519Keypair,
} from "../pairing/crypto.js";
import type { MeshClient } from "./client.js";
import { SelfRevoke, type SelfRevokeStorage } from "./self_revoke.js";
import type { MeshEnvelope } from "./types.js";

function standardKey(keypair: Ed25519Keypair): string {
  return Buffer.from(keypair.publicKey).toString("base64");
}

function urlSafeKey(keypair: Ed25519Keypair): string {
  return Buffer.from(keypair.publicKey).toString("base64url");
}

function ownerHash(owner: Ed25519Keypair): string {
  return createHash("sha256").update(owner.publicKey).digest("hex");
}

function makeEnvelope(
  owner: Ed25519Keypair,
  version: number,
  members: readonly Ed25519Keypair[],
): MeshEnvelope {
  const blob = new TextEncoder().encode(JSON.stringify({
    version,
    issued_at: 1_700_000_000_000,
    owner_pk: standardKey(owner),
    members: members.map((member, index) => ({
      remote_epk: standardKey(member),
      relay_url: "wss://relay.test",
      paired_at: `2026-05-22T0${index}:00:00Z`,
    })),
  }));
  return { blob, sig: ed25519Sign(owner.secretKey, blob) };
}

function client(get: ReturnType<typeof vi.fn>): MeshClient {
  return { get } as unknown as MeshClient;
}

function storage(
  rawOwners: unknown[],
  conditionalRemovePeer = vi.fn(async () => ({
    outcome: "removed" as const,
    nextToken: "next",
  })),
): SelfRevokeStorage {
  return {
    snapshotOwnerPubkeys: vi.fn(async () => rawOwners.map((rawOwnerPubkey) => ({
      rawOwnerPubkey,
      token: String(rawOwnerPubkey),
    }))),
    conditionalRemovePeer,
  };
}

function silentLog() {
  return { info: vi.fn(), warn: vi.fn(), error: vi.fn() };
}

describe("SelfRevoke signed Owner membership", () => {
  test("deduplicates canonical Owner keys and keeps signed self membership", async () => {
    const owner = generateEd25519Keypair();
    const self = generateEd25519Keypair();
    const get = vi.fn(async () => makeEnvelope(owner, 1, [self]));
    const remove = vi.fn(async () => ({ outcome: "removed" as const, nextToken: "next" }));
    const onAuthoritativeOwners = vi.fn();
    const revoker = new SelfRevoke({
      client: client(get),
      storage: storage([urlSafeKey(owner), standardKey(owner)], remove),
      myPubkey: self.publicKey,
      onAuthoritativeOwners,
      log: silentLog(),
    });

    await revoker.checkOnce();

    expect(get).toHaveBeenCalledOnce();
    expect(get).toHaveBeenCalledWith(ownerHash(owner), undefined);
    expect(remove).not.toHaveBeenCalled();
    expect(onAuthoritativeOwners).toHaveBeenCalledWith([standardKey(owner)]);
  });

  test("signed membership removal revokes every exact stored Owner handle", async () => {
    const owner = generateEd25519Keypair();
    const self = generateEd25519Keypair();
    const other = generateEd25519Keypair();
    const rawOwners = [urlSafeKey(owner), standardKey(owner)];
    const remove = vi.fn(async () => ({ outcome: "removed" as const, nextToken: "next" }));
    const onRevoke = vi.fn();
    const revoker = new SelfRevoke({
      client: client(vi.fn(async () => makeEnvelope(owner, 2, [other]))),
      storage: storage(rawOwners, remove),
      myPubkey: self.publicKey,
      onRevoke,
      log: silentLog(),
    });

    await revoker.checkOnce();

    expect(remove).toHaveBeenCalledTimes(2);
    expect(remove.mock.calls.map(([raw]) => raw).sort()).toEqual([...rawOwners].sort());
    expect(onRevoke).toHaveBeenCalledTimes(2);
    for (const [raw, canonical] of onRevoke.mock.calls) {
      expect(rawOwners).toContain(raw);
      expect(canonical).toBe(standardKey(owner));
    }
  });

  test("invalid signature never revokes local Owner storage", async () => {
    const owner = generateEd25519Keypair();
    const self = generateEd25519Keypair();
    const envelope = makeEnvelope(owner, 3, []);
    envelope.sig[0] = envelope.sig[0]! ^ 0xff;
    const remove = vi.fn(async () => ({ outcome: "removed" as const, nextToken: "next" }));
    const log = silentLog();
    const revoker = new SelfRevoke({
      client: client(vi.fn(async () => envelope)),
      storage: storage([standardKey(owner)], remove),
      myPubkey: self.publicKey,
      log,
    });

    await revoker.checkOnce();

    expect(remove).not.toHaveBeenCalled();
    expect(log.warn).toHaveBeenCalledWith(expect.stringContaining("owner_envelope_invalid"));
  });

  test("anti-rollback floor rejects older signed revocation", async () => {
    const owner = generateEd25519Keypair();
    const self = generateEd25519Keypair();
    const get = vi.fn()
      .mockResolvedValueOnce(makeEnvelope(owner, 5, [self]))
      .mockResolvedValueOnce(makeEnvelope(owner, 4, []));
    const remove = vi.fn(async () => ({ outcome: "removed" as const, nextToken: "next" }));
    const revoker = new SelfRevoke({
      client: client(get),
      storage: storage([standardKey(owner)], remove),
      myPubkey: self.publicKey,
      log: silentLog(),
    });

    await revoker.checkOnce();
    await revoker.checkOnce();

    expect(get).toHaveBeenNthCalledWith(2, ownerHash(owner), 5);
    expect(remove).not.toHaveBeenCalled();
  });

  test("stop invalidates delayed storage-removal authority", async () => {
    const owner = generateEd25519Keypair();
    const self = generateEd25519Keypair();
    const other = generateEd25519Keypair();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const remove = vi.fn(async (_raw: string, _token: unknown, canCommit?: () => boolean) => {
      await gate;
      return canCommit?.()
        ? { outcome: "removed" as const, nextToken: "next" }
        : { outcome: "no_authority" as const };
    });
    const onRevoke = vi.fn();
    const revoker = new SelfRevoke({
      client: client(vi.fn(async () => makeEnvelope(owner, 1, [other]))),
      storage: storage([standardKey(owner)], remove),
      myPubkey: self.publicKey,
      onRevoke,
      log: silentLog(),
    });

    const checking = revoker.checkOnce();
    await vi.waitFor(() => expect(remove).toHaveBeenCalledOnce());
    revoker.stop();
    release();
    await checking;

    expect(onRevoke).not.toHaveBeenCalled();
  });
});
