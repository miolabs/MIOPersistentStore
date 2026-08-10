# Live change notifications + persistent cache for MIOPersistentStore

Status: DESIGN / options evaluation — 2026-08-08

## 1. Problem

MIOPersistentStore gives us full control over how and when an app talks to the
remote DB, but we lost two things a local Core Data store gives for free:

1. **Live updates.** If another session changes a row this session has already
   fetched, nothing happens here until the user re-fetches. We want the Core
   Data model: *fetched results controllers stay live and get change
   notifications; plain one-shot fetches do not.*
2. **Cold-start cache.** Every run starts empty; nothing fetched in the last
   run survives to the next.

Both features need the same foundation — a per-row version + a monotonic
change cursor — so they are designed together, and the work is necessarily
**split across server and app**, not confined to one framework.

## 2. What already exists (ground truth, audited 2026-08-08)

### Server side

- **Every save already writes the notification content.**
  `entity_core_save_changelog` (DualLinkServerKit `EntityCore/BlockMerge.swift:77`)
  writes one `Changelog` row per changed object: `entityType`, `entityID`,
  `action` (INSERT/UPDATE/DELETE), `delta` (jsonb of changed attrs only),
  `appID`/`updatedByAppID`, shared per-transaction `syncID`.
- **A total order already exists.** `DLChangelogSerializer` (port 8105) drains
  `Changelog` and writes `ChangelogCommitted` rows with autoincrement
  `syncIndex` plus pre-aggregated `entities[]` and `appIDs[]` — a ready-made
  routing header per commit.
- **A delta-pull endpoint already exists.** `DLSyncPullServer`
  `GET /pull/schema/:scheme/sync-id/:sync_id` with the canonical filter
  (`changelog_query_from_sync_id`): `syncID > cursor`,
  `updatedByAppID != myAppID` (no echo), place-vs-device entity scoping via
  `DBSyncType()`, `syncByAppID` null-or-mine. Client cursor lives in
  `DLAppContext+ServerSync.swift` (`dldb_last_sync_id` in UserDefaults).
- **MIOServerKit just grew WebSocket support** (NIO/`WebSocketEndpoint`,
  `ConnectedWebSocketCatalog`, `sendMessageToAll`) — brand new, **zero
  consumers**, so we can shape it freely. Gaps: no auth at upgrade, no
  per-client addressing (broadcast only), binary frames unimplemented,
  catalog is per-process.
- **Fetch is stateless** — `DLEntityServer` records nothing about what a
  session fetched. There is no server-side subscription registry today.
- **Not usable as-is:** MIONotificationServer (dead UIKit WS client),
  DLNotificationServer (naive Kitura broadcast relay, no auth/rooms),
  DLSyncServer APNs (commented out, hardcoded creds), Postgres LISTEN/NOTIFY
  (MIODBPostgreSQL has no `PQnotifies`/async plumbing at all).

### Client side (Swift)

- **MIOPersistentStore node cache is version-gated.** `nodesByCacheKey`
  keyed by `(entityName, UUID)`, refcounted via didRegister/didUnregister,
  ingest discards rows whose `version <= node.version` (`MPSParser.swift:37`),
  and `version == 0` means "fault — refetch on next access".
- **Batch refetch primitive exists:** `fetchObjects(identifiers:[UUID],
  entityName:context:)` builds an `identifier IN %@` fetch.
- **Delta-fetch slot pre-wired but inert:** `NSFetchRequest.version` →
  `MPSFetchRequest.version`, never read by anyone.
- **The context side is the real gap.** MIOCoreData has only
  Will/DidSave notifications. No `ObjectsDidChange`, no refreshed-objects key,
  no `mergeChanges(fromContextDidSave:)`, `refresh(_:mergeChanges:)` posts
  nothing, and `FetchedResultsController` is a 36-line empty stub.
- **The TypeScript twin already solved this exact shape.** MIOJSLibs:
  `MWSPersistentStore.ts` ingests → `context.refreshObject(obj, true)` →
  `MIOManagedObjectContextObjectsDidChange` (with `MIORefreshedObjectsKey`) →
  `MIOFetchedResultsController` (348 lines: sections, Insert/Delete/Update/Move,
  predicate re-evaluation). This is the porting blueprint.
- Server-side deletes are currently **unhandled** on ingest (commented-out
  block in `MPSParser.swift:51-54`).
- No disk cache anywhere in the Swift stack (`NSSQLiteStore`/`NSBinaryStore`
  in MIOCoreData are empty shells).

## 3. Options — change notification transport

### Option A — polling only (enhanced pull)

Client polls the sync cursor every N seconds while subscribed FRCs exist.

- Server work: ~none (DLSyncPullServer filter exists).
- Pros: simplest, stateless, no new server, survives replicas trivially.
- Cons: latency = poll interval; wasted requests; battery/network cost;
  every idle client hammers the DB.
- Verdict: **fine as the phase-1 fallback path and the catch-up mechanism,
  wrong as the end state.**

### Option B — WebSocket "wake-up ping" + existing pull  ⭐ recommended

Server pushes only a tiny routing message per commit:
`{schema, syncIndex, entities[], appIDs[]}` (exactly the `ChangelogCommitted`
row). Client intersects `entities[]` with its subscribed entity set, ignores
its own `appID`, and if relevant pulls deltas `> cursor` through the
existing pull filter, then applies them.

- Pros: near-real-time; payload is a cursor, not data — no new delta format
  to invent, no ordering/loss protocol (a dropped ping is healed by the next
  ping or a reconnect catch-up pull, because the cursor is monotonic);
  reuses the pull predicate verbatim so notify and pull can never disagree;
  push channel carries no sensitive row data.
- Cons: needs the WS layer hardened (auth at upgrade, addressing) and a
  fan-out home (see §5).
- Verdict: **best fit. Push says "something you care about changed after
  cursor X"; pull remains the single source of truth for what changed.**

### Option C — full delta push over WebSocket

Server pushes the actual changed values to each subscribed session.

- Pros: one round trip.
- Cons: duplicates the pull filter logic in a second code path; requires
  per-connection ordering, ack/replay on reconnect, and server knowledge of
  each session's cursor; larger frames; binary WS send is unimplemented.
- Verdict: **rejected for v1.** Can be layered later as an optimization by
  inlining the delta into the ping for small commits — the client treats it
  as a prefetch hint, cursor semantics unchanged.

### Option D — Postgres LISTEN/NOTIFY as the trigger

- MIODBPostgreSQL is strictly synchronous libpq; no `PQconsumeInput`
  plumbing, pool built around checkout/checkin.
- The serializer already observes every commit anyway — it is our NOTIFY.
- Verdict: **rejected.** Solves a problem we don't have, at the cost of new
  driver plumbing.

### Option E — APNs / platform push

- Verdict: **out of scope for live UI** (latency, throttling, dead hardcoded
  code). Possible later complement for waking backgrounded apps so their
  cache catches up before foregrounding.

## 4. Options — subscription granularity ("only the entities we fetched")

1. **Whole schema, client filters.** Server pushes every commit ping to every
   session of the schema. Simplest; fine for v1 since pings are ~100 bytes.
2. **Entity-type set per session.** ⭐ FRC registration tells the store which
   entity names are live; the store sends `subscribe {entities:[...]}` over
   the socket; server intersects with `ChangelogCommitted.entities[]` before
   pushing. Cheap on both sides (set intersection on a pre-aggregated
   column), cuts most irrelevant wake-ups (e.g. ticket spam while looking at
   products).
3. **Per-object ID registry on the server.** True "only fetched rows" —
   requires stateful fetch, per-session ID sets server-side, and constant
   registration traffic. **Rejected**: the client already knows its fetched
   IDs (`nodesByCacheKey`) and its FRC predicates, so object-level and
   predicate-level filtering belongs client-side where it is free.

Recommended: **2 server-side + client-side ID/predicate filtering** as the
baseline, upgraded with §4.1 predicate pushdown. This also matches the
product requirement directly: only FRCs create subscriptions; a standard
one-shot fetch registers nothing and stays static, exactly like Core Data.

### 4.1 Thin server-side filter layer (predicate pushdown)

Between "entity-type set" (2) and "per-object registry" (3, rejected) there
is a middle tier worth building: the session registers **(entity, filter
predicate)** — typically the FRC's predicate, or a coarser superset of it —
and the server evaluates changes against it before pushing. The server never
tracks which objects a session holds; it holds only a handful of compiled
filters per session. Entity-type pings without a predicate would otherwise
wake every app on every change of a hot entity (tickets…), burning network
and battery for changes the app provably doesn't care about.

**The contract that keeps it thin and safe: server filtering is best-effort
— it may OVER-deliver, it must never UNDER-deliver.** The client re-checks
everything against its own FRC predicate anyway (it must, for section/sort
placement), so a false positive costs one wasted pull; a false negative
would mean stale UI. Every rule below is conservative, and "can't decide"
always resolves to *push*.

**Session/filter state (the "thin" part):**
- `subscribe {subscriptionID, entity, predicate?}` /
  `unsubscribe {subscriptionID}` over the socket; state dies with the
  connection (reconnect re-subscribes — the client owns the truth, so a
  notify-server restart loses nothing but a re-subscribe round trip).
- Predicate wire format: the **same serialized predicate the fetch endpoint
  already accepts** — the server already parses it; no new language.
- Compiled once at subscribe time into `(entity, attrs(P), evaluator over
  a values dictionary)`. Per-session memory: a few dozen bytes per
  subscription, zero growth with data size or objects held.
- **Dedupe by filter hash**: N devices of the same venue watching "today's
  tickets for place X" evaluate as *one* filter mapped to N sessions.
  Evaluation cost per commit is O(distinct filters on the touched entities),
  not O(sessions).

**Pushdown split (client side):** the FRC predicate is decomposed like a
query planner — conjuncts the server evaluator supports (attribute
comparisons, ==/!=/IN/</>, AND/OR) are sent up; unsupported residue
(relationship key-paths, functions) stays client-side and the server filter
is just the supported superset. Worst case the residue is everything and the
subscription degrades to the plain entity-type tier — never wrong, just less
selective.

**Decision table** — for a change `(entity, id, action, delta)` against
subscription `(E, P, attrs(P))`, where the notify layer is given the
**full new-row values** for changed rows (see below):

| Action | Rule |
|---|---|
| INSERT | push iff `P(newRow)` (delta ≈ full row on insert anyway) |
| DELETE | always push `(entity, id)` — no values exist to filter on; client drops it in O(1) via `nodesByCacheKey` if it doesn't hold the object |
| UPDATE, `P(newRow)` = true | push (it's in the set now) |
| UPDATE, `P(newRow)` = false, `attrs(P) ∩ attrs(delta) = ∅` | **suppress** — membership can't have changed and it doesn't match now, so it didn't match before either |
| UPDATE, `P(newRow)` = false, `attrs(P) ∩ attrs(delta) ≠ ∅` | push — the object may have just *left* the result set and the FRC must remove its row |
| P unevaluable / evaluator error | push |

The one thing this table needs beyond the changelog row is `newRow`: the
`delta` jsonb alone can't answer "does it match now" when P references
unchanged attributes. So the emitter enriches the notify payload with
current row values — **one `SELECT ... WHERE identifier IN (...)` per
entity per commit group**, done once where the emit happens (serializer or
notify server), and only when predicate subscriptions exist for that
entity. Bounded, batched, and skipped entirely for entity-only subscribers.

**Budgets, because groups can be huge** (cf. the 173k-row changelog group):
above a row budget per commit group, skip per-row evaluation and fall back
to the entity-tier ping ("something in `entities[]` changed after cursor
X") for all matching subscribers. Over-delivery again — never a miss.

**Explicitly out of scope for this layer** (they'd make it non-thin):
per-object interest sets, per-session cursors/ack state, relationship
traversal in server predicates, and evaluating against *old* row values
(the delta-attrs intersection rule covers membership-exit without them).

## 5. Where the socket lives (multi-replica problem)

`ConnectedWebSocketCatalog` is per-process; entity servers run replicated.

- **(a) Dedicated notify server** ⭐ — new small `DLNotifyServer` (MIOServerKit
  NIO + WS). Apps connect there (one socket per app session).
  `DLChangelogSerializer` POSTs each `ChangelogCommitted` summary to it
  server-to-server (same pattern OneServer uses for `/coordination/relaunch`).
  One socket-holding process per cluster; entity servers stay stateless.
  If it ever needs replicas, add the DLPaymentProxy-style split later.
- (b) Sockets on DLEntityServer + sticky routing — couples connection state
  to a replicated, restart-happy server; rejected.
- (c) OneServer distributed actors — membership is server processes, not app
  sessions; putting iOS/web clients in a cluster is a non-starter. Reuse the
  *pattern* (presence registry + push callback), not the component.

Emit point: **in `DLChangelogSerializer.awake_handler`, right after the
`ChangelogCommitted` insert commits** — it is the total order (`syncIndex`)
the pull endpoint paginates by, and the row already carries the routing
header. Emitting earlier (inside `commit_json_to_db`) would notify before
serialization, letting a client pull a cursor that isn't committed yet.
Latency cost vs. the serializer's poll cadence is acceptable; if not, wake
the serializer via HTTP from `commit_json_to_db` (cheap) rather than moving
the emit.

## 6. Client-side architecture (needed under every option)

### 6.0 Hard constraint: two Core Data runtimes, one store

`MIOCoreData` is a shim: with `APPLE_CORE_DATA` it `@_exported import
CoreData` (Apple's framework — **all iOS/macOS apps run this way**),
otherwise `CoreDataSwift` (the reimplementation — Linux servers, wasm).
MIOPersistentStore compiles against both. Therefore:

- **The store may only talk to the context layer through API Apple already
  defines.** On Apple, `ObjectsDidChange`, `refresh(_:mergeChanges:)`, the
  full native `NSFetchedResultsController`, and
  `NSManagedObjectContext.mergeChanges(fromRemoteContextSave:into:)`
  (objectID-based, built precisely for "the store changed underneath you",
  drives FRCs natively) all exist today — nothing to build there.
- **CoreDataSwift must grow the *same* API surface, same names/signatures**,
  so the ingest and app code is written once and compiles under both flags.
  The TS twin (MIOJSLibs `MIOFetchedResultsController.ts`, ingest →
  `refreshObject` → `ObjectsDidChange`) is the porting blueprint for the
  CoreDataSwift implementations — Apple's behavior is the reference spec.

Propagation pattern (mirrors Apple's `NSPersistentStoreRemoteChange` /
persistent-history flow): the store does **not** reach into contexts
(NSIncrementalStore has no context list on Apple). It applies changes to its
node cache, then posts a store-level notification carrying changed
`NSManagedObjectID`s (inserted/updated/deleted); the app layer
(DLAppContext), which owns the contexts, calls
`mergeChanges(fromRemoteContextSave:into:)` — native FRCs update from there.

```
WS ping ─▶ MPSSyncClient (new)         cursor mgmt, subscribe msgs, reconnect
              │ pull deltas > cursor (existing pull endpoint, existing filter)
              ▼
        MIOPersistentStore ingest      apply to node cache (version gate)
              │ version==0 + batch refetch for anything not resolvable locally
              ▼
        post .MPSStoreRemoteChange {inserted/updated/deleted objectIDs}
              ▼
        DLAppContext: mergeChanges(fromRemoteContextSave:into: contexts)
              ▼
        NSFetchedResultsController     Apple-native on iOS/macOS;
                                       CoreDataSwift port elsewhere
```

### 6.1 Work items

1. **CoreDataSwift parity** (no server dependency; iOS unaffected — Apple
   already has all of this):
   - `NSManagedObjectContextObjectsDidChange` + refreshed/inserted/deleted
     userInfo keys; make `refresh(_:mergeChanges:)` post it.
   - `mergeChanges(fromContextDidSave:)` and objectID-based
     `mergeChanges(fromRemoteContextSave:into:)`.
   - Real `NSFetchedResultsController`: port `MIOFetchedResultsController.ts`
     (sections, change types, delegate protocol, predicate re-evaluation),
     matching Apple's API.
2. **MIOPersistentStore** (shared, compiles under both flags):
   - Remote-change ingest entry point: given `(entityType, entityID, action,
     delta?, version)` — INSERT/UPDATE: apply delta if the node exists and
     version is newer, else mark `version = 0` and batch-refetch via the
     existing `fetchObjects(identifiers:)`; DELETE: evict node. Then post
     `.MPSStoreRemoteChange` with the affected objectIDs (fixes the
     currently-unhandled server-delete case too).
   - Fix `MPSCacheNode.invalidate()` to also drop `_node`/`_attributeValues`
     (today an invalidated node still serves the stale
     `NSIncrementalStoreNode`).
   - Interest registry: refcounted set of live entity names; drives
     subscribe/unsubscribe messages and socket lifecycle (connect on first
     subscriber, disconnect on last).
3. **FRC-only subscription seam.** On Apple we cannot hook native
   `NSFetchedResultsController` creation, so interest is declared via an
   `MPSFetchedResultsController` subclass (NSFetchedResultsController is
   subclassable): `performFetch()` registers its entity with the store's
   interest registry, deinit/`invalidate()` unregisters. CoreDataSwift ships
   the same subclass name over its own FRC. Apps opt in by using it (or the
   explicit `store.beginLiveUpdates(entities:)` API underneath it); plain
   fetches and plain FRCs stay static — exactly the Core Data-like contract
   we want. (Auto-deriving interest from `managedObjectContextDidRegister
   Objects` refcounts was rejected: it covers *every* fetched object, not
   just FRC-held ones.)
4. **DualLinkAppKit** (`DLAppContext`): owns the socket client, auth
   (DL-APP-ID / place headers at upgrade), maps pings to store ingest,
   applies `mergeChanges(fromRemoteContextSave:into:)` to its contexts, owns
   the cursor (shared with the existing `dldb_last_sync_id` mechanism).
5. **Wire contract** in a small shared kit (DLOneKit pattern — e.g.
   `DLSyncKit`): message types `hello/subscribe/ping{schema, syncIndex,
   entities[], appIDs[]}`, versioned. JSON text frames — consumable
   identically by iOS (URLSessionWebSocketTask), CoreDataSwift clients, and
   the TS web manager.
6. **MIOServerKit WS hardening** (server lib, benefits everything):
   auth hook in `shouldUpgrade` (headers are already in scope), per-client
   send + subscription index in `ConnectedWebSocketCatalog`.

Delta application: **start with "invalidate + refetch by IDs"** (small,
correct, reuses the fetch path incl. relationships), then optimize to
applying the changelog `delta` jsonb directly for attribute-only updates.

## 7. Later step — persistent cache (P4)

The cache is only safe because of the same two primitives: per-row `version`
(= changelog syncID at write time) and the monotonic `syncIndex` cursor.

- **Model: persist the node cache, not a mirror DB.** Store
  `(entityName, id, version, rawValues)` rows + one `(schema, lastSyncIndex)`
  cursor. `MPSCacheNode` already keeps `_rawValues` exactly as received and
  converts lazily, so serialization is trivial. Backend: SQLite
  (MIODBSQLite once ready; SQLite.swift as the stopgap) or a single
  journaled file for small datasets — decide by dataset size, API identical.
- **Cold start:** load nodes → serve fetches from cache immediately (nodes
  enter at their persisted version, the existing version gate makes later
  server rows win) → catch up by pulling changelog `> lastSyncIndex` → FRCs
  update through the same ingest path as live pings. **The cache warm-up is
  literally the notification path replayed** — no second code path.
  If the cursor is too old to replay (changelog pruned / huge backlog — cf.
  the 173k-row monster group), drop the cache and full-refetch.
- Rejected alternatives: full local mirror with local query execution
  (offline mode — a much bigger product decision; revisit separately) and
  HTTP-level response caching/ETags (can't answer "what changed", only
  "did this exact request change").
- Note: fetch execution still hits the server in this phase; the cache
  removes the cold-start blank screen and makes faults resolvable offline,
  it does not make queries local.

## 8. Phasing

- **P1a — store ingest path** (shared, both runtimes): remote-change ingest
  + delete handling + invalidate fix + `.MPSStoreRemoteChange` posting +
  interest registry + `MPSFetchedResultsController` seam. **On iOS this is
  already end-to-end** (Apple provides the whole context/FRC side) — demo it
  first on an iOS app with **polling** (Option A) through the existing pull
  endpoint. Full feature works here, just with poll latency.
- **P1b — CoreDataSwift parity** (no server work, parallelizable with P1a):
  ObjectsDidChange, refresh-posts, both mergeChanges variants,
  NSFetchedResultsController port matching Apple's API + tests against the
  in-memory store, cross-checked against Apple behavior via the existing
  AppleCoreDataTests target.
- **P2 — push transport**: MIOServerKit WS hardening; `DLSyncKit` contract;
  `DLNotifyServer`; serializer emit hook; DLAppContext socket client with
  reconnect + catch-up pull. Polling remains the degraded/fallback mode.
- **P3 — filtering + polish**: entity-set subscribe server-side, then the
  §4.1 predicate-pushdown layer (compiled filters, hash dedupe, row-values
  enrichment, budget fallback); optional delta-apply optimization; optional
  inline-delta-in-ping.
- **P4 — persistent cache**: node persistence + cursor + cold-start replay;
  staleness cutoff policy.

Each phase ships independently; P1a/P1b are pure client and unblock the
rest, and P1a alone delivers the feature to iOS apps.

## 9. Open decisions / risks

- **Serializer dependency**: push ordering relies on `ChangelogCommitted`
  (`dbOptionSerializerStatus == .ready`). Schemas without the serializer
  active would fall back to raw `syncID` — decide whether to require the
  serializer for live sync (recommended) or support both cursors.
- **Echo suppression** is by `appID` (`updatedByAppID != mine`) — same-user
  multi-device works, but two windows of the *same* app instance share fate.
  Matches current pull semantics; confirm acceptable.
- **Local save doesn't bump node version** (merge keeps old version until
  next fetch) — with delta-apply (P4) an incoming row equal to the stale
  version would be wrongly discarded; the refetch-based P1a/P2 path is
  immune. Revisit
  when doing delta-apply.
- **Web client** (DLWebManager / MIOJSLibs) has the FRC chain already; it
  needs only the socket client + ingest mapping to join the same
  `DLNotifyServer`. Keep the wire contract JSON/text-frame for this reason
  (binary WS is unimplemented in MIOServerKit anyway).
- **WASI**: MIOCoreData notifications are `#if !os(WASI)`-gated; the
  SwiftWasm data-layer plan will need those TODOs resolved for parity.
- **Security**: WS upgrade must validate the same auth as the pull endpoint;
  pings leak only entity names + syncIndex by design.
