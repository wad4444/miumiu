# Changelog

## 0.2.0 (unreleased)

Ordered stores: `meta(entity, miumiu.ordered, { component, period?, reset?, map?,
period_threshold?, poll_interval?, on_period_change? })` plus `pair(miumiu.field_of, collection)` ranks one
root field in an `OrderedDataStore` named by the entity's `jecs.Name`. Sessions push the
score with the record's write that changed it, on the ordered store's own budget. With
`period` the store is per period (`name_index`), the field resets to its initial when a
record crosses into a new period unless `reset = false` (a per-period ranking of a value
the crossing leaves alone, which may share its field with other stores), and
`on_period_change(world, entity, value, place, period)` runs for the keys that placed
within `period_threshold` of a finished period's ranking, exactly once per key and period
however many servers hold the key, inside a batch that claims the change. The claim is a
lease taken by a write, so one holder delivers it and a holder that dies without doing so
is taken over after `commit_timeout`; a session that is closing, one whose links on that
key are all shallow, and a build whose store declares no callback take no lease at all. A
record that skipped periods gets one call per period it placed in, in order, with the
value that period held, bounded to sixteen periods per pull. `Batch:silence()` accepts a
refusal without the unhooked-refusal warning. `miumiu.get_ordered(world, entity)` returns the `Ordered`
handle (`get_top`, `get_score`, `get_period`, `get_name`), `miumiu.is_ordered` tells it
apart. The record keeps its bookkeeping under `data["miumiu.ordered"]`; keys starting
with `miumiu.` are reserved, for saveables, child kinds and `context.legacy`. `wipe`
removes the key from the collection's ordered stores. A collection with an ordered
store needs a `data_store_service` with `GetOrderedDataStore`.

`Batch:get_keys()` returns `{ collection, key }` records instead of bare key strings,
since a batch may span collections and two collections may use one key string. The
exported type `Map` (an ordered store's score function) is now `ScoreMap`, in both the
Luau and the roblox-ts surface, because `Map` read as a dictionary and shadowed the
global `Map<K, V>` inside the TypeScript definitions. Both are breaking and land before
0.2.0 ships. `close` now waits, inside its budget, for a load that still owes a child
put stashed while its root was deleted, so the put is written instead of lost with the
session that would have written it; a second `close` on the same world joins the first
instead of returning while the write is still in flight.

Two collections of one world can no longer name the same store, an ordered config
field the library does not know fails the schema build, and a collection config that is
not a table fails the link. `idle_interval` is unconstrained when `pull_interval` is
`math.huge`. `wipe` of a key whose load is still in flight cancels that load and starts
it again instead of letting the stale record land. A record whose stored `data`,
`stamps`, `version`, `migrations` or `format` is not the type the library writes is read
as an empty record rather than failing the key, and a record stored with `version = 0`
is forgotten when the store no longer holds it. `Batch:get_result()` of a batch that
spanned several keys hands back the function's value, not the collection's config. A
delta that changes nothing on a key leaves that key out of the batch. A delta keeps an
untouched dictionary key containing `/` and rejects one it would drop. Owned trees and
migrations are no longer capped at 32 levels of nesting.

`Batch:await()` returns the `SettledOutcome` instead of throwing on a refusal, so a
caller written for the throwing form must branch on the result. `Batch:get_result()`
hands back what the function returned. `miumiu.hook(world, hooks.refused, fn)` hears
every refusal on a world after the batch's own hooks and counts as hooked for the
warning. A refused batch now restores exactly what it wrote, even under later writes,
lazy flushes, re-parents, claims, kind tags and pairs, including when two batches
overlapped, then supplies every entity of its keys again from the record so siblings and
children that saw the group flip back with it; an entity unlinked or rejected meanwhile
keeps no state. A batch over collections with different commit stores throws from
`batch` itself. `README.md`, `DESIGN.md` and this file ship in both packages.

Every saveable and every child kind now needs at least one `pair(miumiu.field_of,
target)`; the default root and `config.default_scope` are gone, and a schema build
with an unscoped id fails listing every one. A `batch` or `delta` before the first `step`
installs the listeners itself, so its writes are captured and an unloaded entity throws
as documented. `Session:get_closure()` is replaced by `get_status()`, which returns
`{ kind = "open" }`, `{ kind = "closing" }` or `{ kind = "closed", closure }`.
Snapshots and lazy flushes run before the game's `writing` hooks after a relink too. A
second child with an id another child of the same kind already holds under the parent
throws and takes the pair back instead of corrupting the index; a linked entity that
also carries a kind tag holds its children through its link; a claim is supplied from
the collection that holds the kind even when another link of the root is shallow; a
wipe drops only the lazy marks of the wiped collection; a rollback whose restore made a
listener throw still refreshes shadows and resupplies before rethrowing. `migrations`
and `from_foreign` freeze with the schema.

BREAKING: a batch on one key no longer writes on its own. Its group rides the session's
next write like a plain write, so a batch nobody awaits settles up to `pull_interval`
and its jitter later, never on its own under `pull_interval = math.huge`, and code that
hooked `landed` without `await` now waits that long; `await` or `sync` keeps the old
latency. It is refused when the session ends with the group unwritten (a newer server,
a `close` out of budget, a `wipe`) or when an `await`'s own write fails after its
retries; a failed interval, `sync` or unlink write keeps it pending and retries it, like
any unwritten group. `landed` and `refused` fire on the thread that wrote, after the
session's lock; a write in flight when the session closes settles the batches it
carries. An `await` inside the batch's own function throws. A multi-key batch still
commits at once through the commit store. The scratch
supply that runs before a migration no longer warns about imported arrays or non-table
children under a kind's key, since the migration is where those shapes get fixed; the
live supply still does.

Also new: `Batch` reaches roblox-ts (`batch` and `delta` returned `void` in 0.1.0; now
`Batch<T>`, `is_batch` and the world-level `hook`), `MigrationContext.legacy` is a
function property (0.1.0 typed it as a method, so roblox-ts passed the context as the
stored key), `Batch:get_keys()` names the keys a batch touched, records carry
`format = 1` and a record in a newer format closes the session like newer migrations do,
top-level record fields this build does not know survive its writes, `config` rejects an
unknown field and a `data_store_service` without `GetDataStore`, `pull_interval =
math.huge` spawns no loop, `miumiu.hook` rejects any symbol but `refused`, a guard,
serdes or snapshot that is not a function fails the schema build, and every pending set
of one key coalesces into one group across other keys.

Fixed: a claimed attached child is supplied from its record entry alone, so a field it
shed stays gone (pre-claim values stand only until the first put); a child added under
an imported array group throws until a migration rebuilds it instead of making the
record unwritable; a migration that touches an attached child no longer packs initials
into it; `context.legacy` refuses a kind key the record already holds as children;
`delta` rejects dictionary keys containing `/`; a serialize that returns nil throws
instead of removing the component; a deserialize that returns nil is skipped with a
warning; an unchanged lazy write no longer dirties the session; an awaited batch whose
lost-response write is followed by a newer record lands instead of being refused; a
batch on a closed world is refused without running its function; a leave with only an
undecided shared group, or lazy marks that died with their entity, closes without a
request; an empty-diff `delta` lands at once.

## 0.1.0 (2026-09-07)

First release candidate. Lockless sessions on jecs 0.11.

Core: saveable components and tags, operations captured from world writes, per-key
last-writer-wins stamps, a commit store for multi-key groups, guards, serdes, initial
values, `get_session`, `close` with a budget. Session hooks `pulled`, `closed(closure)`
and `writing`; `get_key`, `get_truth`, `get_stamps`, `get_config`, `is_open`,
`is_dirty`, `is_session`; `get_closure` reporting `clean`, `refused` or `abandoned`;
`sync` as the durability point of a plain write. The link pairs `data_loading`,
`data_loaded` and `data_error(message)`. `idle_interval = math.huge` turns idle reads
off and never runs under `pull_interval`; a `pull_interval` under the 6 s write cooldown
warns. `set_warn`. Group, record and child ids are GUIDs. An unlink, a load or a `close`
whose listeners throw still detaches, marks and unloads. Cleanups queued by an event
land in the same `step`.

Batches: `batch` and `delta` run their function, journal the group and return a `Batch`
handle without yielding (`get_outcome`, `is_settled`, `hook(landed | refused)` firing at
once when already settled, `await`, `is_batch`); the commit runs in the background and
`await`, which yields and throws the message on a refusal, is the durability point for
receipts. A failed commit undoes only the values its own writes still hold (a value the
world wrote again meanwhile stays), silently, fires `refused` and warns when nothing
hooked or awaited it in the same frame; a rollback that throws still settles the batch.

Children (`miumiu.child`, `miumiu.child_id`): owned entities stored inside a record,
attached ones supplied from it, nested to any depth, the relation marked `Exclusive`,
one relation per entity. Attached entities keep their claim-time values as the baseline,
recorded for the whole attached subtree when its top claims. A removal on a child (a
tag, a component, a pair, `world:clear`) reaches the record at once. A child kind must
be declared on a tag. `put`/`drop` stamped per
path, a parent put outranking its subtree and the key's `set` outranking both; no `/` in
keys or ids. Leave order unlink, `step`, delete: unlink deletes owned children and resets
attached ones. `miumiu.data_shallow` for links that must not spawn children. Imported
arrays under a kind key are left for a migration; an existing child whose id is invalid
is skipped with a warning. A second link whose collection holds the same kind gets
`data_error`.

Scopes: `pair(miumiu.field_of, target)` places a saveable or a kind on a collection's
root or under a kind. Unscoped saveables and kinds go to the default root only (the only
collection, or the one marked `default_scope`); a world with several collections
requires every scope unless one sets `default_scope`. A write on an entity that does not
hold the saveable warns once.

Pairs (`miumiu.pairs`): the pairs of a named relation stored as a dictionary keyed by
the target's `jecs.Name`, whole-value, no delta; `{ targets = list }` restricts the
stored targets; duplicate names warn and the loser is left out; a component pair
without a value is not stored.

Write-time values: snapshots (`miumiu.snapshot`) evaluated before every write, children
included, as a group of their own outside any batch; `miumiu.lazy` saveables read at
write time, flushed by unlink, unclaim and `close`, surviving the supply of the write
that preceded them, recorded normally inside `batch`, a throw inside `delta`.

Wipe: `miumiu.wipe` erases a key, loaded or not, stamping every stored key so older
writes from elsewhere lose; a failed wipe keeps the session's changes.

Config: `user_ids(key)` attaches user ids to every write and wipe of a key.

Migrations: scratch-world migrations, append-only, `context.legacy` for dropped keys and
`context.stored` for the raw record (`MigrationContext<S>` in roblox-ts); import from
lapis.

Record format (the contract a future version keeps reading): `data` (stored form per
key; tags as `true`, or `false` on a child for a removed tag with an initial; children
as dictionaries keyed by id under the kind's key, attached ids stringified; pairs as
dictionaries keyed by target name), `stamps` (`key` and `key/path/...` joined by `/` to
`os.time()`, which is why keys and ids reject `/`), `version` (incremented per write; a
version-less record is adopted through a forced write), `written` (a 32-hex GUID per
write), `migrations` (how many ran), `pending[id] = { created, ops }` and
`landed[id] = time` for in-flight and settled shared groups, group ids 32-hex GUIDs.
Ops are the eight kinds in DESIGN Operations (`set`, `remove`, `put`, `drop`, `add`,
`insert`, `erase`, `init`), `init` unstamped. The commit store holds `SetAsync(id, true)`
per committed group. DESIGN Operations and Record are the authoritative text.

Foreign stores: a collection with `from_foreign` reads a key it has no record for from
the other library once, under a store name of its own; roll it out with no old server
alive, since the other library's `read` bypasses its session lock and a late save from
an old server is lost.
