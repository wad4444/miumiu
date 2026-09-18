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
| ordered store | `jecs.meta(o, miumiu.ordered, { component = field, ... })` plus `pair(field_of, c)`, named by `jecs.Name` | an `OrderedDataStore` ranking one root field of `c`, one store per period, optionally resetting the field, with `on_period_change` for the keys that placed; or all-time (Ordered) |

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
  tree under the root is deleted on the next `step`. An owned child's pair removed
  between the root losing its last link pair and the `step` that unlinks it is held
  back: at that `step` it is journaled as a drop if the root still exists (the game
  dropped it), and otherwise treated like the root's deletion (record kept, entity
  deleted). An owned child claimed under a root whose load is in flight is put into the
  record once the load finishes instead of being removed as absent. Deleting an owned child deletes its
  own owned tree the same way, and every entity the library deletes is marked as
  deleting for that step so an attached child hanging off it is reset rather than left
  with supplied values; queued cleanups run until none are left, so the reset lands in
  the same `step`. Owned children found under a parent when it loads and
  absent from the record are deleted: the record is the truth for owned entities. Two
  roots linked to one key each mirror that record's owned children, so one stored child
  is spawned once per root; a drop from either copy drops the entry and the other copy
  goes on the next supply, and a root that unlinks takes only its own copies with it.
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
is declared every leave evaluates it, and writes when the value changed.

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
works on a copy of it. A target's name is a stored key. The first entity to carry a
name owns it in the index; a second one named the same (warned once per name, at build
or when it is named) is left out of the dictionary and left alone by a supply, so a
stored name never retargets while its owner lives, and a target without a name is left
out the same way; a
stored name no entity carries is skipped with one warning per name; a stored value
that is not a table is skipped with a warning. The set is stored
whole: no guard, serdes, snapshot, lazy or `delta` (it throws `not a delta`), and a
batch rollback restores the previous set when the entity's pairs still match what the
batch wrote. Migrations see the pairs on the scratch entity and store what they leave.

## Ordered

An ordered store is an `OrderedDataStore` ranking one root field: its entry for a key is
the score of that key's field, kept by the sessions that write the record. It is
declared on an entity of its own and scoped to a collection with `field_of`, like a
saveable:

```luau
local weekly_coins = jecs.tag()
jecs.meta(weekly_coins, jecs.Name, "weekly_coins")
jecs.meta(weekly_coins, jecs.pair(miumiu.field_of, player_data))
jecs.meta(weekly_coins, miumiu.ordered, {
	component = coins_this_week,
	period = { length = 7 * 86400, epoch = 345600 },
	map = function(stored) return stored end,
	period_threshold = 10,
	poll_interval = 60,
	on_period_change = function(world, entity, value, place, period) ... end,
})
```

| field | meaning |
|---|---|
| `component` | a component saveable that is a root field of the collection the `field_of` pair names. An ordered store has exactly one pair, on a collection; a saveable two collections hold gets one ordered store per collection |
| `period` | optional. `seconds`, `{ length, epoch? }` (`epoch` defaults to 0, so a 7-day period rolls over Thursday 00:00 UTC) or `function(now) -> Period`, with `Period = { index, start, finish }`; `index` must never decrease as `now` grows. Absent means all-time |
| `reset` | optional, needs `period`; default `true`. `false` keeps the field across a crossing, so each period ranks the value as it stands rather than what was earned in it |
| `map` | optional. `function(stored) -> integer?` over the stored form of the field; the default is `math.floor` of a number and nil for anything else. Nil is "not ranked" |
| `on_period_change` | optional, needs `period`. `function(world, entity, value, place, period)`, run once per key and finished period, for the keys that placed within `period_threshold` of that period's ranking: `value` is the field as that period held it, `place` its rank, `period` the finished period's index. Every period a record skipped is delivered, in order |
| `period_threshold` | how many ranks `on_period_change` reaches; a key below them is never called; default 10 |
| `poll_interval` | seconds after a period's end before its ranking is read for `on_period_change`; default 60. A change whose holder never delivered it is taken over after `commit_timeout` |

Its entity's `jecs.Name`, required, is the `OrderedDataStore` name: unique among the
world's ordered stores, different from every collection's store, and not another store's
name followed by a period index (a store named `weekly_3` would share a DataStore with
period 3 of a store named `weekly`), and at most 40
characters so that a period suffix fits the 50 a DataStore name allows. The score must be an
integer; Roblox documents ordered values as positive integers, so a negative score
counts as nil with one warning per store. A lower-is-better metric reads with
`ascending = true` rather than mapping. A throwing `map` is warned about once per
store and counts as nil; it must not yield. A `period` that throws or returns a bad
result is warned about once per store the same way, and the store is skipped entirely
until it works again: no push, no reset, no bookkeeping, and no change resolved, while
every other store and the record itself go on being written. `get_period`, which is the
game asking directly, still throws. `map`, `period` and `on_period_change` freeze with
the schema, like `saveable`. The name plus the widest period suffix must fit the
50-character DataStore limit; the build resolves the current period once to check it.

An all-time ranking lives in `GetOrderedDataStore(name)`; a periodic one in
`GetOrderedDataStore(name .. "_" .. index)`, one store per period, so a new period
starts on an empty store and an old one stays readable. Nothing on Roblox wipes a
store, so a period's store is never reused; scopes are not used. A periodic store's
field is the score *for the period*: when a record's field belongs to an earlier period
than the one the pulling server is in, the pull's transform resets the field to its
initial (removes it, when it has none) with a stamp of now, after landing the session's
unwritten groups, so what was journaled up to that pull counts for the ending period and
at most `pull_interval` of the new period's play lands with it. The reset is the
session's own write, not another server's, so a write journaled while the crossing write
was in flight is stamped past it rather than tying with it and losing: a single writer
never ties with itself. The reset reaches the entities like any remote change, on the
next `step`. A field a periodic store resets therefore feeds no other ordered store, and
the build says so, while several all-time stores may share a field, each with its own
`map` (wins and win rate from one stats table). `reset = false` is the periodic store
that does not own its field: the crossing moves it to the new period's store and leaves
the field alone, so the first pull of each period puts the value as it stands into that
period's ranking and the rest of the period tracks it. A board of totals per month, next
to the all-time one, is that: `on_period_change` still fires with the value at the
crossing, and such a store shares its field with any other store, since it resets
nothing. A
record that skipped several periods resets once, from the last period it was written
in, and one that crosses a second period before its `on_period_change` ran keeps the
earlier change owed. A record whose field has never scored belongs to no period until
it does, so a fresh key costs no write, and a record written before its ordered store
was declared belongs to the period in which its score is first pushed: nothing is
reset. `map` never sees nil: a field the record lacks counts as its initial, and one
without an initial is unranked.

The record keeps its ranking bookkeeping in `data["miumiu.ordered"]`, one entry per
ordered store name: `{ period, pushed, owed }`. `period` is the index the field's value
belongs to, `pushed` the last score pushed to the store, `owed` the finished periods no
holder has delivered yet: `{ from, last, values }`, the first and last of them and the
field's value at each crossing that produced one, plus the lease naming the holder that
took them. Each of the three is written as its own path, never as one put of the whole
entry, so an ordinary push cannot outrank a pending delivery. An entry whose `from` or
`last` is missing, fractional or out of order is read as absent, and so is a lease whose
holder is not a string or whose stamp is not a number. An entry whose shape is
wrong (a hand-written record, a newer build's field the reader does not know) is read as
if the bad fields were absent, never as a reason to fail the key, and the fields the
reader does not know survive its writes. It is data like any other key
(in `get_truth`, the `pulled`
payload, `context.stored`), managed by the transform and by ops the library journals;
`miumiu.` is a reserved prefix for saveable and child keys, and `context.legacy` throws
for it.

Pushing. After every pull that wrote, and after a load, a session compares the score of
the merged field with `pushed`; when they differ, that same transform writes
`pushed = score` (a load whose record is behind escalates its read to a write, like a
migration) and then, still under the session's lock, `SetAsync(key, score)` goes to the
store of the period *the record names*, not of the period this server's clock is in
(`RemoveAsync` for a nil score), so a server whose clock trails the record writes into
the ranking the record belongs to instead of reopening a finished one. A key whose score
is still its
initial's and was never pushed is not ranked, so a new store does not fill with zeros. A
rollover first pushes the final score of the ending period to that period's store, when
it differs from `pushed`. A transform Roblox reran keeps every push its runs produced,
so a write whose response was lost still pushes what its record claims. A push that
fails after its retries is warned about and
retried on the session's next pull, and a session that would otherwise close clean
drains what it still owes first; the record already claims it, so a server that dies
between the write and the push leaves the ranking behind until the next score change
(the window is one request). A push is `SetAsync` of an absolute value, so a repeated
one is harmless. It goes out on the retry budget of the pull that produced it, so the
final write of a `close` does not spend the whole budget on ordered retries. Pushes ride
the record's writes, so they cost at most one ordered write
per record write and two on the write that crosses a period, on the `SetIncrementSortedAsync` budget, which nothing else in the
library uses.

Changes. When a transform rolls a record over and the store declares `on_period_change`,
it records `owed = { from, last, values }`: the first finished period nobody has delivered
yet, the last one, and the field's stored value under each period the crossing found it
in. The lease a holder takes adds `taken` and `taken_at` to the same entry. A record that
crosses again before its change is delivered extends `last` and keeps `from`, so a key
away for three periods owes all three, not the newest.

Delivery is exactly once per key and period, not once per holder, so it is arbitrated by
a write rather than a read. A transform that finds an owed entry that is due, and whose
`taken` is either absent or older than `commit_timeout`, stamps it with the holder's id
and the time in the same `UpdateAsync` that writes the record; a second server's
transform then sees a fresh lease and leaves it alone. Only the holder named by the
record, and only while its lease is still fresh, resolves and runs the change; a holder
that dies before running it loses the lease and the next one takes it over. Three kinds
of holder take no lease at all, because none of them could deliver: a session already
closing, a session whose every entity on that key is `data_shallow` (a gift link), and a
build whose store declares no `on_period_change`. Two entities of one world linked to the
same key share one session, so they were never at risk of running it twice.

A period is deliverable once it has been over for `poll_interval` seconds, long enough
for the final pushes of sessions that were dirty at the rollover; a period older than
that waits for nothing. A holder therefore delivers `from` up to the newest deliverable
period, which is never past the last period this server itself considers finished, and
never more than sixteen periods in one pull: what is left keeps its place in the record
with `from` advanced, and the next pull continues. That bound is what keeps a record
absent for a year, or one written before the period's length changed, from spending a
ranking read per period inside the session's lock. The holder reads the top
`period_threshold` entries of each period it delivers, once per server, store and period
(cached; `get_top` of a finished period reads the same cache), and keeps the periods the
key placed in. `on_period_change` is for the keys that placed: a period the
key is not in the top of does not call it, and a key that placed in none settles the
change with no call at all, narrowing `owed` to the periods still undelivered and
dropping it when none are left.

The next `step` then runs `on_period_change(world, entity, value, place, period)` on the
first loaded, non-shallow entity of the key, once per placed period in order, `place`
always being a rank within `period_threshold`; the value is the field as that period held
it, since every crossing records what it found under its own period, a period nobody
played gets the initial, and a store that does not reset carries the last recorded value
forward instead. Every call of one change runs inside
one `batch` whose group also carries the settlement of `owed`, which narrows it to the
periods still undelivered or drops it when none are left: the callback's writes (a
reward) and the claim land together or not at all, so a refused batch, a crash before the
write or a throwing `on_period_change` (warned) leave it owed and a later load runs it
again. It runs on the stepping thread and must not yield. A callback that threw blocks
only that change: a later period's resolves normally, and another load on the same server
retries this one. The library knows no players, only entities and keys: the game maps the
entity back to its `Player`. A late push that reshuffles a finished ranking after the
holder read it changes nobody's place, since only that one read decides. Absent players
are not swept: `on_period_change` reaches a key when it is next loaded, which is when
someone is there to receive the reward.

Reading. `miumiu.get_ordered(world, weekly_coins)` returns the `Ordered` handle behind
the declaration (one per world and entity, built with the schema; an entity without the
meta, or a collection whose config fails, throws): `get_top(count, { period?, ascending? })`
yields and returns `{ { key, score } }` in rank order, one `GetSortedAsync` per hundred
entries (`count` is an integer of at least 1; `period` defaults to the current one and
is an error on an all-time store; a finished period is served from the change's cache
once read, whole when the ranking is shorter than asked, and the entries handed back are
the caller's own to keep); `get_score(key, period?)`
yields, one `GetAsync`; `get_period()` is the current `Period` without a request, or nil
for an all-time store: `finish` is when the ranking next resets, for a countdown, and
`index - 1` names the previous ranking for a "last week" page; `get_name()` is the
store's name. `miumiu.is_ordered(value)` tells a handle from anything else. The library
keeps no cache of the current period: the game reads the top on its own schedule, one
request per read.

`wipe` also removes the key from every ordered store of the collection, from the period
its own record names (the current one when the record names none), after the record
write; a store whose period cannot be resolved is skipped and a failed removal is warned
about, and either way the entry stays until the next push and the wipe itself finishes.
Entries in the stores of periods the key played in earlier stay: nothing on Roblox wipes
an ordered store, and the record names only the period it last belonged to. A `data_shallow` link pushes like any other holder but never runs
`on_period_change`. Migrations see the field through its component; a migration that rewrites it
changes the score the next push carries. A `data_store_service` without
`GetOrderedDataStore` fails the link of a collection that has an ordered store.

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
  touched), `is_settled`, `silence` (accept a refusal without the unhooked warning),
  `hook(landed | refused)` (fires at once when
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
untouched, so a new field costs nothing to add. The reader is defensive about the fields
it does know: a `data`, `stamps`, `pending`, `landed`, `version`, `migrations` or
`format` that is not the type this build writes reads as absent rather than failing the
key, and a stamp, pending entry or landed id of the wrong shape is dropped, so a
hand-written or half-migrated record loses what it cannot express instead of becoming
unreadable.

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
record, a migration count under what this server declares, an ordered store whose field
belongs to a past period or whose pushed score is behind, or an owed period change this
server can take the lease on (Ordered).

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
unwritten closes without touching storage; a snapshot whose value changed or a pending
single-key batch makes the leave dirty),
a dirty leave one write. A single-key `batch` costs nothing of its own: it rides the
next pull, or one write when awaited. A multi-key `batch` over N keys costs N writes, one
commit-store write, then N reads and N writes to settle. Against Roblox's
`60 + 10 × players` requests per minute per method that stays under 40% of each budget
at any player count, leaving room for the game's own DataStore use. An ordered store adds, per
key, one ordered write per record write that changed the score (its own budget), one
record write and one push when a key first meets a store or crosses a period, and one
`GetSortedAsync` per server, store and finished period for `on_period_change`; `get_top` is one
sorted read per hundred entries.

Journaling is cheap per write: the session keeps its merged state incrementally (the
state before the last unwritten group is kept too, so replacing that group by coalescing
costs one replay of the new ops), and only a pull rebuilds from the base.

`written` is the record's identity: a random id per write. A session compares it, not
`version`, to decide whether the record moved under it, so a key wiped and recreated
with the same version count is still adopted rather than overwritten from a stale base.

After the write: merged truth → reconcile onto every entity linked to that key: for each
schema entry, if the entity's value differs (same reference, else deep-equal after
deserializing), set it. A runtime value must be acyclic: the deep comparison walks it
without a visited set, so a table that reaches itself overflows the stack, which the
supply catches and warns rather than applying. Each such set runs under an `applying` mark naming that entity
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
miumiu.get_ordered(world, o)           -> the Ordered handle behind a declaration: get_top,
                                          get_score, get_period; reads only, sessions push
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
`get_keys`, `is_settled`, `hook(landed | refused)`, `await`, `silence`; one key settles through the session's
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
  `from_foreign`, `field_of`, `guard`, `serdes`, `snapshot`, `lazy`, `pairs`, `child` or
  `ordered` after that throws.
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
`pull_interval` unless `pull_interval` is `math.huge`, which leaves it unconstrained
because no pull loop runs, `retry_attempts` at least 1, `retry_base` at least 0,
`commit_store` a non-empty string, `data_store_service` a table offering `GetDataStore`;
a config that is not a table, and a config field the library does not know, fail the
link, and so does anything above. Two collections of one world cannot name the same
store: one DataStore holds one collection, and the schema build says so. `pull_interval =
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
holder, a strict mode that warns when a system writes to an entity it did not link, an
ordered store's rank lookup for one key (a page scan), removing a key from it for
moderation (the next push would put it back), a sweep that runs `on_period_change` for absent
keys at rollover through gift links (needs a claim key per store and period), a cached
`get_top` of the current period on an interval.
