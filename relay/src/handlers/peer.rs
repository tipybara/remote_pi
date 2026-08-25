use std::net::SocketAddr;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, State};
use axum::response::Response;
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::time::{self, Duration};
use tracing::{info, warn};

use crate::AppState;
use crate::auth::challenge::{
    HELLO_TIMEOUT_MS, challenge_line, gen_nonce, parse_hello, verify_auth,
};
use crate::protocol::outer::{OuterEnvelope, parse_line};
use crate::rooms::{RoomMeta, RoomMetaPatch};

/// Axum route handler: validates the WebSocket upgrade and hands the upgraded
/// socket to `handle_peer`, which owns the connection for its lifetime.
pub async fn ws_handler(
    ws: WebSocketUpgrade,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
) -> Response {
    ws.on_upgrade(move |socket| handle_peer(socket, addr, state))
}

/// Owns one peer's WebSocket connection: hello/challenge/auth → register →
/// routing loop (forwarding outer envelopes + handling presence/rooms control
/// frames + sending 25 s keepalive pings) → unregister on disconnect.
async fn handle_peer(socket: WebSocket, peer_addr: SocketAddr, state: AppState) {
    let peer_addr = peer_addr.to_string();
    let (mut sink, mut stream) = socket.split();

    // ── 1. Wait for hello (with timeout) ──────────────────────────────────
    let hello_result =
        tokio::time::timeout(Duration::from_millis(HELLO_TIMEOUT_MS), stream.next()).await;

    let hello_text = match hello_result {
        Ok(Some(Ok(Message::Text(t)))) => t,
        _ => {
            warn!(addr = %peer_addr, "no hello received, closing");
            return;
        }
    };

    let vk = match parse_hello(&hello_text) {
        Ok(vk) => vk,
        Err(e) => {
            warn!(addr = %peer_addr, err = %e, "bad hello, closing");
            return;
        }
    };

    // ── 2. Send challenge ─────────────────────────────────────────────────
    let (nonce, nonce_b64) = gen_nonce();
    if sink
        .send(Message::Text(challenge_line(&nonce_b64)))
        .await
        .is_err()
    {
        return;
    }

    // ── 3. Receive and verify auth ────────────────────────────────────────
    let auth_text = match stream.next().await {
        Some(Ok(Message::Text(t))) => t,
        _ => return,
    };

    if let Err(e) = verify_auth(&nonce, &vk, &auth_text) {
        warn!(addr = %peer_addr, err = %e, "auth failed, closing");
        let _ = sink.send(Message::Close(None)).await;
        return;
    }

    let peer_id = B64.encode(vk.to_bytes());
    let peer_short = peer_id[peer_id.len().saturating_sub(8)..].to_string();

    // Extract room_id and room_meta from hello (auth handled separately above).
    let room_meta = {
        let hello: serde_json::Value =
            serde_json::from_str(&hello_text).unwrap_or(serde_json::Value::Null);
        let room_id = hello
            .get("room_id")
            .and_then(|v| v.as_str())
            .unwrap_or("main")
            .to_string();
        let room_meta_val = hello.get("room_meta");
        let name = room_meta_val
            .and_then(|m| m.get("name"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let cwd = room_meta_val
            .and_then(|m| m.get("cwd"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let model = room_meta_val
            .and_then(|m| m.get("model"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let thinking = room_meta_val
            .and_then(|m| m.get("thinking"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let working = room_meta_val
            .and_then(|m| m.get("working"))
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        // ── plan 61 Phase 1 — session identity carried in the hello ──
        //
        // All three are opaque to the relay; it stores and re-broadcasts
        // them so the app can key by session instead of by (cwd, name).
        // A pre-Phase-1 Pi omits them and everything below stays `None`,
        // which is exactly the legacy behaviour.
        let session_id = room_meta_val
            .and_then(|m| m.get("session_id"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let workspace_path = room_meta_val
            .and_then(|m| m.get("workspace_path"))
            .and_then(|v| v.as_str())
            .map(String::from)
            // Legacy Pis only send `cwd`; it holds the same canonical
            // realpath, so treat it as the workspace key rather than
            // leaving Phase 2's grouping blind.
            .or_else(|| cwd.clone());
        let name_rev = room_meta_val
            .and_then(|m| m.get("name_rev"))
            .and_then(|v| v.as_i64());
        // plan 61 Phase 3 — `role: "control"` marks the supervisor gateway's
        // `ctrl` room so the app can skip it when rendering chat tiles.
        let role = room_meta_val
            .and_then(|m| m.get("role"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let started_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        RoomMeta {
            room_id,
            session_id,
            workspace_path,
            name_rev,
            role,
            name,
            cwd,
            model,
            thinking,
            working,
            started_at,
        }
    };
    let room_id = room_meta.room_id.clone();

    info!(peer = %peer_short, room = %room_id, addr = %peer_addr, "authenticated");

    let registry = state.registry.clone();
    let presence = state.presence.clone();
    let rooms = state.rooms.clone();
    let mesh = state.mesh.clone();
    let mesh_auth = state.mesh_auth.clone();
    let metrics = state.metrics.clone();

    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
    let conn_id = registry.register(peer_id.clone(), room_meta, tx).await;

    // Plan 62 state-sync audit — the per-conn dedup that used to live here
    // (suppressing a `presence`/`rooms` reply identical to the previous one)
    // is deliberately GONE, and must not come back.
    //
    // `presence_check` / `rooms_check` are POLLS: the client asks precisely
    // because it suspects its own copy is wrong. Answering "same as last
    // time, so silence" makes any client-side divergence within one
    // connection unrecoverable — the client's only resync channel stops
    // answering exactly when it is needed. That was the second half of the
    // permanent false-offline bug: a client that locally marked a room dead
    // (missed inner pings) could never learn it was alive again, because the
    // relay's view had never changed and the check reply was suppressed.
    //
    // The firehose this dedup once guarded against was the app re-sending
    // checks on every peer-storage mutation; plan 61 Phase 0 removed that
    // churn at the source. Unsolicited pushes keep their own edge-triggered
    // dedup in the registry (`was_offline_before` / `is_first_in_room`) —
    // this change is only about answering direct questions.

    // ── 4. Routing loop ───────────────────────────────────────────────────
    // Send a WS Ping every 25 s so NAT/LB idle timers don't close the connection.
    // First tick fires after 25 s (not immediately).
    let mut heartbeat = time::interval_at(
        time::Instant::now() + Duration::from_secs(25),
        Duration::from_secs(25),
    );

    'routing: loop {
        tokio::select! {
            item = stream.next() => {
                match item {
                    None | Some(Err(_)) => break,
                    Some(Ok(msg)) => {
                        let text = match msg {
                            Message::Text(t) => t,
                            Message::Close(_) => break,
                            // Pong frames are keepalive responses; Ping frames are
                            // answered automatically by axum's WS. Drop both.
                            Message::Ping(_) | Message::Pong(_) => continue,
                            Message::Binary(_) => continue, // ignore binary
                        };

                        // Parse as JSON to check for relay control frames.
                        let frame: serde_json::Value = match serde_json::from_str(&text) {
                            Ok(v) => v,
                            Err(e) => {
                                warn!(peer = %peer_short, err = %e, "invalid json, dropping");
                                continue;
                            }
                        };

                        // Frames with a top-level "type" are handled by the relay itself.
                        if let Some(t) = frame.get("type").and_then(|v| v.as_str()) {
                            let peers: Vec<String> = frame
                                .get("peers")
                                .and_then(|v| v.as_array())
                                .map(|arr| {
                                    arr.iter()
                                        .filter_map(|v| v.as_str().map(String::from))
                                        .collect()
                                })
                                .unwrap_or_default();

                            match t {
                                // ── presence control frames (plano 12) ──
                                "subscribe_presence" => {
                                    presence.subscribe(peer_id.clone(), peers.clone()).await;
                                    // Backfill: push peer_online for any already-online
                                    // peers in the list, so subscribers don't have to
                                    // call presence_check to discover current state.
                                    registry.backfill_presence(&peer_id, &peers);
                                }
                                "unsubscribe_presence" => {
                                    presence.unsubscribe(&peer_id, peers).await;
                                }
                                "presence_check" => {
                                    let states = presence
                                        .snapshot(&peers, |p| registry.is_online(p))
                                        .await;
                                    let resp = serde_json::json!({
                                        "type": "presence",
                                        "states": states,
                                    })
                                    .to_string();
                                    // A poll is always answered — see the
                                    // audit note above the routing loop.
                                    if sink.send(Message::Text(resp)).await.is_err() {
                                        break;
                                    }
                                    metrics.inc_presence_emitted(1);
                                }

                                // ── rooms control frames (plano 17) ──
                                "subscribe_rooms" => {
                                    rooms.subscribe(peer_id.clone(), peers).await;
                                }
                                "unsubscribe_rooms" => {
                                    rooms.unsubscribe(&peer_id, peers).await;
                                }
                                "rooms_check" => {
                                    for target_peer in &peers {
                                        let active_rooms = registry.rooms_of(target_peer);
                                        let resp = serde_json::json!({
                                            "type": "rooms",
                                            "peer": target_peer,
                                            "rooms": active_rooms,
                                        })
                                        .to_string();
                                        // A poll is always answered — see the
                                        // audit note above the routing loop.
                                        if sink.send(Message::Text(resp)).await.is_err() {
                                            break 'routing;
                                        }
                                        metrics.inc_rooms_emitted(1);
                                    }
                                }

                                // ── room meta update (plano 18 + 28 + 32) ──
                                // `meta.model`, `meta.thinking` and
                                // `meta.working` are patched independently: a
                                // field absent from `meta` is *left alone* on
                                // the room (not cleared). For the nullable
                                // string fields, an explicit `null` clears
                                // them. `working` is a plain bool, so it only
                                // ever toggles — a non-bool/absent value leaves
                                // it untouched. Mirrors the JSON Merge Patch
                                // shape clients already produce.
                                "room_meta_update" => {
                                    let target_room = frame
                                        .get("room_id")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or(&room_id)
                                        .to_string();
                                    let meta_obj = frame
                                        .get("meta")
                                        .and_then(|v| v.as_object());
                                    let model_patch = meta_obj
                                        .and_then(|m| m.get("model"))
                                        .map(|v| v.as_str().map(String::from));
                                    let thinking_patch = meta_obj
                                        .and_then(|m| m.get("thinking"))
                                        .map(|v| v.as_str().map(String::from));
                                    let working_patch = meta_obj
                                        .and_then(|m| m.get("working"))
                                        .and_then(|v| v.as_bool());
                                    // plan 61 Phase 1 — a rename is now a
                                    // patch. `name_rev` (when present) orders
                                    // competing renames; see
                                    // `RoomMeta::name_rev`.
                                    let name_patch = meta_obj
                                        .and_then(|m| m.get("name"))
                                        .map(|v| v.as_str().map(String::from));
                                    let name_rev_patch = meta_obj
                                        .and_then(|m| m.get("name_rev"))
                                        .and_then(|v| v.as_i64());
                                    let patch = RoomMetaPatch {
                                        model: model_patch,
                                        thinking: thinking_patch,
                                        working: working_patch,
                                        name: name_patch,
                                        name_rev: name_rev_patch,
                                    };
                                    if !registry
                                        .update_room_meta(&peer_id, &target_room, patch)
                                        .await
                                    {
                                        warn!(
                                            peer = %peer_short,
                                            room = %target_room,
                                            "room_meta_update for unknown (peer, room), dropping"
                                        );
                                    }
                                }

                                // ── Pi-to-Pi envelope forward (plano 25 W-A) ──
                                "pi_envelope" => {
                                    use crate::handlers::pi_forward::{
                                        PiForwardResult, handle_pi_envelope,
                                    };
                                    match handle_pi_envelope(
                                        &peer_id,
                                        &frame,
                                        &registry,
                                        mesh.clone(),
                                        mesh_auth.clone(),
                                    )
                                    .await
                                    {
                                        PiForwardResult::Forwarded => {}
                                        PiForwardResult::TransportError(err_msg) => {
                                            if sink.send(err_msg).await.is_err() {
                                                break;
                                            }
                                        }
                                    }
                                }

                                _ => {
                                    warn!(
                                        peer = %peer_short,
                                        frame_type = %t,
                                        "unknown control frame type, dropping"
                                    );
                                }
                            }
                            continue; // do not fall through to envelope path
                        }

                        // No "type" field → outer envelope (opaque routing).
                        match parse_line(&text) {
                            Err(e) => {
                                warn!(peer = %peer_short, err = %e, "invalid envelope, dropping");
                            }
                            Ok(env) => {
                                let ct_len = env.ct.len();
                                let dest_peer = env.peer;
                                let dest_room = env.room;
                                let dest_tail =
                                    dest_peer[dest_peer.len().saturating_sub(8)..].to_string();
                                // Rewrite: recipient sees sender's peer_id + sender's room_id.
                                let rewritten = OuterEnvelope {
                                    peer: peer_id.clone(),
                                    room: room_id.clone(),
                                    ct: env.ct,
                                };
                                let fwd_line = serde_json::to_string(&rewritten)
                                    .expect("OuterEnvelope serialisation is infallible");
                                // Skip-sender: pass our own conn_id so multi-device
                                // Owners don't echo their own outbound messages.
                                if !registry.forward(
                                    &dest_peer,
                                    &dest_room,
                                    Message::Text(fwd_line),
                                    conn_id,
                                ) {
                                    warn!(
                                        from = %peer_short,
                                        dest = %dest_tail,
                                        room = %dest_room,
                                        bytes = ct_len,
                                        "dest (peer, room) not found, dropping",
                                    );
                                    // plan 61 Phase 3 — tell the sender.
                                    //
                                    // App↔Pi used to fail COMPLETELY silently:
                                    // the app kept an optimistic bubble until a
                                    // ~20 s no-echo timeout swept it away, with
                                    // no way to distinguish "the Pi is gone"
                                    // from "the Pi is slow". Only the Pi→Pi
                                    // `pi_envelope` path had a transport error.
                                    //
                                    // The outer envelope carries no message id
                                    // (peer/room/ct only) and `ct` is opaque, so
                                    // the relay cannot correlate to a single
                                    // message nor synthesize an inner body. The
                                    // error is therefore a CONTROL frame scoped
                                    // to the destination: the client fails the
                                    // sends outstanding for that (peer, room).
                                    let err = serde_json::json!({
                                        "type": "transport_error",
                                        "reason": "offline",
                                        "peer": dest_peer,
                                        "room_id": dest_room,
                                    })
                                    .to_string();
                                    if sink.send(Message::Text(err)).await.is_err() {
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            result = rx.recv() => {
                match result {
                    Some(msg) => {
                        if sink.send(msg).await.is_err() {
                            break;
                        }
                    }
                    None => break,
                }
            }
            _ = heartbeat.tick() => {
                if sink.send(Message::Ping(Vec::new())).await.is_err() {
                    break;
                }
            }
        }
    }

    registry.unregister(&peer_id, &room_id, conn_id).await;
    rooms.unsubscribe_all(&peer_id).await;
    info!(peer = %peer_short, room = %room_id, addr = %peer_addr, "disconnected");
}
