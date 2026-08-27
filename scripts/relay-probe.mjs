// Protocol conformance probe for a LIVE relay deployment.
//
//   node scripts/relay-probe.mjs wss://relay.tengfei.site
//
// Six checks, pinned to the plan-61/62 protocol: session identity in the
// rooms snapshot (T1), polls always answered (T2, audit D2), rename as a
// name_rev-gated metadata patch (T3/T4), transport_error on dest-miss (T5),
// and plain envelope delivery as the regression guard (T6). Exit 0 = all
// pass. Run BEFORE and AFTER swapping the binary — the before-run against a
// pre-plan-61 relay legitimately fails T1-T5 and proves the probe can fail.
//
// First used 2026-08-27 to upgrade relay.tengfei.site (Aug-10 binary → dev
// @1e0681f): before 1/5, after 6/6, with a live legacy pi-extension
// reconnecting through the restart untouched.
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
// Borrow `ws` from pi-extension's node_modules, same as fake-pi.mjs — no
// dependency is added anywhere. Resolved relative to this file, not to a
// hardcoded absolute path.
const require = createRequire(
  join(dirname(fileURLToPath(import.meta.url)), '..', 'pi-extension', 'package.json'),
);
const WebSocket = require('ws');
import { generateKeyPairSync, sign as edSign, createPublicKey } from 'node:crypto';

const RELAY = process.argv[2] || 'wss://relay.tengfei.site';
const b64 = (buf) => Buffer.from(buf).toString('base64');

function keypair() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
  return { raw, privateKey };
}

function connect(kp, roomId, roomMeta) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(RELAY);
    const inbox = [];
    const waiters = [];
    ws.on('message', (d) => {
      const line = d.toString();
      let j; try { j = JSON.parse(line); } catch { return; }
      const w = waiters.findIndex((f) => f.pred(j));
      if (w >= 0) waiters.splice(w, 1)[0].res(j); else inbox.push(j);
    });
    ws.on('error', reject);
    ws.on('open', () => {
      ws.send(JSON.stringify({ type: 'hello', pubkey: b64(kp.raw), room_id: roomId, ...(roomMeta ? { room_meta: roomMeta } : {}) }));
    });
    const api = {
      ws, inbox,
      send: (o) => ws.send(JSON.stringify(o)),
      wait: (pred, ms = 5000, tag = '?') => new Promise((res, rej) => {
        const hit = inbox.findIndex(pred);
        if (hit >= 0) return res(inbox.splice(hit, 1)[0]);
        const t = setTimeout(() => { const i = waiters.findIndex(x => x.res === res); if (i>=0) waiters.splice(i,1); rej(new Error('timeout: ' + tag)); }, ms);
        waiters.push({ pred, res: (v) => { clearTimeout(t); res(v); } });
      }),
    };
    api.wait((j) => j.type === 'challenge', 5000, 'challenge').then((ch) => {
      const nonce = Buffer.from(ch.nonce, 'base64');
      const sig = edSign(null, nonce, kp.privateKey);
      api.send({ type: 'auth', sig: b64(sig) });
      // no auth-ok frame; relay just proceeds. resolve after a beat.
      setTimeout(() => resolve(api), 300);
    }).catch(reject);
  });
}

const results = [];
const check = (name, ok, extra = '') => { results.push([ok ? 'PASS' : 'FAIL', name, extra]); console.log((ok ? '✅' : '❌') + ' ' + name + (extra ? '  — ' + extra : '')); };

const pi = keypair();
const app = keypair();
const piId = b64(pi.raw);
const SESSION = '0199aaaa-1111-7abc-8def-0123456789ab';

// Pi opens a session room with full plan-61 meta
const piConn = await connect(pi, SESSION, {
  name: 'probe-session', cwd: '/tmp/probe', workspace_path: '/tmp/probe',
  session_id: SESSION, name_rev: 1000, model: 'probe-model', working: false,
});

// App connects on main, subscribes
const appConn = await connect(app, 'main');
appConn.send({ type: 'subscribe_rooms', peers: [piId] });
appConn.send({ type: 'rooms_check', peers: [piId] });

// T1: rooms snapshot carries plan-61 fields
try {
  const rooms = await appConn.wait((j) => j.type === 'rooms' && j.peer === piId, 5000, 'rooms');
  const r = (rooms.rooms || [])[0] || {};
  check('T1 rooms snapshot carries session_id/workspace_path/name_rev',
    r.session_id === SESSION && r.workspace_path === '/tmp/probe' && r.name_rev === 1000,
    JSON.stringify({ session_id: r.session_id, workspace_path: r.workspace_path, name_rev: r.name_rev }));
} catch (e) { check('T1 rooms snapshot carries plan-61 fields', false, e.message); }

// T2 (D2): identical second poll is still answered
try {
  appConn.send({ type: 'rooms_check', peers: [piId] });
  await appConn.wait((j) => j.type === 'rooms' && j.peer === piId, 4000, 'second rooms reply');
  check('T2 identical rooms_check answered again (audit D2)', true);
} catch (e) { check('T2 identical rooms_check answered again (audit D2)', false, e.message); }

// T3: rename is a metadata patch guarded by name_rev
try {
  piConn.send({ type: 'room_meta_update', room_id: SESSION, meta: { name: 'renamed-by-probe', name_rev: 1001 } });
  const upd = await appConn.wait((j) => j.type === 'room_meta_updated' && j.room_id === SESSION, 5000, 'meta update');
  check('T3 rename patch broadcast with name/name_rev',
    upd.meta?.name === 'renamed-by-probe' && upd.meta?.name_rev === 1001, JSON.stringify(upd.meta));
  // stale rev must lose but still re-broadcast the winner
  piConn.send({ type: 'room_meta_update', room_id: SESSION, meta: { name: 'stale-loser', name_rev: 999 } });
  const upd2 = await appConn.wait((j) => j.type === 'room_meta_updated' && j.room_id === SESSION, 5000, 'stale rebroadcast');
  check('T4 stale name_rev rejected, current name re-broadcast', upd2.meta?.name === 'renamed-by-probe', JSON.stringify(upd2.meta));
} catch (e) { check('T3/T4 name_rev gating', false, e.message); }

// T5 (Phase 3): dest-miss answers transport_error instead of silence
try {
  appConn.send({ peer: piId, room: 'no-such-room', ct: Buffer.from('{"type":"ping","id":"x"}').toString('base64') });
  const te = await appConn.wait((j) => j.type === 'transport_error', 5000, 'transport_error');
  check('T5 dest-miss answers transport_error', te.reason === 'offline' && te.room_id === 'no-such-room', JSON.stringify(te));
} catch (e) { check('T5 dest-miss answers transport_error', false, e.message); }

// T6: real delivery still works end to end (envelope through relay)
try {
  const ct = Buffer.from(JSON.stringify({ type: 'ping', id: 'probe-1' })).toString('base64');
  appConn.send({ peer: piId, room: SESSION, ct });
  const env = await piConn.wait((j) => j.ct && j.peer, 5000, 'delivered envelope');
  const inner = JSON.parse(Buffer.from(env.ct, 'base64').toString());
  check('T6 envelope delivery + peer/room rewrite', inner.id === 'probe-1' && env.room === 'main', 'from room=' + env.room);
} catch (e) { check('T6 envelope delivery', false, e.message); }

piConn.ws.close(); appConn.ws.close();
const failed = results.filter(r => r[0] === 'FAIL').length;
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
