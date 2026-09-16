# miumiu conventions

Luau library, wally package (shared realm), consumed from both Luau and roblox-ts.
Layout and style follow WCS (`../WCS`, branch `luau-rewrite`) and `../cake`; read
`DESIGN.md` before touching behaviour. dataforge (`PepeElToro41/dataforge`) is the
design base for the storage layer, never a dependency.

## Layout

```
src/init.luau         the public table; re-exports types
src/types.luau        every type the library owns, internal ones included
src/ids.luau          every preregistered component/tag the library exposes
src/messages.luau     every user-facing string (errors, warnings, closures, reasons)
src/logging.luau      warn sink (`miumiu.set_warn`), warn_once over a per-world `warned` table
src/symbol.luau       opaque symbols; hooks.luau holds the hook symbols (pulled, closed, writing, landed, refused)
src/callbacks.luau    connect/invoke/fire/is_connected registry behind Session:hook and Batch:hook
src/mutex.luau        per-session lock (cake-style class)
src/util.luau         describe, targets_of, sync (no-yield runner), own (copy-on-write), run_all, join_all, create_guard, cached, create_guid
src/state.luau        per-world state: applying marks, entity shadows and removal bookkeeping (forget_removing / mark_removing_field / removing_targets), linked_key, link_states_of, open_session, read_values
src/contexts.luau     create_context = world + world_state + schema (builds and freezes the schema)
src/schema.luau       saveable discovery, field_of scopes (roots per collection, kinds), freeze
src/collection.luau   collection config resolution and validation, store handle
src/codec.luau        stored_form / runtime_form (serdes), check_guard and op_for
src/ops.luau          op replay (pure), deep_equal/deep_copy, path stamps
src/delta.luau        diff of two values into delta ops
src/commit.luau       commit-store cache, fetch, mark, resolve
src/datastore.luau    the only calls into DataStoreService (GetDataStore/GetAsync/SetAsync/UpdateAsync)
src/session.luau      one key: journal, watch (a group's landing or loss), merge, pull (read or update), adopt, unload, touch, wipe / wipe_key (cake-style class)
src/pull_loop.luau    the per-session loop (pull_interval when dirty, idle_interval when clean)
src/recorder.luau     jecs added/changed/removed listeners feeding a sink (pairs packed per write, jecs.Name index); used by capture and migrations
src/relations.luau    saveable pairs: pack the dictionary of a relation's pairs, apply one onto an entity
src/children.luau     child index (entity → parent/kind/id), ancestry paths, kind_of, pack / pack_fields_of, each_child / each_nested, delete_tree (marks deleting), stored_children
src/capture.luau      world writes → validated ops, batch capture (undos, carried marks), shadows, lazy flush at write time (flush_lazy), child put/drop ops
src/claims.luau       child pairs: claim and unclaim (on_attached/on_detached), kind validation, id assignment, claim-time supply (supply_claimed), pre-step child indexing, the recorder sink (install)
src/reconcile.luau    merged truth → entity (initials, decode, apply; lazy-marked keys skipped), child supply, reset_child, baselines, snapshots, wipe_entity
src/migrations.luau   scratch-world migrations
src/foreign/          adapters for importing from other libraries (lapis.luau)
src/listeners.luau    data_link listeners → events; install/uninstall
src/link.luau         link lifecycle: link/unlink/loaded/load_failed/closed/pulled handlers, cleanups, get_session, wipe_key, detach_all, resupply
src/step.luau         the event loop, get_session, wipe, close, the world-level hook
src/batch.luau        batch/delta: capture, single-key groups journaled and settled through the session's watch (await flushes them), shared commit in the background, rollback
src/handle.luau       Batch: the handle batch/delta return (outcome, result and keys via hold/get_result/get_keys, landed/refused hooks, await, which runs the flush installed by flush_with; cake-style class)
src/index.d.ts        the roblox-ts surface
tests/specs/          TestEZ specs, never inside src
tests/coverage.luau   block instrumenter used by the runner
tests/coverage_check.luau  self-check: instruments fixtures and asserts the marker counts
tests/run.luau        Lune runner
tests/typecheck/      roblox-ts usage compiled by `npm run typecheck`
```

## Style

- snake_case for everything: modules, locals, functions, fields, exported ids.
- Module-level `local function name(...)`, not methods on a table literal.
- Modules return `table.freeze({ ... })`; `init.luau` also sets `.default = self`.
- Factories are `create_x` / `load_x`, predicates `is_x`, accessors `get_x` / `is_x`.
- Every user-facing string lives in `src/messages.luau` (`errors`, `warnings`, `closures`,
  `reasons`).
  `src/index.d.ts` is the one file that carries doc comments: it is the typed surface
  roblox-ts users read in their editor.

## Classes (the cake pattern)

`src/session.luau`, `src/handle.luau` and `src/mutex.luau` are the reference:

- Methods are module-level `local function name(self: types.X, ...)`.
- A `template` table at the bottom holds default values plus the method references;
  `create_x` does `table.clone(template)`, re-creates every mutable sub-table, sets
  `setmetatable(instance, meta)` and returns `instance :: types.X`.
- `meta` carries only `__tostring` (`Session(key)`, `Mutex(free)`, `Batch(pending)`); no
  `__index`.
- Immutable by-value state (scalars, functions, frozen variant records such as `status`
  and `outcome`) lives in `internal_values`, mutable collections in their own
  `internal_*` field; the public
  surface is getters (`get_key`, `is_open`) and verbs. The public type (`Session`) lists
  only that surface; `SessionInternal = Session & { internal_*, internal verbs }` is what
  the module and the rest of the library use. Nothing outside the class module reads an
  `internal_*` field; add a getter instead. cake marks internals `read` in its types;
  miumiu does not yet, because the default (old) Luau solver in luau-lsp rejects the
  modifier and the new one adds unrelated errors.
- Identity is a `symbol` field checked by `is_x`, never `getmetatable`.
- Events are one `hook(self, hooks.x, callback) -> disconnect` over the typed symbols in
  `src/hooks.luau` (`PulledHook = Symbol<"pulled">`; `SessionHook` is an intersection of
  overloads that gives each callback a real signature; `BatchHook` does the same for
  `landed` / `refused`; the world-level `miumiu.hook(world, refused, fn)` in `step.luau`
  uses the same registry on the world state), backed by `src/callbacks.luau`
  (`connect` / `invoke` / `fire`;
  `invoke` pcalls one callback and warns through `messages`, `fire` does that for every
  connected one; `Batch:hook` invokes at once when the batch is already settled).
  Background loops live in their own module (`src/pull_loop.luau`), never inside the
  class file.
- Validation helpers are `validate_*(self)`.
- Requires: `types` first, then the rest alphabetically. Every module aliases the types it
  uses at the top (`type Session = types.Session`). String requires: `require("./sibling")`;
  `@self/x` from an `init.luau` for its own children, `./x` from an `init.luau` for the
  folder's siblings.
- Functions that return several values return one record type (`PullResult`,
  `Resolution`), not a tuple. State with phases is a union on `kind`, never optional
  fields (`LinkPhase`, `Event`, `Undo`).
- `--!` pragmas are allowed. Nothing else is.
- No comments. If a decision needs explaining, put it in the commit message or
  `DESIGN.md`.

## Types

- `.luaurc` is `nonstrict` (WCS convention). Annotate what matters; casts only when
  load-bearing. jecs arrives through `dependencies/jecs.luau`, whose return is cast to
  `typeof(require(script.Parent.Parent.Parent.jecs))` so the sourcemap gives it real
  types; `types.luau` redeclares `Entity<T>` structurally. `Symbol<T>` is phantom-typed
  on its name (`PulledHook = Symbol<"pulled">`); the old solver treats generics as
  invariant, so `Symbol` defaults to `any` and `hooks.luau` casts each symbol once.
- A variant record is a discriminated union keyed by `kind`, not one table with every
  field optional. Refine on `value.kind` directly.
- Never use an `[any]: any` indexer to silence the checker.
- Unused parameters are prefixed `_` (selene `unused_variable`).

## ECS rules

- Ids are preregistered in `src/ids.luau` with `jecs.component()` / `jecs.tag()` and
  named `miumiu.<name>` through `jecs.Name`. Never create ids in the game world at
  runtime. Migrations run in a scratch `jecs.world()` that mirrors the schema ids with
  `world:entity(id)`; legacy keys become components of that scratch world only.
- World calls use colon methods (`world:set`, `world:get`); roblox-ts emits the same.
- The game world is written only by `step` (through `reconcile` and the queued cleanups),
  `batch`'s rollback, a guard's restore, `capture.reject_unloaded`, the undo of a
  rejected child pair or tag, claim-time supply of an attached child (`claims.attach` →
  `reconcile.supply_child`), `wipe` (`reconcile.wipe_entity`) and child-id minting
  (`children.mint_id`), all but the minting (which writes `child_id` bare: nothing
  listens on it) under `state.with_applying` (which nests) so listeners skip it. Two
  deliberate exceptions run unmarked so they journal like a game write: a snapshot write
  (`reconcile.snapshot_fields`), and a refused batch's corrective restore
  (`reconcile.rewrite_fields` and an unmarked `undo_one` for an undo a later journaled op
  carried, flagged by `capture.mark_carried` / `mark_carried_children`; and
  `reconcile.repair_fields` for a child a plain write changed since). Listeners read or
  enqueue into `src/state.luau`.
- Anything run inside a `removed` hook only reads: no `world:add/set/remove/delete`.
- Plain `task.spawn` / `task.wait`; `task.defer` only for the load thread (a same-frame
  cancel never reaches storage) and for `handle.refuse`'s unhooked-refusal warning (a
  `hook(refused)` or `await` in the same frame silences it). Timestamps are `os.time()`.
  Never `os.clock()`: benchmarking only, in specs too. The `tick` shim
  MockDataStoreService needs in `tests/run.luau` is the one place it appears.
- Nothing touches `DataStoreService` at require time; the module must load on the client.
  Storage calls live in `datastore.luau` only.

## Tests

- TestEZ, specs in `tests/specs/*.spec.luau`; shared fixtures in `tests/specs/utils.luau`.
  Specs require packages by full path (`ReplicatedStorage.Packages.miumiu`) so luau-lsp
  can type them. Leaf modules (ops, delta, codec, commit, datastore, mutex, handle, schema,
  collection, session, logging, state, ids, util, callbacks) get a unit spec; world behaviour is split by phase into
  `link.spec`, `write.spec`, `unlink.spec` (unlink and `close`), `batch.spec`,
  `migrations.spec` (migrations and foreign import), `children.spec` (child kinds,
  snapshots, lazy, wipe) and `pairs.spec` (saveable pairs), each ending in a `regressions`
  block, and those cover capture/reconcile/step/link/migrations/listeners/children/relations.
  Specs never read `internal_*` fields; `utils.journal`, `utils.session_of` and
  `state.get(world)` cover what the public surface does not; `schema.create_schema`,
  and `collection.resolve_config` are spec seams, exported for the unit specs and unused
  by the library. Every spec that opens a fixture or session, or calls
  `utils.create_backend`, starts with `afterEach(utils.cleanup)` so nothing keeps pulling
  and the warn sink stops fanning into a dead backend in the next test.
- Storage is always MockDataStoreService through `utils.create_backend()`: a unique store
  per test, zeroed yields/cooldowns/budgets, `backend:fail_next(op, mode)` for failures,
  `backend:delay_next(op, seconds, mode)` for in-flight windows, `backend.warnings` for
  captured warnings, `utils.timings` for the small intervals. World specs use
  `utils.create_fixture()`, `utils.settle`, `utils.session_of`; session specs use
  `utils.open_session`. Prefer `utils.wait_until(condition)` over fixed `task.wait` calls;
  `utils.timings.never` is the "never pulls on its own" interval, `utils.timings.grace` the
  one grace wait for negative assertions (long enough to cover a pull interval with
  jitter), `in_flight` / `short` / `fast` / `window` / `slow` / `overdue` / `long` the
  delay, interval and timeout sizes, `poll` / `patience` what `wait_until` uses; specs
  never spell a wait, delay or interval out as a literal. The mock
  completes calls synchronously, so a spec that needs a load in flight uses
  `delay_next("GetAsync", s, "before")`: a load is
  a `GetAsync` unless the key carries a seed or pending entries to settle. `delay_next`
  and `fail_next` take a `skip` count to target a later call. The runner honours
  `MIUMIU_TEST_TIMEOUT`; selene's TestEZ globals live in `testez.toml`.
- `rojo build test.project.json -o test.rbxl && lune run tests/run.luau test.rbxl`.
  The place has to be rebuilt after editing `src/` or a spec.
- New behaviour gets a test that fails when the behaviour is removed. Check it by
  actually breaking the code, not by assuming.
- Coverage is 100% of blocks and CI enforces it: `MIUMIU_COVERAGE=strict` makes the
  runner instrument `src/` (`tests/coverage.luau` marks every function body and branch
  arm) and fail on any block no spec reaches. A guard that no spec can reach is a guard
  for an invariant that cannot break: delete it, don't exclude it. `src/dependencies/`
  is the only exclusion. The instrumenter is line-based: it masks strings and comments,
  skips single-line functions, one-line `if … then … end` counts as one block after its
  `then`, and the statement after an early-exit guard (`return`/`continue`/`break`/
  `error(` then `end`) is its own block. Expression-level branches (`if … then … else`
  expressions, `and`/`or`, `x or default`) are invisible to it, so "100%" says nothing
  about those: an expression-level branch with distinct outcomes gets its own `it`. A
  function whose first statement is an `if`, or a statement after an early exit that is
  one, carries both markers: one for reaching it, one for its `then` arm.
  `lune run tests/coverage_check.luau` instruments fixture snippets and checks that they
  compile with the expected marker counts. Its
  string masking is `"[^"]*"`, so an escaped quote inside a string would desync it; none
  exist in `src/`. Keep a branch arm on its own line if it must be measured. A spec that
  needs a real deadline passes it explicitly (`miumiu.close(world, 0)`), never waits.

## Before committing

```
stylua --check src tests
selene src tests
rojo sourcemap test.project.json -o sourcemap.json
luau-lsp analyze --sourcemap=sourcemap.json --definitions=globalTypes.d.luau \
  --definitions=tests/testez.d.luau --base-luaurc=.luaurc src tests/specs tests/main.server.luau
lune run tests/coverage_check.luau
rojo build test.project.json -o test.rbxl && MIUMIU_COVERAGE=strict lune run tests/run.luau test.rbxl
npm run typecheck
```

`globalTypes.d.luau` comes from
`https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/<version>/scripts/globalTypes.d.luau`
at the luau-lsp version pinned in `rokit.toml` (CI reads that same pin with `sed`).
`npm run typecheck` keeps `--skipLibCheck` because `@rbxts/types` itself does not pass
`tsc` without it; `usage.ts` is what exercises `index.d.ts`.
