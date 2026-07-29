# Apple NSIncrementalStore contract (observed)

Reference for how real Apple Core Data drives an `NSIncrementalStore`,
observed with a logging store subclass on macOS (2026-07, macOS 26.5 SDK).
MIOCoreData's context/store and MIOPersistentStore's node cache follow this
contract. It exists because we got it wrong twice in a row:

- Placeholder cache nodes were created on `didRegisterObjects` for
  **temporary** IDs. Apple never notifies the store about temporary objects
  at all, and the temporary key mutates at save, so those nodes leaked.
- Removing that placeholder creation without populating the cache during the
  save request left `insert → save → update → save` with no node to update:
  a force unwrap trapped with Signal 4 and took the whole server down
  (DLPaymentServer, `createOnlineOrderTransaction`, 2026-07-29).

## Observed sequence

```
insert                 -> (no store callback of any kind)
save #1 (insert)       -> obtainPermanentIDs(count=1)
                       -> execute(SAVE inserted=1)        <- populate row cache HERE
                       -> didRegisterObjects [permanent]  <- after the save, IDs only
mutate + save #2       -> newValuesForObject(permanent)   <- store must serve the row
                       -> execute(SAVE updated=1)
context reset/dealloc  -> didUnregisterObjects [permanent]
fetch (fresh context)  -> execute(FETCH)
                       -> newValuesForObject(permanent)   <- on fault
                       -> didRegisterObjects [permanent]
```

## Rules that follow

1. **Temporary IDs never reach the store.** No registration, no
   `newValuesForObject`, no cache entries keyed by temporary references.
   Unsaved objects live in the context, period.
2. **The save request populates the row cache.** `execute(SAVE)` is the only
   moment the store sees an inserted object's values; by then the object
   already carries its permanent ID (`obtainPermanentIDs` runs first).
   `didRegister` cannot do this job — it carries no values.
3. **`didRegister`/`didUnregister` are a reference count** on the row cache:
   "these IDs are (no longer) in use by a context". Evict a cached row only
   when its last registration goes away — the cache is shared by every
   context on the store, and an unconditional delete pulls rows out from
   under contexts that still hold the object.
4. **After an insert-save, the store must be able to serve the row** — Apple
   calls `newValuesForObject` on the next update-save of that object.

## Reproducing the observation

The probe is a ~150-line SPM executable: a `ProbeStore : NSIncrementalStore`
whose every override logs its inputs (and whether IDs are temporary), an
in-code model with one entity, and a script that runs
insert → save → mutate → save → reset → refetch. Rebuild it against a new SDK
if Apple's behavior is ever in question again.

Covered by tests:

- `MIOCoreData/Tests/MIOCoreDataTests/StoreRegistrationNotificationTests.swift`
  (notification timing and ID kinds)
- `Tests/MIOPersistentStoreTests/MPSSaveLifecycleTests.swift`
  (cache population per save request, ref-counted eviction, the
  insert→save→update→save regression)
