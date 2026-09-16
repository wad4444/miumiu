# miumiu

Persistence for jecs worlds, lockless. A collection is an entity, a save is a relationship,
the saved shape of an entity is the set of saveable components it carries. Every write to a
saveable is an operation; a session replays its operations onto the live record on every
pull and reconciles the merged truth back onto the entity. Any server may edit any key at
any time; everything converges.

## Core (v1)

| entity | declared with | meaning |
|---|---|---|
| collection | `jecs.meta(c, miumiu.collection, "store name")` | one named DataStore; `meta(c, miumiu.config, { ... })` for the rest |
| saveable | `jecs.meta(id, miumiu.saveable, "key")` | a component or tag stored under `key`; the key is the stored identity and never follows a rename |
| field | `jecs.meta(id, pair(miumiu.field_of, c or kind))` | where a saveable lives; every saveable and kind needs at least one |
| linked entity | `world:set(e, pair(miumiu.data_link, c), key)` | one stored key; pulls while linked, whether it is "your" player, another server's, or nobody's |

There is one kind of link, plus `pair(miumiu.data_shallow, c)` on the entity to load
only the root's own fields. Gifting to an offline player is: link (shallow), write,
unlink.

A saveable's initial value is the component set on itself: `jecs.meta(money, money, 0)`;
for a tag, `jecs.meta(tag, tag)` means "present at first". At link, every saveable the
entity lacks gets a deep copy of its initial before the load; stored values then
override. Initials are never journaled, so a record holds only what changed. Like
`saveable`, an initial is read when the schema is built and frozen with it.

`jecs.meta(money, miumiu.guard, t.number)` guards a component. A write whose new value
fails the guard throws at the `world:set`, after restoring the value the entity had
(inside `batch` or `delta` that also rolls the batch back). A stored value that fails the
guard is skipped on supply with one warning; the entity keeps what it had. Tags have no
guard. Guards freeze with the schema too. Building the schema warns once, listing every
component saveable without a guard.

`jecs.meta(codes, miumiu.serdes, { serialize = fn, deserialize = fn })` for a component
whose runtime value cannot go into a DataStore (sets, maps with non-string keys,
userdata). Ops carry the serialized form; supply deserializes (a throwing `deserialize`
skips the key with a warning); guards see the runtime value on both sides. Inside
`delta` the serialized forms are diffed, so `serialize` must keep element identity
(`[...set]` does). Reconcile remembers the stored value it last supplied per key and
skips it while that reference is unchanged, so a serdes component is not rebuilt every
pull. Frozen with the schema.

## Children

An entity's record can hold other entities. A child kind is declared on the tag that
marks the kind, naming the relation that points at the parent:

```luau
jecs.meta(tool, miumiu.child, { via = owner_link, key = "inventory", mode = "owned" })
jecs.meta(part, miumiu.child, { via = part_link, key = "parts", mode = "owned" })
jecs.meta(plot, miumiu.child, { via = owner_link, key = "containers", mode = "attached", id = plot_kind })

jecs.meta(tool, jecs.pair(miumiu.field_of, player_data))
jecs.meta(plot, jecs.pair(miumiu.field_of, player_data))
jecs.meta(durability, jecs.pair(miumiu.field_of, tool))
jecs.meta(part_id, jecs.pair(miumiu.field_of, tool))
jecs.meta(part_id, jecs.pair(miumiu.field_of, part))
jecs.meta(zones, jecs.pair(miumiu.field_of, plot))
jecs.meta(part, jecs.pair(miumiu.field_of, tool))            -- parts nest under tools only
```

A child is an entity carrying the kind's tag and `pair(via, parent)`. `via` must be marked
`jecs.Exclusive`, so an entity has one parent per relation and a re-parent is a removal
followed by an addition. An entity is a child under one relation at a time, and carries
one kind tag per relation; both are errors at the `world:add`. Its stored form is the
saveables that are `field_of` the kind plus its own children, so kinds nest to any depth
and a tool does not carry the player's forty fields. `field_of` is a relation from a
saveable to a collection entity or a kind tag: a saveable is a field of exactly the
targets its pairs name, a target that is neither fails the schema build, and so does a
saveable with no pair at all. Kinds use the same relation and the same rule: a kind
nests exactly under the roots and kinds its pairs name. Initials, guards, serdes and
snapshots follow the scope. There is no default root: a saveable on every root would
put the player's initials on a server record, and a kind under every kind would nest
where nobody asked, so the build lists every unscoped id and stops. A saveable may name
several collections; *Lifecycle* says what a write does then. Entities on the relation without a
kind tag are not saved. A write of a saveable on an entity that does not hold it (a
kind-only field on the root, a root-only field on a child, a field of another
collection) journals nothing, inside `batch` as well, and warns once per saveable and
holder; a child pair added under a parent that does not hold the kind is not a child at
all (no id, no index, no journal). A kind error at the `world:add` (a second kinded
relation, two kind tags on one relation, a missing or bad attached id) takes the pair or
tag back before throwing, so the entity is never half a child. An entity may link two
collections only if their root kinds do not overlap, since each record would otherwise
delete the children the other supplied; the second link gets `data_error`. Keys (saveable
and child) and attached ids cannot contain `/`: stamps for paths are keyed `key/id/...`.
The record keeps a dictionary per key:

```luau
inventory = { ["3f2a9c1e"] = { part_id = "arm", parts = { ["9b1d"] = { ... } } } }
containers = { plot = { unlocked = true, zones = { ["1"] = { level = 2 } } } }
```

Two modes, decided by who owns the entity:

- `owned`: the entity belongs to the record. The library mints its id into
  `miumiu.child_id` on first capture (children that exist before the first `step` get
  theirs then, whenever their parent holds the kind: a linked parent through a linked
  collection the kind is a field of, an unlinked one through its own kind tag or, with
  no kind tag, always; a parent's own pair may come later). A linked parent is a root
  for its children even when it carries a kind tag itself, matching where a write on it
  goes. Two children of one kind under one parent cannot share an id: the second claim
  throws and takes the pair back, a second existing one is skipped with a warning.
  Removing the pair or deleting the
  entity drops it from the record; loading spawns it; a remote drop deletes it, and its
  owned descendants with it. Re-parenting under a different owner is a drop on one
  record and a put on the other (the Exclusive
  relation fires the removal itself; inside `batch` both land as one group or neither).
  The entities the library spawned are its own: when the root unlinks, or its session
  is refused, the owned tree under it is deleted after the final write, so a gift link
  to an offline player does not leave that player's inventory alive in the world.
  Deleting a linked root is not a save: the record keeps its children, and the owned
  tree under the root is deleted on the next `step`. Deleting an owned child deletes its
  own owned tree the same way, and every entity the library deletes is marked as
  deleting for that step so an attached child hanging off it is reset rather than left
  with supplied values; queued cleanups run until none are left, so the reset lands in
  the same `step`. Owned children found under a parent when it loads and
  absent from the record are deleted: the record is the truth for owned entities.
- `attached`: the entity outlives the record (a plot claimed for a session). Its id is
  the value of the `id` component (a string or a number), authored by the game before
  the pair is added, and missing means an error at the `world:add`. The values the
  entity carries when its own pair is added are its baseline (claiming records the baseline
  of the whole attached subtree beneath it, so a nested attached entity resets to what
  it carried when its top claimed, not when its own pair was added; an owned child's
  pre-attach values enter its shadow when it attaches, so a failed batch that changed
  them restores them instead of removing them): adding the pair while the
  parent is loaded (or the parent finishing its load while the pair exists) supplies
  the record's entry for it whole (a field the entry lacks is removed, initials play no
  part) and, while the record has no entry for it yet, leaves the pre-claim values in
  place for the first put to store; its own children are supplied the same way. Stored
  child ids are strings; a group
  keyed by numbers (an imported array) is left alone until a migration rebuilds it
  through `context.legacy`, with one warning per world and kind key when no migration
  did. Removing the pair journals nothing and the
  record keeps the state; on the next `step` the entity returns to its baseline (unless
  something claimed it again in the meantime). The root unlinking resets it the same
  way. Deleting it journals nothing either.

Every write inside a child, and every child pair added or removed, journals one
`put <key>.<path>` of the nearest child (its whole stored form) or one `drop`, on every
session of the linked ancestor. jecs fires `removed` before the component leaves the
entity, so the put for a removal packs the child without the removed tag, component or
pair (the write carries what to leave out); nothing else re-packs during a removal.
Consecutive puts of the same child collapse into one unwritten group (so do consecutive
`set`s of one root key), so a value written every
frame costs one group per pull; each write still packs the child once. A group whose
write is in flight is never collapsed into: the next write appends and stamps past it.
Inside `batch` a repeated put of one path moves to the end of the batch, so the order
of nested puts holds. Children do not diff: `delta` inside a child is a whole-child put.
`put` and `drop` carry a stamp per path (`stamps["inventory/3f2a9c1e"]`), a put of a
parent outranks every put under it and clears the stamps beneath it, and the key's own
`set` outranks them all, so a late final write from a server the player already left
cannot roll a child back. A tag
with an initial that a child no longer carries is stored as `false`, so the removal
survives the next supply; a component with an initial cannot be absent from a child
(it comes back as the initial), remove the initial or store a sentinel. A write under
an unlinked or still-loading ancestor is dropped outside `batch` and rejected inside
it, as is a pair added under such a parent.

An entity linked with `pair(miumiu.data_shallow, c)` present skips the child supply for
that link: no owned children are spawned or reconciled for it, only its own saveables.
Children created under it still journal, and unlink still deletes them; an attached
entity claimed under it is not supplied from the record either. That is the
shape of a gift link to another player's key.

Migrations see children as entities of the scratch world, keyed the same way; a
migration that touches a child rewrites that top-level child's subtree from the scratch
world and leaves the others as stored. `context.stored` is the record as read, for the
shapes `legacy` cannot express (an array under a kind's key); it is read-only.

## Snapshots

`jecs.meta(last_seen, miumiu.snapshot, function(world, entity) return os.time() end)`
makes a saveable the library evaluates itself: right before every write of a session
that has something to write (interval pull, `sync`, a batch's `await`, a multi-key
batch's commit, the final write on unlink or `close`), the function runs for each linked
entity and its children and the component is set when the result changed, journaling an
ordinary `set` (or a child put) as a group of its own: during a batch's `await` or a
multi-key batch's commit it lands in the same write as the batch but is not part of the
batch, so a refusal leaves it in the record. A batch that wants a
snapshot's value inside its group sets the component by hand. A `nil`
result leaves the value alone. Idle reads never run it. It must not yield; a throwing or
yielding snapshot is warned about and skipped. Tags cannot be snapshots. Once a snapshot
is declared every leave writes, since the final write evaluates it.

## Lazy

`jecs.meta(battery, miumiu.lazy)` marks a component saveable the library reads at write
time instead of journaling per write: a write updates the entity, marks the session
dirty and remembers the key; when `writing` fires, before any callback the game
connected, the session packs each remembered key once (a whole-child put under a kind).
Unlink, `close` and `sync` flush the same way, and an unclaim flushes the attached
entity's marks before its reset; a deleted entity's marks are dropped. A pending mark is an
unwritten change: a supply
(the `pulled` event of the write that just flushed, a remote change) leaves a marked
key alone until the flush, so a per-frame value written between a flush and the next
`step` is never set back to the flushed one. Only a reset (unclaim, unlink, remote
drop), `wipe` and deletion clear marks without flushing. Inside `batch` a lazy write
is recorded like any other; inside `delta` it throws (`not a delta`), since the value
is read later. Tags cannot be lazy.

## Pairs

`jecs.meta(relation, miumiu.saveable, "buffs")` plus `jecs.meta(relation, miumiu.pairs)`
makes the pairs `pair(relation, target)` on an entity a saveable: a dictionary keyed by
the target's `jecs.Name`, `true` per pair for a tag relation, the pair's value for a
component one (a component pair without a value is neither stored nor removed). A
write of any pair journals a `set` of the whole dictionary (a put of the child under a
kind); removing the last pair journals a `remove`. Supply adds the pairs the record
names, sets their values, and removes the present pairs whose name the record lacks; a
stamped `nil` removes them all. `meta(relation, miumiu.pairs, { targets = list })`
restricts the saveable to those targets: other pairs on the relation are neither
stored nor touched by a supply. The schema keeps a name index seeded from every named
entity at build time and kept current by hooks on `jecs.Name` (a rename drops the old
name), so a target named after the first `step` resolves; a migration's scratch world
works on a copy of it. A target's name is a stored key. A target without a name, or
whose name another entity also carries (warned once per name, at build or when the
second one is named), is left out of the dictionary and left alone by a supply; a
stored name no entity carries is skipped with one warning per name; a stored value
that is not a table is skipped with a warning. The set is stored
whole: no guard, serdes, snapshot, lazy or `delta` (it throws `not a delta`), and a
batch rollback restores the previous set when the entity's pairs still match what the
batch wrote. Migrations see the pairs on the scratch entity and store what they leave.

## Migrations

```luau
jecs.meta(player_data, miumiu.migrations, {
	function(world, entity, context)
		local luck_boosts = context.legacy("luck_boosts")
		world:set(entity, boosts, convert(world:get(entity, luck_boosts)))
		world:remove(entity, luck_boosts)
	end,
})
```

Ordered, append-only. The record stores how many have been applied. A load that finds
fewer applied than declared runs the missing ones, in order, in a scratch `jecs.world()`
that mirrors the schema's ids: a template entity gets the initials, then the stored truth
on top; the callbacks mutate it; every change is recorded as an op by the same recorder
the game world uses and replayed onto the stored data. Only keys the callbacks touched
change in the record. `context.legacy(stored_key)` is for keys that are no longer
components but still sit in the record: it returns a component of the scratch world
named `miumiu.legacy.<key>` holding the raw stored value; remove it from the template and
the key leaves the record. It throws for a key the record does not hold, and for a key
that is a current saveable (use its component). `context.key` is the stored key. The
write that loads the key carries the migrated data and the new count. A fresh record is
stamped with the count and runs nothing. A record with more applied than declared was
written by a newer server: the load fails. A throwing migration fails the load and writes
nothing. Migrations run inside the load transform: synchronous, no yielding, and the game
world is never touched.

## Importing from another library

```luau
jecs.meta(player_data, miumiu.from_foreign, {
	type = "lapis",
	name = "PlayerData",
	source = lapis,
	options = { defaultData = default_player_save, migrations = lapis_migrations, validate = validate_save },
})
```

A key that has no miumiu record yet is read from the foreign store first, through the
foreign library itself (`lapis.createCollection(name, options):read(key)`), so the
library's own migrations and validation run as they would on a normal load. The result
becomes the initial truth with zero miumiu migrations applied, so every declared miumiu
migration runs on it (`context.legacy` reaches the old keys), and the load itself writes
the miumiu record. Once that record exists the foreign store is never read again for
that key. The foreign store is never written. Its name must differ from the collection's
own store name: lapis reads through its own DataStoreService, so on the real service a
shared name would have lapis reading miumiu's record. Adapters live in
`src/foreign/<type>.luau`; `lapis` is the only one. A key with no foreign document is
loaded fresh with one read.

## Operations

```luau
{ kind = "set", key = "inventory", value = { ... }, at = 1700000100 }
{ kind = "remove", key = "inventory", at = 1700000100 }
{ kind = "init", key = "money", value = 100 }
{ kind = "add", key = "money", delta = 100 }
{ kind = "insert", key = "inventory", value = { id = "sword" } }
{ kind = "erase", key = "inventory", value = { id = "sword" } }
{ kind = "put", key = "settings", path = { "volume" }, value = 0.5, at = 1700000100 }
{ kind = "drop", key = "inventory", path = { "3f2a9c1e", "parts", "9b1d" }, at = 1700000100 }
```

Captured by `world:added` / `world:changed` / `world:removed` listeners on every saveable
id, installed per world by the first `step`, `batch` or `delta`. A write on an entity that is not `data_loaded` is
not journaled. Reconciliation writes (below) are not journaled either.

- Outside `delta`: components map `world:set` → `set`, `world:remove` → `remove`; tags map
  `world:add` → `set true`, `world:remove` → `set false`. `at = os.time()`.
- Inside `miumiu.delta(world, fn)` a `set` is diffed against the previous value:

| previous → value | ops |
|---|---|
| number → number | `add (value - previous)` |
| array → array with elements appended | one `insert` per element |
| array → array with elements missing | one `erase` per element |
| dictionary → fields added or changed | one `put` per field |
| dictionary → fields removed | one `drop` per field |
| anything else | throws `not_a_delta` |

Diff is top level only and compares elements by reference: build the new value from the
old one (`table.clone` + insert, `[...old, item]`) so unchanged elements keep their
identity; a rebuilt equal element counts as changed in place. `erase` matches the first
deep-equal element on replay, since values cross the JSON boundary. `replay` never
mutates its inputs; unchanged tables come back as the same reference.

Replay onto a truth table:

| op | effect |
|---|---|
| `set` | if `at > stamps[key]`: `truth[key] = value; stamps[key] = at`, else dropped |
| `remove` | same rule, `truth[key] = nil` |
| `init` | `truth[key] = value` only when the key is absent; no stamp |
| `add` | `truth[key] = delta + (truth[key] if it is a number, else 0)` |
| `insert` | `truth[key] = truth[key] if it is a table, else {}`, append |
| `erase` | remove first deep-equal element, no-op when absent |
| `put` | if `at` beats the stamp of `key/path` and of every prefix of it: walk `path` under `truth[key]`, creating tables (replacing non-tables) on the way, set the last segment, stamp `key/path` |
| `drop` | same rule; clear the last segment when the whole path exists, stamp `key/path` either way |

`set` / `remove` are per-key last-writer-wins by timestamp, and `put` / `drop` per path,
so a stale copy from a server the player already left cannot overwrite a newer write. A
put of a parent path stamps it, and a later put under it must beat that stamp too: a
parent put is a write of the whole subtree. Delta ops (`add`, `insert`, `erase`, `init`)
compose with each other, in any order, from any server. A `set` does not compose with
anything: it replaces the whole value, so a plain `world:set(player, money, x)` on the
player's own server overwrites a gift another server added with `delta` in the same
window. Keys that several servers may touch (currencies, inventories) should be written
through `delta` everywhere.
A session journaling a `set` / `remove` / `put` / `drop` whose `at` would not beat the
stamp it currently knows bumps it to `stamp + 1`, so a writer's own successive writes
always land in order. Two servers writing the same key in the same second tie, and the
value already in the record stays. `init` seeds a key the record lacks (an initial the
entity carried) without a stamp, so two servers seeding the same initial before their
first delta converge instead of adding to nothing twice. A path stamp whose value is gone
from the record and older than `commit_timeout` is pruned on the next write, so dropped
children do not accumulate stamps forever; the window it protects (a late final write)
is far shorter than that.

## Groups

Every op belongs to a group. A group lands whole or not at all: one pull applies all of it
inside one transform; a group whose keys span several records commits through the commit
store (below). Outside `batch`, each op is its own group.

```luau
Group = { id: string, ops: { Op }, kind: "single" | "shared", coalesce: string? }
```

A session journals its own slice of a group; a `batch` that touches several keys hands
each session a `shared` group under one id, and that id is what the commit store
decides on.

`id` is a GUID from `HttpService:GenerateGUID` with the dashes stripped: 32 hex characters,
unique across servers and short enough to be a commit-store key. DataStore keys are capped
at 50 characters, so a `game.JobId` prefix would not fit.

```luau
miumiu.batch(world, function()
	miumiu.delta(world, function()
		world:set(buyer, money, world:get(buyer, money) - 100)
		world:set(seller, money, world:get(seller, money) + 100)
	end)
	world:set(buyer, inventory, with_item(world:get(buyer, inventory), item))
end)
```

- `fn` runs synchronously, ops land in the world at once. `fn` throws → every op undone
  in reverse, nothing journaled, rethrown. A commit that fails after its write started
  undoes the same way, but only the values the batch's own writes still hold (scalars
  compared by value, tables by reference, pairs by their packed dictionary): a key the
  world wrote again meanwhile keeps that newer value (it journaled on its own). An undo
  a later journaled op carried is restored with a journaled corrective write; the rest
  restore silently. jecs listeners carry no old value, so the
  library keeps a per-entity shadow of the last values it supplied or captured; rollback
  and `delta` diffs read `previous` from it.
- A write inside `batch` or `delta` to an entity that is not `data_loaded` throws and rolls
  the loaded entities back; on the unloaded entity itself only a component the write
  added is removed again (a changed or removed one has no known previous value, there is
  no shadow for an entity nobody linked). Outside them such a write is silently not
  journaled.
- Nested `batch` and `delta` join the outer call; a `batch` inside a `delta` stays in
  delta mode.
- `batch` and `delta` return a `Batch` handle as soon as `fn` ran and the group is
  journaled; they never yield. A group on one key is journaled like a plain write and
  rides the session's next write (the interval pull, an unlink, `close`, a `sync`), so a
  burst of batches costs the key nothing beyond its pull; `await` on it writes now (a
  `sync`), and it is refused when the session ends with the group unwritten (a newer
  server took the key, `close` ran out of budget, the key was wiped) or when an `await`'s
  own write fails after its retries (the session then checks the record's `landed` map
  under its lock, so a write that landed but lost its response still lands the batch,
  and a write another thread carried meanwhile is never refused; the probe retries with
  the collection's config, and if it still fails the batch is refused, the safe side for a
  receipt, which the platform re-fires); a failed interval,
  `sync` or unlink write keeps it pending and retries it, like any unwritten group. A
  `delta` whose diff is empty lands at once. A group over several keys commits in a
  spawned thread
  through the commit-store dance below. Either way it lands or is refused;
  refused means the group is dropped from every session, the world rolled back (values
  the batch still holds) and a warning when nothing hooked or awaited the handle in the
  same frame. The handle: `get_outcome` (`pending`, `landed`, `refused` with the
  message), `get_result` (what the function returned), `get_keys` (the stored keys it
  touched), `is_settled`, `hook(landed | refused)` (fires at once when
  already settled, pcalled and warned like session hooks), `await` (yields until settled
  and returns the outcome, never throws: the durability point). A nested `batch` or `delta`
  returns the outer handle. Every key in a multi-key batch must share one
  commit store (same `data_store_service`, `commit_store`, `commit_timeout`), otherwise it
  throws before touching storage. A single-key batch whose awaited write throws after
  reaching storage (the record's `landed` holds the id) counts as written, and so does a
  multi-key batch whose commit mark throws but is found in the commit store; both probes
  read past the DataStore cache. A `delta` on a key the
  record does not hold yet (an initial the entity carried) journals an `init` of the value
  the entity had before the delta, so the record never adds to nothing.
- `commit_store` writes (`mark`) make one attempt: a retry after a timeout could commit a
  group the sessions already dropped.

## Record

```luau
{
	data = { money = 120, inventory = { ... } },
	stamps = { money = 1700000100, ["inventory/3f2a9c1e"] = 1700000090 },
	pending = {
		["9c1e3f2a7b4d0e8f5a6c1d2e3f4a5b6c"] = { created = 1700000200, ops = { ... } },
	},
	landed = { ["9c1e3f2a7b4d0e8f5a6c1d2e3f4a5b6c"] = 1700000200 },
	version = 12,
	written = "0e8f5a6c1d2e3f4a5b6c9c1e3f2a7b4d",
	migrations = 1,
	format = 1,
}
```

`pending` holds the entries of multi-key groups that are not decided yet. `landed` holds
the ids of groups this record has taken, with the time, for `commit_timeout` seconds: a
write that fails after reaching storage is retried, and the retry skips groups the
record already holds instead of applying `add` twice. `version` bumps on every write.
`migrations` is how many declared migrations have been applied. `format` is the
record-format version this library writes; a read of a record in a higher `format`
closes the session like a newer migration count, so an old server cannot mangle a record
a new one owns. Top-level fields a build does not know are carried through its writes
untouched, so a new field costs nothing to add.

## Pull

One session per (world, collection, key). The session pulls on `await` of a batch on its
key, on a multi-key `batch`, on unlink, and on
its own loop: every `pull_interval` seconds (stretched by up to 50% so sessions opened
together drift apart) while it has unwritten groups, every `idle_interval` seconds while
it is clean, counted from its last pull of any kind (a `sync` or an `await` restarts the
idle clock). A clean session reads (`GetAsync`, past the read cache) and adopts the
record when its `written` id differs from the last one adopted. The read hands over to the
`UpdateAsync` below when the session has groups to write, holds a foreign seed, or the read shows
something only a write can settle: pending entries that are decided, a version-less
record, or a migration count under what this server declares.

```
transform(old):
  truth, stamps, pending, landed = old or fresh
  base = in-memory state when old.written == last adopted written, else old.data
  applied = old.migrations (declared for a fresh key, 0 for a record without the field)
  applied > declared -> fail: newer server
  applied < declared -> truth = migrate(truth)
  for id, entry in pending:
    status = commit_status(id)              from the process cache only, never a request
    committed  -> replay entry.ops, pending[id] = nil
    failed     -> pending[id] = nil
    unknown    -> keep
  for group in unwritten (in order), skipping ids in landed:
    landed[group.id] = now
    single-key group     -> replay its ops
    multi-key group      -> pending[group.id] = { created, ops = its entry for this key }
  format > known           -> fail: a newer server owns the key
  drop landed ids older than commit_timeout
  return { data = truth, stamps, pending, landed, version + 1, written = new id, migrations = declared, format = 1 }
                                           (nil when nothing changed)
```

The transform never requests anything, so it can rerun as often as Roblox needs. Ids it
did not know are looked up on the commit store afterwards (`GetAsync`, absent and older
than `commit_timeout` means failed); when any of them is decided the pull runs the
transform once more. A newer record found on either run closes the session.

Reusing the in-memory base when the record is unchanged keeps table references stable
across pulls, so an untouched key on an entity is the same table before and after. A
record that vanished from storage (`RemoveAsync` from outside) is adopted as empty; the
next write recreates it at version 1.

Budget at the defaults, per player: a clean key costs at most one read per minute
(`idle_interval = math.huge` turns idle reads off for a game that never edits a key from
two servers), an active key at most four writes per minute (jitter only stretches an
interval, 15 s to 22.5 s), a join one read, a clean leave nothing (a session with nothing
unwritten closes without touching storage; a declared snapshot or a pending single-key
batch makes the leave dirty),
a dirty leave one write. A single-key `batch` costs nothing of its own: it rides the
next pull, or one write when awaited. A multi-key `batch` over N keys costs N writes, one
commit-store write, then N reads and N writes to settle. Against Roblox's
`60 + 10 × players` requests per minute per method that stays under 40% of each budget
at any player count, leaving room for the game's own DataStore use.

Journaling is cheap per write: the session keeps its merged state incrementally (the
state before the last unwritten group is kept too, so replacing that group by coalescing
costs one replay of the new ops), and only a pull rebuilds from the base.

`written` is the record's identity: a random id per write. A session compares it, not
`version`, to decide whether the record moved under it, so a key wiped and recreated
with the same version count is still adopted rather than overwritten from a stale base.

After the write: merged truth → reconcile onto every entity linked to that key: for each
schema entry, if the entity's value differs (same reference, else deep-equal after
deserializing), set it. Each such set runs under an `applying` mark naming that entity
and id, so the listener for that exact write is skipped while a write a listener makes
to another key (or another entity) is journaled as usual. A listener that throws
propagates out of `step`; the entity's shadow is refreshed first so the value it did
receive is not diffed against a stale previous later. Reconcile remembers the stored
reference it last supplied per key, so a rejected or unchanged value is not decoded or
warned about again. Ops journaled during the yield are replayed on the merged truth
first, so the entity never loses a write made while the pull was in flight. `pulled`
fires only when the pull adopted something new and the session is still open, after the
session's lock is released, so a callback may `sync` again; it runs on the pull thread,
before the next `step` reconciles the entities, so a callback reads the truth it is
handed, not the world. `landed` and `refused` fire after the lock the same way, on the
thread that wrote: a session closed by that write (a newer record, an abandoned `close`)
fires `closed` under the lock, then lands what the write carried and refuses the rest.

A write that fails keeps the unwritten groups, single-key batches included; they go out
on the next pull. Warned. An
unlink whose final write fails keeps the session open and retrying; it closes on the
first pull that leaves nothing unwritten. A shared group the session is awaiting is
forgotten as soon as a pulled record no longer lists it in `pending`, whoever decided it;
a group dropped while its write is in flight is never awaited. A pull that finds a
record with more migrations applied than this server declares closes the session and
throws: a newer server owns that key now; the next `step` drops the link, sets
`pair(data_error, c)` to that reason on every entity and stops journaling for it. Ops
that session had not written yet are lost, and so is the final write of an unlink that
meets the newer record: a rolling deploy in which a new server links a key an old server
still holds (a gift) ends the old server's session that way. A record with no `version`
(written by hand or by an older build) is adopted through a forced write so it gets one,
and every declared migration runs on it first. A pull loop that keeps failing warns
once, and once more when it recovers.

## Commit store

Multi-key groups need one atomic decision. That is one key in a separate DataStore,
`commit_store` (default `"miumiu_commits"`):

```
1. every touched key: pull, writing pending[id]        (the batch's own pulls)
2. SetAsync(commit_store, id, true)                     the commit point
3. records clear pending on their next pull
```

A session applies its own shared group locally the moment it journals it, so every
entity of the key sees the batch's values while the decision is pending; a refusal takes
the group back from every one of them (the rollback undoes the batch's entities, then
every touched session re-supplies its entities from the record).

A crash before 2 leaves `pending` entries that time out: any pull after `commit_timeout`
finds no commit key and drops them. A crash after 2 leaves entries that any pull
resolves as committed. A coordinator that reaches step 2 later than `commit_timeout / 2`
after `created` aborts instead, so no reader has dropped what it is about to commit.
Commit keys are never deleted; the status cache is per server.

## Lifecycle

```
world:set(e, pair(data_link, c), key)
  step: add pair(data_loading, c); spawn first pull
        ok  -> reconcile truth onto e, remove data_loading, add pair(data_loaded, c)
        err -> set pair(data_error, c) = message
world:set(e, saveable, v)              -> op in the open group (or its own)
every pull_interval / idle_interval    -> pull (rebase unwritten groups, reconcile)
miumiu.batch(world, fn)                -> journal the group, return a Batch; one key: it rides
                                          the next write, await writes now; several keys: pull
                                          each in the background and commit
world:remove(e, pair(data_link, c))    -> step: snapshots, remove data_loaded, delete the
                                          owned children of e and reset the attached ones,
                                          final pull; the link stays "unloading" until that
                                          write lands, then the session ends; nothing
                                          unwritten -> the session closes at once without
                                          a request
world:set(e, pair(data_link, c), key)  -> while "unloading": the same session is taken
                                          back, still holding its unwritten ops; the
                                          in-flight final write finishes as an ordinary
                                          pull and the entity is loaded immediately
miumiu.get_session(world, c, key)      -> the open Session behind a loaded link, else nil
miumiu.wipe(world, c, key)             -> one write: empty record, every stored key stamped
                                          past its old stamp, version bumped; a loaded key
                                          drops its unwritten groups and lazy marks,
                                          refuses every single-key batch riding it and
                                          re-initialises its entities, an unloaded key is
                                          wiped straight in the store; a failed write
                                          throws and keeps everything
miumiu.close(world, budget?)           -> cancel loads, unload every session, disconnect
                                          listeners, reset; yields until done; every
                                          later step is a no-op
```

A link without a string key, or whose collection fails to resolve, gets
`pair(data_error, c)` at the next `step` and nothing else. Setting the link to the key it
already has is a no-op.

`close` collects every session it can reach: those behind loaded links, those whose
`loaded` event is still queued, and every session an unlink handed to its final write
(they are registered before the write starts, so a shutdown right after a leave waits
for it). It retries each final write with one storage attempt per try, backing off
exponentially up to 8 s, until `budget` seconds (default 25) have passed since the call,
then warns and closes the session as `abandoned` (its `closed` hooks fire; a write still
in flight finishes and lands or refuses the single-key batches it carries when it
returns, and with no write in flight every batch riding the session is refused at
once); a game's `BindToClose` has 30, and the budget is per world. A
final write the record refuses (newer server) is warned about as lost.

`Batch` is the public surface of one `batch`/`delta` call: `get_outcome`, `get_result`,
`get_keys`, `is_settled`, `hook(landed | refused)`, `await`; one key settles through the session's
watch on whichever write carries it, several keys through the commit sequence above in a
thread of their own. `miumiu.hook(world, refused, fn)` is
the world-level listener: every refusal on the world reaches it after the batch's own
hooks, and one listener there silences the unhooked-refusal warning.

`Session` is the public surface of one key: `get_key`, `get_truth`, `get_stamps`,
`get_config`, `get_status`, `is_open`, `is_dirty`, `sync`,
`hook(pulled | closed | writing)`; README lists the same nine. `sync` is "pull now":
rebase, write, adopt. It returns only once every change journaled before the call is in
the record, and throws otherwise
(the write failed after its retries, or the session was refused or closed); the boolean
says whether something new from elsewhere was adopted, not whether the write happened.
That is the durability point for a plain write; receipts go through `batch(...):await()`
(Using it). `get_truth` and the
`pulled` payload are the stored form (serialized, before guards) and the session's own
tables: read them, never write them. `writing` fires right before a write, while the
entities are still linked and after the snapshots and lazy flushes of that write ran: a
plain write from the callback joins this write, a lazy one the next; never yield or
`sync` in it (`pulled` is the one hook that may). The link owns the
session's lifetime; there is no public `unload`. To learn when a leave's final write
landed, take the session before unlinking and hook `closed`, which receives the closure:
`{ kind = "clean" }`, `{ kind = "refused", message }` (a newer server took the key) or
`{ kind = "abandoned", message }` (`close` ran out of budget); the latter two lost the
unwritten changes. A join is: link, then gate every system that writes on `data_loaded`
(writes before it are dropped, initials are already on the entity). A leave is: unlink,
`step`, delete; deleting first still lands the journaled writes but loses snapshots and
pending lazy values. `get_status` is `{ kind = "open" }`, `{ kind = "closing" }` while
the final write runs, or `{ kind = "closed", closure }` with the same closure.

An entity linked to several collections journals a saveable write into each collection
that holds the saveable (`field_of`), so a saveable that is a field of both roots lands
in both records; a remote change one collection supplies is not journaled into the
other, so scope a saveable to one collection unless both records may drift apart.
`world:clear(entity)` removes
every component with the ordinary `removed` hook, so unlike `world:delete` it journals a
`remove` per saveable of the root; its children carry their own pairs and stay in the
record.

Rules:

- The library writes saveables and child trees only from `step` (reconciliation and the
  cleanups queued by a deletion or an unclaim), `batch`'s rollback, a guard's restore,
  the removal of a component or pair added to an unloaded entity inside `batch`, the
  undo of a rejected child pair or tag, the claim-time supply of an attached child,
  `wipe` and child-id minting. Every one but the minting (which writes `child_id` bare,
  since nothing listens on it) runs under an `applying` mark, which nests;
  two deliberate exceptions run unmarked so they journal like a game write: a snapshot
  write, and a refused batch's restore of an undo a later journaled op carried (a lazy
  flush, a plain write of the same value, a re-parent put over the child or its subtree
  mark the undo `carried`), so a corrective write reaches the record. A refused batch's
  rollback of a child compares the child's fields as a whole: a plain write that changed
  them since is left alone and only the batch's own fields are repaired. A plain write
  of the very value a pending batch already set is a no-op and is rolled back with the
  batch. A kind tag toggled without its pair inside a batch is recorded too, and a pair
  undo puts the tag and the pair back together, so a move across relations rolls back
  whole; an unclaim and re-claim inside one batch keep the first claim's baseline;
  overlapping batches hand their previous values only to captures made after them.
  After the undo the batch's sessions re-supply every entity of their keys, so a sibling
  that saw the dropped group and a value the record legitimately holds both converge. A child the
  library spawns, deletes or
  resets runs under a mark on the whole entity, so a listener on its tag that writes a
  saveable onto it during that spawn is not journaled; write to spawned children from
  `step`'s events instead. `step` never runs
  twice at once: a listener that yields inside `step` (a `sync` or `batch(...):await()`
  in an `added` hook)
  makes the next `step` a no-op until the first returns; spawn such work instead. A
  `changed` that sets the value the entity already had (same reference) is not
  journaled. `step` also toggles
  the `data_loading` / `data_loaded` / `data_error` pairs, which are never saveables.
  Listeners read or enqueue.
- A listener that throws during a supply does not stop the other entries or entities;
  the entity is still marked `data_loaded`, the shadow is refreshed, and `step` rethrows the
  first error afterwards.
- The schema (every id carrying `saveable`) is built once per world on first use, then
  frozen. Adding, changing or removing `saveable`, `collection`, `config`, `migrations`,
  `from_foreign`, `field_of`, `guard`, `serdes`, `snapshot`, `lazy`, `pairs` or `child`
  after that throws.
- A failed write never loses ops. A failed load never writes.
- The module loads on the client. Only `datastore.luau` calls DataStoreService, and only
  from inside functions.
- An unlink runs its final snapshot and lazy flush, the `data_loaded` removal and the
  release of the entity's children under `pcall`: a listener or guard that throws there
  still lets the link detach and the session unload, and `step` rethrows the first error
  afterwards. A load marks every entity of the key the same way, and `close` detaches
  every link the same way before it unloads, rethrowing once the writes are done.
- `step` drains events and the cleanups they queue until both are empty, so a reset or
  deletion an event handler queues lands in the same `step`.
- A `wipe` seen from another holder strips every stamped key without re-running
  initials, so that server ends bare where the wiping one is re-initialised; its next
  local write behaves as usual, and a pending lazy value there survives the wipe until
  its flush, like any unwritten change. The wiped record drops `landed`, so a group whose write
  reached storage right before the wipe and is retried within the window re-applies its
  delta ops on the empty record.
- A `wipe` refuses the single-key batches riding the key but not a multi-key batch
  mid-commit: its pending entry goes with the record while the coordinator may still
  mark the commit, so the other keys land it and the wiped key never replays it. The
  wipe stamps past everything; it is the erasure it claims to be, and it does not honour
  the newer-server guard: it writes this build's `migrations` and `format` whatever the
  record held.
- `format` is detection only. A record in a higher format closes the session; a record
  in a lower one is passed through `merge` unchanged and relabelled on the next write.
  A format that changes the record's shape needs a read-side upgrade transform that does
  not exist yet, so until then every reader tolerates every past shape.
- Time is `os.time()`. Servers are NTP-synced; a same-second `set` tie between two
  servers keeps the existing value (a single writer never ties with itself, see
  Operations).
- A warning about a shape the game keeps producing (a write the holder does not save, a
  kind under a parent that does not hold it, a pair on an unnamed target, a stored name
  nobody carries, a stored id-less child) fires once per world and subject, so a
  per-frame loop cannot flood the log. A warning about one stored value (a rejected or
  undeserializable value) fires once per supplied reference.
- Guards, serdes and migrations run synchronously. One that yields is rejected: a
  yielding guard throws (the previous value is restored), a yielding migration fails the
  load.

## Config

`jecs.meta(c, miumiu.config, { ... })`, every field optional:

| field | default |
|---|---|
| `data_store_service` | `DataStoreService` |
| `pull_interval` | 15 |
| `idle_interval` | 60 (never under `pull_interval`) |
| `retry_attempts`, `retry_base` | 5, 1 |
| `commit_store` | `"miumiu_commits"` |
| `commit_timeout` | 300 |
| `user_ids` | none |

`user_ids`,
a function of the key, returns the user ids every `UpdateAsync` and wipe of that key
carries (the DataStore GDPR association); it must be a function or absent.
`pull_interval` and `commit_timeout` must be positive, `idle_interval` at least
`pull_interval`, `retry_attempts` at least 1, `retry_base` at least 0, `commit_store` a
non-empty string, `data_store_service` a table offering `GetDataStore`; a config field
the library does not know fails the link, and so does anything above. `pull_interval =
math.huge` runs no pull loop at all, so idle reads are off whatever `idle_interval` says:
only `sync`, `await`, an unlink and `close` write. On the real `DataStoreService` a
`pull_interval` under Roblox's 6 s per-key write cooldown warns once per collection.
With `retry_attempts = 5, retry_base = 1` a load during an outage takes 15 s of backoff
to reach `data_error`. `pull_interval` bounds how long a write, or a single-key batch
nobody awaits, can sit unwritten;
`idle_interval` bounds how stale a key another server edits can be.

## Using it

- Call `miumiu.step(world)` every Heartbeat. Remote changes reach the world only in a
  `step`; what happens at write time is the Rules list above (a guard's restore, a
  rejected pair or tag, claim-time supply, id minting), and a batch's rollback and its
  `landed` fires on the thread that wrote the group (the pull loop, or whoever called
  `sync` or `await`), `refused` on the thread that refused it (the awaiting thread, the
  pull thread that met a newer record, `close`, `wipe`); a multi-key batch's hooks and
  rollback run on its commit thread between frames.
- Call `miumiu.close(world)` from `game:BindToClose`. Budget it under the 30 s the
  callback has.
- Link on join, unlink on leave: `world:remove(e, link)`, a `step`, then delete the
  entity and unclaim what it held. Deleting the entity first is not a save and deletes
  its owned children on the next `step`; the record keeps them. Unclaiming an attached
  entity resets it on the next `step`.
- Gate reads and writes on `pair(data_loaded, c)`:
  initials are on the entity before the load, stored values arrive with `data_loaded`.
  `world:added(miumiu.data_loaded, fn)` with `id == pair(miumiu.data_loaded, c)` is the
  ECS-shaped "player is ready"; jecs keys hooks by the relation, so a hook on the pair
  itself never fires. Do not yield in that hook; spawn the work.
- `get_session` is nil while a leave's final write is in flight; the entity has no
  `data_loaded` then and its writes are not saved. A relink in that window takes the
  session back, so `closed` does not fire for it.
- A failed load leaves `pair(data_error, c)` and the `data_link`; nothing retries by
  itself. Remove and re-set the link to try again.
- Writes to an entity that is not `data_loaded` are dropped outside `batch`/`delta`.
  Writes inside `delta` must build the new value from the old one so unchanged elements
  keep their identity.
- Two `batch`es on one key ride the same write; two `await`s inside 6 s queue behind the
  write cooldown. A multi-key batch's pull carries the single-key batches pending on its
  keys and lands them early; its refusal leaves them alone.
- `miumiu.get_session(world, c, key)` gives the live session for forcing a `sync`,
  reading `is_dirty`, or hooking `pulled`/`closed`/`writing`. `batch` and `delta` never
  yield; hook the returned handle, or `await` it where yielding is allowed.
- A link to another player's key (a gift) spawns that player's owned children while it
  is loaded and deletes them again at unlink; add `pair(miumiu.data_shallow, c)` before
  the link to skip that and only write.
- `child_id` is nil on a child created before the first `step`; it is minted then. An
  entity is a child under one relation at a time. An attached entity returns to what it
  carried at claim time when unclaimed.
- Moving an entity between records is a `drop` on
  one session and a `put` on the other: wrap it in `batch` so both land or neither (two
  keys go through the commit store), and remove the old pair or tag before adding the
  new one on a different relation.
- Receipts: write the receipt and grant the reward in one `batch` (a `delta` inside for
  the composing keys) and `await` it, `PurchaseGranted` on `landed`, `NotProcessedYet`
  on `refused` or when `get_session` is nil. Keep processed receipts as a dictionary (a capped
  array is not a delta), so two servers granting at once compose.
- `miumiu.wipe(world, c, key)` erases a key in one write: empty record, every stored key
  stamped, version bumped, unwritten groups and lazy marks dropped, the linked entities
  stripped and re-initialised, owned children deleted, attached ones reset to baseline.
  A key nobody holds is wiped straight in the store.
- A saveable marked `miumiu.lazy` is read at write time: writes update the entity and
  mark the session dirty, the value is packed once per write cycle. For values written
  every frame.
- A key that grows past the 4 MB DataStore limit fails every write: the session keeps
  retrying, `close` warns, the data stays in memory. Keep saveables small.

## Later, each its own decision

peek, a MessagingService nudge so a
write reaches other holders before their next pull, an advisory lock that kicks a second
holder, a strict mode that warns when a system writes to an entity it did not link.
