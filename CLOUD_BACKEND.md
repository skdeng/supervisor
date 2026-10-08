# Cloud Backend Investigation: peer taps and emoji between SuperVisor users

This note investigates what it would take for SuperVisor users to connect their apps to each other
and exchange tiny ephemeral signals — an emoji, or a "tap" in the Apple Watch Digital Touch sense —
with the result arriving in the other person's notch. It covers what the codebase already offers,
the backend options and how each fits a Developer-ID-signed SwiftPM menu-bar app, a recommended
architecture, the client module that would consume it, and the risks. Nothing here is implemented.

The working name for the feature is **TapVisor**, following the `<Feature>Visor` convention for a
generic capability (the capability is "reach another person's notch", not whose data is shown).

---

## 1. What the feature is

- Two SuperVisor users pair once. After that, each sees the other in the expanded sheet.
- Clicking a peer sends a **tap**; the peer's pill pulses in the brand gradient, in the sender's
  rhythm, and shows who it was. A tiny emoji palette sends an **emoji** instead; it rides the peek
  banner for a few seconds with the sender's name.
- Optionally, each peer sees the other's **presence** (at the Mac / away). Presence is a separate
  opt-in, since it leaks a schedule.
- Nothing is stored: a tap is "now". The server keeps at most a short redelivery queue for a peer
  who reconnects within minutes.

The five-second demo: a friend's emoji drops out of the notch while you are in a fullscreen app,
and one click on it sends a tap back.

## 2. What the codebase gives us today

Reading the sources, the relevant facts are:

- **There is no network stack in the app.** No `URLSession`, `Network.framework`, WebSocket,
  Keychain, or CloudKit use anywhere under `Sources/`. The only network traffic today is Sparkle's
  appcast check. The README's privacy posture leans on "local processing"; a networked module is a
  new category and has to be plainly opt-in and plainly scoped.
- **Signing and distribution constrain the Apple-native options.** The app is a Developer-ID-signed,
  non-sandboxed, hardened-runtime SwiftPM executable shipped via Sparkle, not the Mac App Store.
  `make-app.sh` embeds no provisioning profile, and debug builds fall back to ad-hoc signing.
  Restricted entitlements (iCloud/CloudKit, APNs, Sign in with Apple) need a provisioning profile
  embedded in the bundle, which the build does not do and which ad-hoc builds cannot satisfy at
  all. Any design that leans on those entitlements costs a build-pipeline change *and* makes the
  feature dead in every dev build. Sign in with Apple is not available to Developer ID apps even
  with a profile (see §3.1).
- **The surfaces an incoming signal needs already exist.** `peekBanner()` plus
  `requestPeek(seconds:)` presents a transient banner below the notch or inside the pill;
  `AttentionGlowCenter` is a one-shot glow cleared when the sheet opens; `SectionUrgencyCenter`
  floats a section when it matters; module `order` resolves banner collisions (SwarmVisor's 15
  beats FlowVisor's 100). A received emoji is exactly the SwarmVisor toast shape: banner + glow,
  retiring when seen.
- **The input-hardening conventions are set.** `FleetHookEvent.isValid` rejects oversize payloads
  rather than trimming; `AgentFleetCenter.displayMessage` collapses whitespace and strips control
  characters before text reaches a view; `AppLog` never records content. A peer's display name and
  emoji are the same class of input and get the same treatment.
- **The concurrency idiom for a background I/O worker is set.** `AgentEventSocket` confines socket
  state to a private serial queue in an `@unchecked Sendable` worker and hops to the main actor
  through `DispatchQueue.main.async { MainActor.assumeIsolated { … } }`. A WebSocket client can
  follow the same shape, or be an `actor` that posts to the module.
- **Lifecycle hooks exist.** `FlowTracker` already observes `NSWorkspace.willSleepNotification`,
  `didWakeNotification`, and screen lock/unlock. A connection should drop on sleep and reconnect on
  wake using the same notifications.
- **The idle-CPU rule applies.** Modules arm a single deadline rather than a periodic tick. A
  persistent socket has a floor cost (keepalive), so the client must hold a connection only while
  it would do something: identity exists, the module is enabled, and at least one peer is paired.
  Heartbeats should be server-driven and sparse (≥ 60 s), never a client-side poll.
- **Settings follow one pattern.** `SettingsStore` keys like `swarm.showMessages`; `SettingsView`
  renders a `Section` per module with its toggle and options. TapVisor's pairing UI, display name,
  presence toggle, and peer list live there.
- **CallSense is reusable.** `CallActivityMonitor` already knows when a call is in progress. The
  sheet floats above screen shares, so an incoming emoji during a call should degrade to a quiet
  badge instead of a banner, the same concern that keeps `swarm.showMessages` off by default.

## 3. Backend options

The workload is: tens to low thousands of long-lived connections, each sending a few hundred-byte
messages a day, needing sub-second delivery while both ends are online, and a small durable graph
of who is paired with whom. That shape rules some options in and out quickly.

### 3.1 Apple-native: CloudKit (+ push)

Zero servers and no account system, since the Apple ID is the identity.

- **No realtime channel.** CloudKit notifies through `CKSubscription` → APNs silent push, which is
  seconds of latency at best and throttled. A tap is a realtime gesture; a push-delivered one lands
  as a notification, not a touch.
- **Entitlements fight the build.** iCloud and APNs are restricted entitlements requiring an
  embedded provisioning profile. `make-app.sh` has none, ad-hoc dev builds can never carry one, and
  Developer ID + restricted entitlements has known signing pitfalls (Apple DTS on the managed
  Developer ID identity case: [forums thread 818501](https://developer.apple.com/forums/thread/818501),
  [thread 707244](https://developer.apple.com/forums/thread/707244)).
- **Sign in with Apple is out regardless.** Apple DTS states it is unsupported for Developer ID
  apps; the portal strips the entitlement from non-App-Store profiles
  ([forums thread 129263](https://developer.apple.com/forums/thread/129263)). A browser OAuth flow
  would work, but then CloudKit's "free identity" advantage is gone.
- **Friend discovery is gone.** `CKDiscoverUserIdentitiesOperation` is deprecated, so pairing would
  be by code anyway.

**Verdict: no.** It solves the easy half (storage) and not the hard half (realtime), while adding
the one dependency the build pipeline cannot absorb cheaply.

### 3.2 Managed realtime backend-as-a-service

- **Supabase** (Postgres + Realtime + Auth). The official Swift SDK supports macOS, and Realtime
  offers broadcast and presence channels, with private channels gated by row-level security
  policies on `realtime.messages`
  ([supabase-swift](https://swiftpackageregistry.com/supabase/supabase-swift),
  [Realtime guide](https://supabase.com/docs/guides/realtime/getting_started.md),
  [Swift subscribe reference](https://supabase.com/docs/reference/swift/v1/subscribe)). Fit is
  decent: the pairing graph is two Postgres tables, taps are broadcast on a per-user private
  channel, presence is built in. Costs: the SDK is a sizable new dependency in a package that has
  exactly one; Auth wants an email or OAuth identity (an anonymous-user mode exists); abuse controls
  are written as SQL policies plus edge functions; the free project pauses after inactivity.
- **Firebase** (RTDB/Firestore + Auth). Realtime works, but the Apple SDK is heavy (gRPC) and its
  macOS story is secondary; not worth the dependency weight for this payload.
- **Ably / Pusher / PubNub** (pure pub/sub). Excellent realtime and presence, but identity and the
  pairing graph are still ours to build, and per-message pricing is the wrong shape for a hobby
  scale that may grow.

**Verdict: Supabase is the credible BaaS choice** if the goal is to avoid writing any server. The
dependency weight and the SQL-policy abuse model are the trade.

### 3.3 Self-hosted small relay

One process: WebSocket endpoint, SQLite or Postgres, deployed on Fly.io / Railway / a VPS.

- **Swift on the server** (Hummingbird 2 or Vapor) lets a `SuperVisorWire` SPM package hold the
  `Codable` message types shared byte-for-byte with the client, matching the repo's Swift-only
  culture and `@testable` test style. Hummingbird is the lighter of the two.
- **Costs are operational**, not technical: TLS certificates, patching, uptime, backups, deploys,
  and a monthly bill (~$5). Auth, pairing, rate limiting, and the offline queue are all ours.

**Verdict: the best fit for full control**, and the right choice if Swift end-to-end matters more
than ops. Every protocol decision in §4 applies unchanged.

### 3.4 Serverless edge: Cloudflare Workers + Durable Objects

A Durable Object is a single-threaded, addressable object with its own storage and the ability to
hold WebSockets. **One Durable Object per user identity** is exactly the shape of this problem:
the object is that user's mailbox, holds their live connection(s), stores their peer edges, and
forwards a tap to the recipient's object by id.

- **Idle is nearly free.** With the WebSocket Hibernation API, an object holding idle sockets is
  not billed for duration; incoming messages are metered at a 20:1 ratio against requests and
  outgoing messages and protocol pings are free
  ([Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing)).
  The Workers free plan's 100,000 requests/day covers hundreds of users of a tap feature; the paid
  plan is $5/month with 1M requests included.
- **Server-side auto-responses** (`setWebSocketAutoResponse`) answer a client ping without waking
  the object, so the client's sparse keepalive costs nothing.
- **No server to run**, global edge, built-in SQLite storage per object, TLS handled.
- **Costs:** TypeScript rather than Swift; vendor-specific primitives; per-object single-threading
  means a fan-out to many peers is many object calls (fine at "a handful of friends").

**Verdict: recommended for v1.** Lowest ops, lowest cost, and the data model maps one-to-one onto
the platform's primitive.

### 3.5 No backend at all (LAN)

Bonjour / `MultipeerConnectivity` / `Network.framework` peer discovery works only on one network.
It is a legitimate "office mode" later, not an answer to "cloud".

### Summary

| Option | Realtime | Ops | Identity | Fits Developer ID + ad-hoc dev builds | Verdict |
| --- | --- | --- | --- | --- | --- |
| CloudKit + push | No (push latency) | None | Apple ID | No (profiles, entitlements) | Reject |
| Supabase | Yes | Low | Supabase Auth / anon | Yes | Viable fallback |
| Swift relay (Hummingbird) on Fly.io | Yes | Medium | Ours | Yes | Viable, Swift end-to-end |
| Cloudflare Workers + Durable Objects | Yes | Very low | Ours | Yes | **Recommended** |
| LAN peer-to-peer | Yes, LAN only | None | Ours | Yes | Later, office mode |

## 4. Recommended architecture

### 4.1 Identity: a device keypair, no accounts

Each install generates an Ed25519 keypair on first use (CryptoKit `Curve25519.Signing`), stores the
private key in the login Keychain, and uses the public key as its identity. Authentication is
challenge-response: the server sends a nonce on connect, the client returns it signed, the server
issues a session token for the socket's life.

Why not an account: Sign in with Apple is unavailable to Developer ID apps (§3.1), email sign-up
is friction and a database of emails to protect, and the feature does not need recovery. A
keypair works identically in ad-hoc dev builds and the shipped app, needs no entitlement, and
leaks nothing. Its weakness is that identity is per-Mac; a second Mac is a second identity until
a later "link my other device" step signs one key with another.

### 4.2 Pairing: short-lived codes

- `pair.create` returns an 8-character code (≈ 1e12 space) valid 10 minutes, single use.
- The other person enters it (or opens a `supervisor://pair/<code>` link). `pair.redeem` creates a
  symmetric edge between the two identities and both sides learn the other's display name.
- Codes are rate-limited per identity and per IP; a wrong guess burns attempts, so the space is
  never searchable inside the TTL.
- Either side can **remove** a peer, which deletes the edge; **block** additionally records a
  denylist entry so the blocked identity cannot re-pair without the blocker's own code.

### 4.3 Wire protocol: JSON lines over WSS

One JSON object per frame, mirroring the JSON-per-line idiom the app already uses for the
now-playing stream and the hook socket. Every frame is capped at 1 KiB and rejected above it.

```
→ hello        { "v": 1, "key": "<base64 pubkey>", "name": "Shawn" }
← challenge    { "nonce": "<base64>" }
→ auth         { "sig": "<base64 ed25519(nonce)>" }
← ready        { "peers": [ { "id": "<pubkey>", "name": "…", "presence": "online"|"away"|null } ] }

→ ping         { "to": "<pubkey>", "kind": "tap", "pattern": [0, 180, 160] }
→ ping         { "to": "<pubkey>", "kind": "emoji", "emoji": "👋" }
← ping         { "from": "<pubkey>", "kind": "tap", "pattern": [0, 180, 160], "ts": 1760000000 }
← delivered    { "id": "…" }

→ presence     { "state": "online"|"away" }          (only when the user opted in)
← presence     { "peer": "<pubkey>", "state": "online"|"away"|null }

→ pair.create  {}            ← pair.code   { "code": "K7Q2-M9XD", "expires": 1760000600 }
→ pair.redeem  { "code": "…" } ← peer.added { "id": "…", "name": "…" }
→ peer.remove  { "id": "…" } / peer.block { "id": "…" }
```

- `pattern` is a short array of millisecond offsets (≤ 8 entries, each ≤ 2 000 ms), so a double
  tap arrives as a double tap. The client coalesces clicks within a 2-second window into one
  `ping` to keep the rate limit meaningful.
- `emoji` must be exactly one extended grapheme cluster whose scalars are emoji; anything else is
  rejected server-side and again client-side.
- The server enforces: sender and recipient are paired; ≤ 20 pings per sender per recipient per
  minute; undelivered pings are queued for the recipient for 10 minutes, then dropped (a tap from
  an hour ago is noise, not a message).
- The server stores: public keys, display names (≤ 32 characters), edges, denylist entries, and the
  transient queue. No history, no content in logs.

### 4.4 Server (Durable Objects sketch)

- A Worker handles `wss://…/v1/connect`, parses `hello`, and forwards the socket to the Durable
  Object named by the public key (`idFromName(pubkey)`), which performs the challenge, holds the
  hibernatable socket, and owns that user's SQLite tables (`peers`, `blocked`, `queue`).
- Sending a tap is the sender's object calling the recipient's object (RPC) with the validated
  frame; the recipient's object fans out to its live sockets or appends to `queue`.
- Pairing codes live in a single `PairingCodes` object (or KV with TTL) keyed by code.
- Presence is the recipient object's view of "does this peer's object have a live socket", pushed
  on connect/disconnect only to peers who opted in.
- `setWebSocketAutoResponse` answers the client's keepalive without waking the object.

The same design in Hummingbird on Fly.io is one process with an in-memory `[pubkey: [socket]]`
map and SQLite behind it; the protocol does not change.

### 4.5 Client module: `Modules/Tap/` ("TapVisor")

- **`TapModule`** — `NotchModule, ObservableObject`, `order` 20 (a friend's touch outranks a break
  nudge; a blocked agent still wins). Compact: nothing at rest, like SwarmVisor. On a received
  ping: `requestPeek(3)` with a `peekBanner()` showing the sender and emoji, plus
  `AttentionGlowCenter.raise()`; a tap additionally animates the surface in the received pattern
  (a brand-gradient ring pulsing per offset, reusing `SwarmPulseRing`'s idiom and honoring Reduce
  Motion). Expanded: peer rows (name, optional presence dot, last-received emoji), click = tap,
  hover reveals a 6–8 emoji palette; a "Pair…" row for code create/enter; a muted-peer marker.
- **`Services/Peers/PeerIdentity`** — Keychain-backed keypair.
- **`Services/Peers/PeerLinkClient`** — the WebSocket client (`URLSessionWebSocketTask` inside an
  `actor`), connect/auth/reconnect with jittered backoff, sparse keepalive, disconnect on
  `willSleep`/screen lock and reconnect on wake. It connects only while the module is enabled, an
  identity exists, and ≥ 1 peer is paired.
- **`Services/Peers/PeerStore`** — paired peers cached locally (JSON under Application Support via
  `AppManagedFileStorage`) so the roster renders offline.
- **`PeerFrame` validation** — a `Decodable` with an `isValid` in the `FleetHookEvent` style:
  name ≤ 32 chars after control-character stripping, emoji is one emoji grapheme, pattern bounded,
  unknown `kind` ignored, frame ≤ 1 KiB.
- **Settings** (`tap.*`): module toggle (default on but inert until paired, so connecting is the
  explicit opt-in); display name; "Share whether I'm at my Mac" (default **off**); "Quiet during
  calls" (default on, via `CallActivityMonitor`: badge instead of banner); pairing code UI; peer
  list with Mute / Remove / Block.

### 4.6 Privacy and abuse, stated plainly

- Only paired peers can reach you; pairing is mutual and revocable; blocking sticks.
- Presence is off unless turned on, and it is "online/away" only, never what you are doing.
  FlowVisor's idle signal is **not** reused for presence; "away" is derived only from sleep/lock.
- The server sees public keys, chosen names, and edges. It never sees calendar, media, files, or
  agent data; the module shares no state with other modules, per the module contract.
- Incoming text and emoji are validated before they reach a view, never logged, and shown only
  for a few seconds. During a call they do not appear at all.

## 5. Risks and open questions

- **Cost of a persistent connection.** Even a hibernated WebSocket keeps a TCP connection and a
  rare keepalive alive on the Mac side. Holding it only while a peer exists bounds that, but it is
  the first always-on network activity in the app and should be visible in Settings ("Connected
  as …").
- **Identity recovery.** Losing the Keychain item loses the identity and every pairing. Acceptable
  for taps; document it, and add device linking before anything that would hurt to lose.
- **Server trust.** The relay sees who taps whom and when. End-to-end encrypting the payload is
  cheap with the keys already in hand (X25519 agreement from the same Curve25519 material), and
  would make the server a pure router. Worth doing in v1 if emoji ever grow into short text; not
  needed while payloads are a tap pattern.
- **Spam through pairing.** A code shared publicly lets strangers pair with you until it expires.
  Codes are single use, so the exposure is one stranger per code, and Block ends it.
- **Who hosts the relay.** A hosted relay makes SuperVisor depend on a service the user does not
  control. Shipping the Worker as open source in the repo, with the endpoint a Settings field
  (default to the official one), keeps self-hosting possible.
- **Does this belong in the notch?** The product checklist in `PRODUCT_IDEAS.md` asks why the
  notch rather than a popover. Here the answer is the surface itself: a tap is a physical gesture
  and the notch is the one piece of UI that can pulse like hardware. If the feature drifts toward
  chat, it has left the notch's remit.

## 6. Suggested path

1. **Protocol and server (1–2 days).** Write the frame types and validators as a `SuperVisorWire`
   package with tests, then the Durable Objects worker with a local `wrangler dev` loop. Validate
   two `websocat` clients can pair and tap.
2. **Client services (2–3 days).** `PeerIdentity`, `PeerLinkClient`, `PeerStore`, with unit tests
   for frame validation, reconnect backoff, and the connect-only-when-useful rule.
3. **Module and UI (2–3 days).** `TapModule`, banner, pulse, roster, Settings section. Verify on
   both notched and flat geometry, and the call-quiet path.
4. **Hardening.** Rate limits, block list, keepalive tuning, Reduce Motion, a "Connected as" line.
5. **Later.** Device linking, end-to-end payload encryption, LAN office mode, a global hotkey to
   tap the most recent peer.

If the team would rather stay in Swift end-to-end, swap step 1 for Hummingbird on Fly.io; nothing
after it changes.
