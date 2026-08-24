# Remote Pi — Protocol & Security

Documentação canônica do protocolo Remote Pi e do modelo de proteção.
Reescrita em 2026-08-24 (plano 61, Fase 4).

> **O que mudou nesta revisão.** A versão anterior descrevia um *mesh de agentes*:
> broker UDS local, envelope `{from,to,id,re,body}`, endereçamento
> `<cwd>@<agent>`, ACKs `received|busy|denied|timeout` e ferramentas
> agent-to-agent cross-PC. **Nada disso existe neste fork** — foi removido em
> `f84a33f` / `e0d9e95`, e a decisão de não restaurá-lo está registrada em
> [`plan/00-decisions.md`](plan/00-decisions.md) (plano 61, D10). O documento
> ficou meses descrevendo um sistema que não estava mais lá; quem implementasse
> a partir dele construiria o produto errado.
>
> O que sobrou do vocabulário "mesh" é **uma coisa só**: a membership assinada
> pelo Owner (`mesh_versions`), que é como o celular prova autoridade para
> parear e revogar. Ela continua viva e é descrita abaixo.

---

## Visão de 30 segundos

- **Um produto**: celular ↔ Relay ↔ Pi. Só isso.
- **Cada PC** roda o `pi-extension` com **uma Pi-key** Ed25519 no Keychain do sistema.
- **Celular** guarda a **Owner-key** Ed25519 (iOS Keychain / Android Block Store),
  que sincroniza entre devices da mesma conta.
- **Relay** WebSocket roteia App↔Pi de forma opaca e guarda/verifica os blobs
  `mesh_versions` assinados pelo Owner. Não guarda conversa, nem catálogo de sessões.
- **Sessão** é a unidade de identidade: `room_id == session_id`. Renomear é metadado.
- **Supervisor** (`pi-supervisord`) mantém uma sala de controle permanente por
  máquina, para o celular criar/parar sessões sem precisar de um Pi já aberto.

---

## Identidades

| Chave | Algoritmo | Onde mora | Quem cria | Para que serve |
|---|---|---|---|---|
| **Owner-key** | Ed25519 | iOS Keychain (sync iCloud) / Android Block Store (sync Google) | App no 1º boot | Assina `mesh_versions`; prova autoridade para parear/revogar PCs |
| **Pi-key** | Ed25519 | `@napi-rs/keyring` no PC (Keychain / libsecret / Credential Manager). Fallback `~/.pi/remote/identity.json` (`0600`) com warning em headless | pi-extension no 1º boot | Autentica a conexão WS no relay; é a identidade técnica da **máquina** |
| **App-key** | Ed25519 efêmera | RAM do app | App por sessão de pareamento | Canal autenticado durante o pair |

**Uma Pi-key por PC.** Trocar de hardware = re-parear; não há migração. A
Owner-key compensa, porque sincroniza entre devices do usuário.

> **Regra dura (plano 61 Fase 3):** o supervisor usa **a mesma Pi-key** que os
> processos de chat. Cunhar uma segunda identidade para o daemon foi o que fez o
> keyring do desktop e a unit do systemd discordarem e o self-revoke apagar
> `peers.json`.

Nas fronteiras do protocolo, Pi-key e Owner-key usam Base64 RFC 4648 **padrão,
com padding**. Formas URL-safe podem entrar, mas são normalizadas — ver
`app/lib/data/transport/epk_encoding.dart` para o histórico desse bug recorrente.

---

## Identidade de sessão (plano 61)

Esta é a parte que mais mudou. Antes:

```text
room_id = sha256(realpath(cwd))[:12]                    # nome default
room_id = sha256(realpath(cwd) + NUL + name)[:12]       # com /name
```

Ou seja: **o identificador de transporte era função de um rótulo editável**.
Renomear uma sessão re-chaveava a sala — o app via `room_ended` + uma sala nova,
ganhava um segundo tile, e a caixa Hive com a conversa ficava órfã sob o id
morto. Junto com isso, o app tratava nome, cwd e posição na lista como
identidade em vários pontos, o que produzia a classe de bug "as sessões pulam".

Agora:

```text
Machine
  machine_id   = Pi-key                     (1 por PC)
  display_name = apelido do dispositivo

Workspace
  workspace_id = daemon id = sha256(realpath(cwd))[:8]
  path         = realpath(cwd) canônico
  display_name = rótulo editável

Session
  session_id   = UUID da sessão Pi (ou o id que o supervisor cunhou)
  room_id      = session_id                 ← chave de transporte
  workspace_id
  display_name = rótulo editável, com name_rev monotônico
  mode         = interactive | background
```

Regras que o código deve preservar:

- Armazenamento, navegação, chaves de widget e ponteiros de seleção usam
  `session_id`. Nunca nome, nunca cwd, nunca índice de lista.
- **Renomear é patch de metadado.** Nunca re-chaveia `room_id`, nunca reinicia o
  Relay.
- Um Pi anterior ao plano 61 continua anunciando o id derivado antigo. O campo
  `session_id` em `room_meta` é o sinal de que a sala é estável: sua **presença**,
  não seu valor.

### Unicidade do `room_id`: por máquina, não global

O `room_id` **só tem significado dentro de uma máquina**, porque toda camada que
o usa como chave já carrega a Pi-key junto:

| Camada | Chave |
|---|---|
| Registry do relay | `(peer_id, room_id)` |
| Cache de salas do app | `Map<epk, List<RoomInfo>>` |
| Conjunto de salas vivas | `Map<epk, Set<roomId>>` |
| Mensagens (Hive) | `msgs_<epk>__<roomId>` |
| Índice de sessões (Hive) | `<epk>:<roomId>` |
| Seleção persistida | `<epk>:<roomId>` |
| Chaves de widget / cache de ações | `<epk>\|<roomId>` |

Duas máquinas emitindo o mesmo id é **inofensivo**: são entradas diferentes em
todos os lugares. Por isso **não** se prefixa o id com um device id — seria
embutir a identidade da máquina num valor que já está escopado por ela, em todo
frame, além de desfazer a identidade `room_id == session_id` que a Fase 1
estabeleceu.

O invariante que importa, e que qualquer cache novo precisa respeitar:
**nunca chavear estado persistente só pelo room id.**

Para registro: os ids do Pi são UUIDv7 (48 bits de timestamp em ms + 74 bits
aleatórios ⇒ colisão no mesmo milissegundo ≈ 2⁻⁷⁴); os cunhados pelo supervisor
são `crypto.randomUUID()` (122 bits aleatórios). Nenhum dos dois é um número
contra o qual valha a pena projetar.

---

## Camadas do protocolo

```
┌──────────────────────────────────────────────────────────────────────┐
│  Agent layer     Pi coding agent                                     │
├──────────────────────────────────────────────────────────────────────┤
│  Inner           JSON App↔Pi (user_message, agent_chunk, actions…)   │
│                  + ações de controle de máquina (sala `ctrl`)        │
├──────────────────────────────────────────────────────────────────────┤
│  Outer           {peer, room, ct} — o relay nunca abre `ct`          │
├──────────────────────────────────────────────────────────────────────┤
│  Control frames  presence / rooms / room_meta / transport_error      │
├──────────────────────────────────────────────────────────────────────┤
│  Transport       WebSocket sobre TLS                                 │
├──────────────────────────────────────────────────────────────────────┤
│  Trust           Ed25519 challenge-response + Owner-sig em mesh       │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Envelope App↔Pi

```jsonc
{ "peer": "<Pi-key ou Owner-key destino, Base64 padrão>",
  "room": "<session_id>",
  "ct":   "<Base64 do JSON interno>" }
```

O relay reescreve `peer` para o remetente autenticado e `room` para a sala de
origem antes de entregar, e **nunca** faz parse de `ct`.

> `ct` é Base64 de JSON em claro, **não** ciphertext. Ver "o que NÃO está
> protegido".

### Destino inexistente (plano 61 Fase 3)

Antes, um envelope App↔Pi para uma sala sem conexão viva era **descartado em
silêncio**: a bolha otimista do app ficava lá até um timeout de ~20s sem echo, e
não havia como distinguir "o Pi sumiu" de "o Pi está lento". Só o caminho Pi→Pi
tinha erro de transporte.

Agora o relay responde ao remetente:

```jsonc
{ "type": "transport_error", "reason": "offline",
  "peer": "<destino>", "room_id": "<sala>" }
```

É um **control frame**, escopado ao destino e não a uma mensagem: o envelope
externo não carrega id de mensagem e `ct` é opaco, então o relay não tem como
correlacionar a um frame específico nem forjar um corpo interno. O cliente
derruba o que tiver pendente para aquele `(peer, room)` e marca a sala offline na
hora.

---

## Salas, presença e metadados

Um Pi registra `(Pi-key, room_id)` no relay via `hello`. O `room_meta` do hello
carrega:

```jsonc
{ "name": "backend", "cwd": "/Users/x/proj",
  "session_id": "019ffb64-…", "workspace_path": "/Users/x/proj",
  "name_rev": 1780000000000,
  "model": "claude-sonnet-4.5", "thinking": "high", "working": false,
  "role": "control"        // só o gateway da máquina
}
```

O relay reemite isso como `room_announced` / `rooms` para quem assinou
`subscribe_rooms`, e aceita patches parciais:

```jsonc
{ "type": "room_meta_update", "room_id": "<sala>",
  "meta": { "name": "novo rótulo", "name_rev": 1780000000001 } }
```

Semântica de patch: campo ausente = **preserva**; `null` explícito = limpa (para
os campos nuláveis). `working` é bool puro — `false` já é o estado desligado.

**`name_rev` (plano 61 Fase 1).** O relay só aceita um patch de nome cuja
revisão seja **estritamente maior** que a guardada. Sem isso, um segundo device
do mesmo Owner reconectando e reenviando o patch que ele viu por último puxava o
rótulo de volta para um valor antigo. Um patch rejeitado ainda faz o relay
retransmitir o nome **vigente**, que é o que ressincroniza quem mandou errado.

`started_at` é o instante do registro no relay e **muda a cada reconexão** —
nunca use como chave nem como critério de ordenação.

---

## Plano de controle da máquina (plano 61 Fase 3)

O problema: a descoberta ia Pi → `room_announced` → app. Sem filho, sem sala;
sem sala, o celular não tinha a quem pedir. **Era preciso ter um Pi para criar
um Pi.**

O supervisor (`pi-supervisord`) mantém **uma** sala permanente por máquina:

- `room_id = "ctrl"` — reservado. Não é um digest de 12 chars nem um UUID, então
  não colide com sala de chat.
- `room_meta.role = "control"` — o app **não** renderiza como tile de chat.
- Mesma Pi-key dos filhos; o gateway roda SelfRevoke por conta própria (um
  gateway que não faz polling de membership continua podendo spawnar depois de
  revogado — backdoor).

### Ações (inner, dentro do envelope normal, endereçadas a `ctrl`)

```jsonc
{ "type": "workspace_list", "id": "<rpc>" }
{ "type": "session_list",   "id": "<rpc>", "workspace_id": "opcional" }
{ "type": "create_session", "id": "<rpc>", "idempotency_key": "<uuid>",
  "workspace_id": "…", "display_name": "opcional", "background": true }
{ "type": "session_start",  "id": "<rpc>", "session_id": "…", "idempotency_key": "<uuid>" }
{ "type": "session_stop",   "id": "<rpc>", "session_id": "…", "idempotency_key": "<uuid>" }
{ "type": "session_rename", "id": "<rpc>", "session_id": "…", "display_name": "…", "rev": 4 }
```

Respostas usam `action_ok` / `action_error`, as mesmas formas das ações de chat.

**Não se tunela o `ControlRequest` do UDS.** O protocolo local é de confiança
same-user: sem auth, validação fraca, e aceita um `cwd` arbitrário que é
spawnado com `--approve`. Expor isso pelo relay seria RCE em nível de usuário.
Por isso **nenhuma ação aqui aceita caminho**: só id de workspace **já
registrado** na máquina (`remote-pi create <pasta>`).

**Idempotência é obrigatória** nas ações que mutam. A máquina guarda a chave por
≥24h em `~/.pi/remote/sessions.json` e **repete o resultado original** — inclusive
o erro original, para que um loop de retry não vire um loop de spawn. Um frame
mutante sem `idempotency_key` é recusado, e não default-ado: um default por
tentativa não deduplica nada.

**`action_ok` significa "spawn pedido", não "sala no ar".** O app espera o
`room_announced` daquele `session_id` antes de abrir o chat. O app **nunca**
deriva um `room_id` sozinho.

### Estado desejado

`sessions.json` guarda `desired: running | stopped` por sessão. Antes, `stop` era
só em memória: o supervisor reiniciava e ressuscitava um daemon que o usuário
tinha parado de propósito.

---

## Mesh membership (Owner)

`mesh_versions` é o cartório assinado pelo Owner — **a única coisa "mesh" que
sobrou**. Nada aqui tem a ver com agentes conversando entre si.

Blob canônico assinado pelo Owner:

```json
{
  "version": 7,
  "issued_at": 1780000000000,
  "owner_pk": "<Owner-key Base64 padrão, 32B>",
  "members": [
    { "remote_epk": "<Pi-key>", "relay_url": "wss://…", "paired_at": "2026-05-22T…", "nickname": "casa" }
  ]
}
```

No wire/storage vai como `{ "blob": "<Base64 do JSON>", "sig": "<Base64 Ed25519>" }`.

- **POST /mesh/&lt;hash&gt;** publica versão nova (relay verifica assinatura +
  monotonicidade de `version`).
- **GET /mesh/&lt;hash&gt;** lê a última; o cliente valida a assinatura localmente.
- `hash` = SHA-256 hex minúsculo dos 32 bytes da Owner-key.
- LWW em conflito; anti-rollback pela `version` monotônica.

**Self-revoke**: o pi-extension (e o gateway do supervisor) fazem polling. Se a
Pi-key local sumiu de `members`, saem graciosamente.

O SQLite do relay guarda **só** isso. O catálogo de sessões vive na máquina
(plano 61 D7).

> **Nota sobre `pi_envelope`.** O relay ainda tem o caminho de forward Pi→Pi com
> autorização por co-membership assinada (`relay/src/handlers/pi_forward.rs`).
> **Este fork não o usa** — nenhum código do pi-extension emite `pi_envelope`.
> Está documentado aqui para quem lê o código do relay e se pergunta o que é.

---

## Pareamento

O QR mostra Pi-pubkey + hint de sala + token de uso único.

1. App escaneia, conecta ao relay como peer efêmero
2. App manda `pair_request` assinado com a **Owner-sk**
3. Pi-extension valida e grava a Owner-key em `peers.json`
4. App adiciona a Pi-key no `mesh_versions` e publica a versão nova
5. Pi passa a aceitar mensagens daquele Owner

O `pair_ok` devolve, além do histórico `session_name` / `room_id`, a identidade
de sessão do plano 61: `session_id`, `workspace_path`, `display_name`, `name_rev`
— para o app já chavear por sessão desde o primeiro frame.

Vários Owners podem parear o mesmo PC.

Detalhes em [`plan/04-pairing.md`](plan/04-pairing.md).

---

## App actions (sessão)

| Ação | ClientMessage | Chamada no pi-extension |
|---|---|---|
| Compact context | `session_compact` | `ctx.compact()` |
| New **context** | `session_new` | `ctx.newSession()` (mesmo processo, mesma sessão) |
| Set model | `model_set {provider, model_id}` | `ModelRegistry.find(...)` + `pi.setModel(...)` |
| Set thinking | `thinking_set {level}` | `pi.setThinkingLevel(level)` |
| List models | `list_models` | `ModelRegistry.getAvailable()` |
| Rename | `session_rename {display_name, session_id?, rev?}` | `setSessionName` + patch de `room_meta` |

> **`session_new` não cria sessão.** Ele limpa o contexto **da mesma** sessão. A
> UI chama isso de "New Context". Criar sessão de verdade é `create_session`, no
> plano de controle da máquina.

`session_rename` usa concorrência otimista: `rev` é a `name_rev` que o device
viu por último. Se o Pi já tem uma maior, outro device renomeou antes e o pedido
é **recusado** em vez de sobrescrever calado.

Níveis de thinking: `off | minimal | low | medium | high | xhigh`.

---

## Imagens

Anexadas ao `user_message` imediato:

```jsonc
{ "type": "user_message", "id": "…", "text": "…",
  "images": [ { "data": "<base64 sem prefixo data:>", "mime": "image/jpeg" } ] }
```

O Pi mapeia para o `{type:"image", data, mimeType}` do SDK. O teto do envelope
externo é 4 MiB de payload decodificado (`RELAY_MAX_CT_MIB`), com folga para o
duplo Base64.

---

## Mensagem enfileirada durante turn ativo

Só texto; imagens seguem apenas no `user_message` imediato. As filas internas do
Pi/TUI não são expostas — a API da extension não dá ids estáveis nem mutação
segura delas.

---

## Modelo de proteção

### O que está protegido

- **Pareamento autenticado**: `pair_request` assinado pela Owner-sk.
- **WS sobre TLS**: ninguém na rota vê o tráfego em claro.
- **Plano de controle Owner-only**: o gateway só aceita frames de peer presente
  em `peers.json`, e roda SelfRevoke.
- **Sem caminhos no wire de controle**: só workspace já registrado localmente.
- **Idempotência**: retry não vira spawn duplicado.
- **Pi-secret e Owner-secret** em keystore do sistema.
- **Anti-rollback de membership em processo**: versão monotônica + assinatura.
  O floor reinicia com o processo; persistência entre reinícios não é implementada.

### O que NÃO está protegido (declarado honestamente)

- **O relay vê o conteúdo em claro.** TLS protege o trânsito, mas `ct` é Base64
  de JSON, não ciphertext. O operador vê quem fala com quem e o quê.
  Mitigação: **self-hosting**.
- **Não há E2E.** Não afirmamos E2E em nenhuma copy do produto.
- **Headless Linux** sem D-Bus: a Pi-key cai para arquivo `0600` com warning.
- **Backup completo criptografado** pode carregar o Keychain.
- **Clone detection não implementada**: dois PCs com a mesma Pi-key coexistem no
  relay sem alerta.
- **O gateway pode spawnar processos.** É o ponto: qualquer Owner pareado pode
  iniciar um `pi` em pasta já registrada daquela máquina. Revogar o pareamento é
  o que tira essa capacidade — e é por isso que o SelfRevoke no gateway não é
  opcional.

### Threat model resumido

| Adversário | Capacidade | Protegido? |
|---|---|---|
| Rede passiva | Sniff TLS | ✅ |
| Rede ativa (MITM) | Sniff + inject | ✅ (TLS + Ed25519) |
| Operador do relay público | Lê e persiste o que passa | ⚠️ Parcial (self-host) |
| Outro usuário no PC alvo | Lê filesystem | ✅ (keystore user-bound) |
| Root no PC alvo | Memory dump, injection | ❌ (root = jogo perdido) |
| Owner revogado | Tenta spawnar via `ctrl` | ✅ (SelfRevoke no gateway) |
| Quem rouba só `peers.json` | Vê metadata pública | Privacidade, não impersonation |

---

## Failure modes

| Falha | Comportamento |
|---|---|
| Relay cai | pi-extension reconecta com backoff; o app zera seu conjunto de salas vivas e só volta ao verde quando o relay reanuncia |
| Pi da sala offline no envio | O remetente recebe `transport_error: offline` e a sala fica cinza na hora. Sem fila offline no relay |
| Owner revoga o PC | Detectado no próximo poll de `mesh_versions`; self-revoke gracioso, inclusive no gateway |
| Supervisor reinicia | Reabre a sala `ctrl` e respeita `desired` — sessão parada de propósito **não** ressuscita |
| `create_session` reenviado (link ruim) | Mesma `idempotency_key` ⇒ mesma resposta, sem segundo processo |
| Renomeio simultâneo em dois devices | O de `name_rev` menor é recusado; ambos convergem para o nome vigente |
| WS do Pi reconecta muito (NAT) | O relay dedupa `peer_online`; o cliente dedupa snapshots idênticos |

---

## Implementações de referência

- **Relay** (Rust, axum): [`relay/src/`](relay/src/)
- **Pi-extension** (Node/TS): [`pi-extension/src/`](pi-extension/src/)
- **App** (Flutter): [`app/lib/`](app/lib/)
- **Planos**: [`plan/`](plan/) — em especial
  [`61-stable-session-identity.md`](plan/61-stable-session-identity.md),
  [`23-owner-key-sync.md`](plan/23-owner-key-sync.md),
  [`24-mesh-membership.md`](plan/24-mesh-membership.md)
- **Auditorias que motivaram o plano 61**: [`review/`](review/)

---

## Reportar problemas de segurança

[Definir canal] — por enquanto, abra issue marcando como `security` ou contate
os maintainers diretamente.
