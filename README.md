# miumiu

Persistence for [jecs](https://github.com/Ukendio/jecs) worlds on Roblox, without session
locks. A collection is an entity, a save is a relationship, the saved shape of an entity is
the set of saveable components it carries. Every write to a saveable is an operation; a
session replays its operations onto the live record and reconciles the merged truth back
onto the entity. Any server may edit any key at any time; everything converges.

`DESIGN.md` is the specification. This file is the ten-minute version.

## Install

Wally:

```toml
[dependencies]
miumiu = "cheetiedotpy/miumiu@0.1.0"
```

roblox-ts:

```
npm install @rbxts/miumiu
```

Both need jecs 0.11.

## Declare

```luau
local jecs = require(path.to.jecs)
local miumiu = require(path.to.miumiu)

local player_data = jecs.tag()
jecs.meta(player_data, miumiu.collection, "PlayerData")
jecs.meta(player_data, miumiu.config, { pull_interval = 15, idle_interval = 60 })

local money = jecs.component() :: jecs.Entity<number>
jecs.meta(money, miumiu.saveable, "money")
jecs.meta(money, money, 0)
jecs.meta(money, miumiu.guard, function(value)
	return type(value) == "number"
end)

local tutorial_done = jecs.tag()
jecs.meta(tutorial_done, miumiu.saveable, "tutorial")

local world = jecs.world()
```

Ids come from `jecs.component()` / `jecs.tag()` and are described with `jecs.meta`
*before* `jecs.world()`: jecs applies that metadata when a world is created and never
again. Require miumiu before that too, its own ids are named the same way. Ids made with
`world:component()` after the fact take `world:set(id, miumiu.saveable, "money")`
instead. `miumiu.saveable` gives a component or tag its stored key. The component set on
itself is its initial value. A guard rejects bad writes and skips bad stored values.
Everything is declared before the first `miumiu.step` (or `batch` / `delta`); the schema
freezes there.

`miumiu.config` fields, all optional:

| field | default | meaning |
|---|---|---|
| `pull_interval` | 15 | seconds between writes while something is unwritten |
| `idle_interval` | 60 | seconds between reads while clean; `math.huge` turns them off |
| `retry_attempts`, `retry_base` | 5, 1 | storage retries and their base delay, doubling |
| `commit_store`, `commit_timeout` | `"miumiu_commits"`, 300 | the store and window multi-key batches commit through |
| `data_store_service` | `DataStoreService` | swap in a mock for tests |
| `default_scope` | `false` | with several collections, the one that takes unscoped saveables |
| `user_ids` | none | `function(key)` returning the user ids every write and wipe of that key carries |

## Link

```luau
local link = jecs.pair(miumiu.data_link, player_data)
local entities: { [Player]: jecs.Entity } = {}

Players.PlayerAdded:Connect(function(player)
	local entity = world:entity()
	entities[player] = entity
	world:set(entity, link, tostring(player.UserId))
end)

Players.PlayerRemoving:Connect(function(player)
	local entity = entities[player]
	entities[player] = nil
	world:remove(entity, link)
	miumiu.step(world)
	world:delete(entity)
end)

RunService.Heartbeat:Connect(function()
	miumiu.step(world)
end)

game:BindToClose(function()
	miumiu.close(world)
end)
```

`close` writes every open session and yields until the writes land or its budget runs
out (25 s by default, under the 30 s `BindToClose` allows).

While the first read is in flight the entity carries `pair(miumiu.data_loading, c)`;
once stored values are on it, `pair(miumiu.data_loaded, c)`. A failed load sets
`pair(miumiu.data_error, c)` to the reason. Gate your systems on `data_loaded`. Leave in
this order: unlink, a `step`, then delete the entity. Writes before `data_loaded` are dropped, so
link first and gate the systems that write on the pair. A write made after the link is
removed is not saved. Deleting a linked entity is not a save either: writes already
journaled still land with the final write, but snapshots and pending lazy values are
lost, and the record keeps the children the entity had. Inside a scheduler, an unlink
in one system and the delete in the next frame's system after the `step` one is the
same order. To know when the final write
landed, take the session before unlinking and hook `closed` (a relink before the write
lands takes the session back, and `closed` does not fire):

```luau
local session = miumiu.get_session(world, player_data, key)
if session then
	session:hook(miumiu.hooks.closed, function(closure)
		print(closure.kind)
	end)
end
world:remove(entity, link)
```

## Write

```luau
world:set(entity, money, 150)
```

That is a save. It is journaled as an operation and written within `pull_interval`
seconds (default 15, up to 22.5 with jitter), or now:

```luau
local session = miumiu.get_session(world, player_data, key)
if session then
	session:sync()
end
```

The session behind a key is `miumiu.get_session(world, player_data, key)`: `get_key()`,
`get_truth()` and `get_stamps()` (the stored form, read-only), `get_config()`,
`is_open()`, `is_dirty()`, `sync()`, `get_closure()` once closed, and
`hook(miumiu.hooks.pulled | closed | writing, fn)`. `is_dirty()` stays true while a
write is in flight.

Writes that must land together, across any number of players, go in a batch; writes that
should compose with what other servers did go in a delta:

```luau
miumiu.batch(world, function()
	miumiu.delta(world, function()
		world:set(buyer, money, world:get(buyer, money) - 100)
		world:set(seller, money, world:get(seller, money) + 100)
	end)
	world:add(buyer, tutorial_done)
end)
```

`batch` and `delta` both yield until every key they touched has the group, and throw
(rolling the world back) when they cannot. Inside `delta`, build new tables from the old
ones so untouched elements keep their identity.

## Items as entities

Entities related to the player can be part of the record. Declare the kind on its tag:

```luau
local owner_link = jecs.tag()
jecs.meta(owner_link, jecs.Exclusive)

local tool = jecs.tag()
jecs.meta(tool, miumiu.child, { via = owner_link, key = "inventory", mode = "owned" })

local part_id = jecs.component() :: jecs.Entity<string>
jecs.meta(part_id, miumiu.saveable, "part_id")
jecs.meta(part_id, jecs.pair(miumiu.field_of, tool))
```

The kind tag is the persistence marker: give it only to entities that belong in the
record, and keep a transient variant (a ghost golem, a preview part) on a tag of its
own. Any entity with `tool` and `pair(owner_link, player)` is stored under `inventory`, keyed
by an id the library mints into `miumiu.child_id`, with the saveables that are
`field_of` the kind. A saveable with no `field_of` pair lives on the collection's root
(with several collections, the one marked `default_scope`) and on no kind; with pairs it
lives exactly where they point, so `money` on both the player and its tools is
`pair(field_of, player_data)` plus `pair(field_of, tool)`. Kinds scope the same way:
`jecs.meta(part, jecs.pair(miumiu.field_of, tool))` nests parts under tools only, and a
kind with no pair nests under that root and every kind. The relation must be
`Exclusive`, and an entity is a child under one relation at a time. Write to it like any
entity; it lands in the player's record. Remove the pair or delete the entity and it
leaves the record. Loading spawns the entities back, with initials for anything the
record lacks, and unlinking deletes them again. Children nest: a golem tool can own part
entities through another kind.

For server entities that a player only borrows (a plot claimed for the session) use
`mode = "attached"` with an `id` component you set yourself. Claiming lays the record's
values over what the entity carries; unclaiming keeps the state in the record and puts
the entity back to what it carried at claim time on the next step, so the next occupant
starts from theirs. Claiming records that baseline for the whole attached subtree, so a
shelf attached to a plot resets with the plot. Plots, zones and shelves can share one
kind tag: the `id` value (`"plot"`, `"zone_3"`) tells them apart in the record, and
`field_of` on the kind decides what they store. With two or more collections in one
world every saveable and kind needs a `field_of` pair.

Values that only make sense at write time are snapshots:

```luau
jecs.meta(last_seen, miumiu.snapshot, function(world, entity)
	return os.time()
end)
```

A snapshot must not read its own saveable: a playtime that adds "now minus session
start" to its stored value compounds on every write. Keep the base in a non-saveable
component and compute from that:

```luau
world:added(miumiu.data_loaded, function(entity, id)
	if id == loaded then
		world:set(entity, playtime_base, world:get(entity, total_playtime) or 0)
		world:set(entity, session_start, os.time())
	end
end)
jecs.meta(total_playtime, miumiu.snapshot, function(world, entity)
	return world:get(entity, playtime_base) + os.time() - world:get(entity, session_start)
end)
```

## Relationships

Pairs on an entity can be saved too. Name the relation and mark it `pairs`:

```luau
local has_buff = jecs.tag()
jecs.meta(has_buff, miumiu.saveable, "buffs")
jecs.meta(has_buff, miumiu.pairs)

local fire = jecs.tag()
jecs.meta(fire, jecs.Name, "fire")

world:add(player, jecs.pair(has_buff, fire))
```

The record holds `buffs = { fire = true }`: a dictionary keyed by each target's
`jecs.Name`, `true` for a tag relation or the pair's value for a component one. A
target's name is a stored key, like a saveable's: keep it unique and never rename it
once shipped (a renamed target orphans its stored pairs, recoverable through
`context.stored` in a migration). A target without a name, or whose name another
entity also carries, is left out with a warning; a stored name no entity carries is
skipped with a warning. The set is stored whole, so it takes no guard, serdes,
snapshot, lazy or `delta`. Scope the relation with `field_of` like any saveable.

A component relation stores the pair's value. A timed buff and its expiry loop:

```luau
local buff = jecs.component() :: jecs.Entity<{ multiplier: number, expires_at: number }>
jecs.meta(buff, miumiu.saveable, "buffs")
jecs.meta(buff, miumiu.pairs, { targets = { oil_buff, cell_buff } })

world:set(golem, jecs.pair(buff, oil_buff), { multiplier = 2, expires_at = os.time() + 300 })

for golem, applied in world:query(jecs.pair(buff, oil_buff)) do
	if applied.expires_at <= os.time() then
		world:remove(golem, jecs.pair(buff, oil_buff))
	end
end
```

`targets` limits what is stored: a `blessing_buff` on the same relation stays a
server-side effect. Each removal journals the whole dictionary again, and a buff that
expired while the record sat in storage is supplied at load and removed by the next
tick, one write. A buff with more state than a value (a source item, a stack count that
changes) is better as an owned child with `destroyed_at`; its `world:delete` is the
`drop`.

## Moving items between records

Re-parenting a child (a gift between two online players, a part moving from a tool onto
a golem) is a `drop` on one record and a `put` on the other. Wrap it in `batch` so both
land or neither; two different keys go through the commit store. When the new parent
sits on a different relation, remove the old pair and kind tag before adding the new
ones: an entity is a child under one relation at a time and the second `world:add`
throws.

```luau
miumiu.batch(world, function()
	world:remove(part, jecs.pair(owner_link, player))
	world:remove(part, tool)
	world:add(part, part_kind)
	world:add(part, jecs.pair(part_link, golem))
end)
```

## Values written every frame

A component set every Heartbeat (a golem's battery) should not journal a put per frame.
Mark it lazy: writes land on the entity as usual, and the library reads the value once
per write cycle.

```luau
jecs.meta(battery, miumiu.saveable, "battery")
jecs.meta(battery, miumiu.lazy)
```

A lazy write still counts as unwritten, so the session writes on its next interval;
unlink, unclaim and `close` write pending lazy values too, and a pull never sets a
pending value back. Inside `batch` a lazy write is recorded
like any other; `delta` refuses it, since a value read at write time has no delta.

## Other players

There is no separate API for a player who is offline or on another server. Any key can
be linked from anywhere, so a gift is a link, a write, an unlink:

```luau
local loaded = jecs.pair(miumiu.data_loaded, player_data)
local shallow = jecs.pair(miumiu.data_shallow, player_data)
local pending_gifts: { [jecs.Entity]: number } = {}

world:added(miumiu.data_loaded, function(entity, id)
	local amount = pending_gifts[entity]
	if id ~= loaded or amount == nil then
		return
	end
	pending_gifts[entity] = nil
	task.spawn(function()
		miumiu.delta(world, function()
			world:set(entity, money, world:get(entity, money) + amount)
		end)
		world:remove(entity, link)
	end)
end)

local function gift(user_id: number, amount: number)
	local target = world:entity()
	pending_gifts[target] = amount
	world:add(target, shallow)
	world:set(target, link, tostring(user_id))
end
```

`data_shallow` keeps the other player's items (below) out of this world: the link loads
only the root's own values. Without it their whole inventory would be spawned as entities
here (kind tag, `pair(owner_link, target)`, `child_id`, the kind's fields) and deleted
again at unlink; adding the pair after the load changes nothing. With
`idle_interval = math.huge` the other server never sees the gift until its own next
write.

jecs hooks are keyed by the relation, so listen on `miumiu.data_loaded` and compare `id`
with the pair; `world:added(pair(...))` does not fire.

`delta` journals `add money amount`, which composes with what the player's own server
writes as long as that server also writes money through `delta`. A plain `world:set`
there replaces the whole value and would overwrite a gift that landed in the same
window, so write shared currencies through `delta` everywhere. The hook runs inside
`step`, hence the `task.spawn`: `delta` yields, and `step` must not. `batch` makes the
whole thing one group. A transfer between two players,
one of them elsewhere, is a `batch` over two linked entities:

```luau
miumiu.batch(world, function()
	miumiu.delta(world, function()
		world:set(sender, money, world:get(sender, money) - amount)
		world:set(receiver, money, world:get(receiver, money) + amount)
	end)
end)
```

The other server sees the change within its `idle_interval` (default 60 s, plus one pull
tick), or on its next write. If that player is online here as well, link the same key
from both entities: they share one session and see each other's writes on the next step.

## Receipts

`batch` returns only once everything it wrote is in the record and throws otherwise, so
it is the durability point. Write the receipt and grant the reward in one batch: a crash
between the two cannot leave a receipt marked processed with nothing granted.

```luau
local function process_receipt(receipt): Enum.ProductPurchaseDecision
	local entity = entities_by_user[receipt.PlayerId]
	if not entity or not miumiu.get_session(world, player_data, tostring(receipt.PlayerId)) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if world:get(entity, processed_receipts)[receipt.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local ok = pcall(miumiu.batch, world, function()
		if not grant(entity, receipt.ProductId) then
			error("nothing to grant")
		end
		miumiu.delta(world, function()
			local processed = table.clone(world:get(entity, processed_receipts))
			processed[receipt.PurchaseId] = os.time()
			world:set(entity, processed_receipts, processed)
		end)
	end)
	return if ok then Enum.ProductPurchaseDecision.PurchaseGranted else Enum.ProductPurchaseDecision.NotProcessedYet
end
```

A receipt Roblox retries after a crash is already in the dictionary, so it is granted
without granting twice. A dictionary of processed ids composes across servers; a capped
array does not. Coming from an array, a migration turns it into a dictionary and prunes
what is older than the window you keep. A throw leaves the world rolled back, and Roblox
asks again later; a grant that cannot be fulfilled returns `false` and the `error` inside
the batch turns it into that same rollback. `batch` yields, so it cannot run inside a
system that must not yield: spawn it.

## When a session ends mid-play

A newer server can take a key this server holds (a rolling deploy): the entity loses
`data_loaded`, gets `pair(data_error, c)` and its writes stop saving. Hook
`world:added(miumiu.data_error, ...)` and kick the player with the message. The same
pair also carries a load failure; there, remove and re-set the link to retry.

## Wipe

`miumiu.wipe(world, player_data, key)` erases a key: a fresh record, unwritten changes
dropped, initials back on the linked entities, owned children deleted, attached ones
reset. A key nobody here holds is wiped straight in the store. Every stored key is
stamped by the wipe, so a write another server journaled against the old record loses to
it. It yields; if the write fails it throws and the session keeps its unwritten changes.

## Migrate

```luau
jecs.meta(player_data, miumiu.migrations, {
	function(world, entity, context)
		local old = context.legacy("luck_boosts")
		world:set(entity, boosts, convert(world:get(entity, old)))
		world:remove(entity, old)
	end,
})
```

Append-only. Each migration runs once per key, in a scratch world, on a template entity.
`context.stored` is the record as it was read, a frozen deep copy, for the shapes
`legacy` cannot express.

Importing from lapis: `jecs.meta(player_data, miumiu.from_foreign, { type = "lapis",
name = "OldStore", source = lapis, options = lapis_options })`. The foreign store's name
must differ from the collection's own, so the miumiu collection gets a new store and
reads each key from the old one once. Rolling out: lapis `read` bypasses its session
lock, so a server still on the lapis build keeps saving to a key miumiu has already
imported and those saves are lost; ship with a migrate-to-latest so no old server is
alive when the first miumiu server starts. Keep the lapis migrations in
`from_foreign.options` for as long as unimported keys exist, since the import runs them.
`wipe` never re-imports: the wiped key has a record.

An imported record usually keeps items in arrays. Children are keyed by id, so an array
under a kind's key is left alone (with one warning) until a migration turns it into
children:

```luau
function(world, entity, context)
	local old = context.legacy("inventory")
	for _, item in world:get(entity, old) do
		local tool = world:entity()
		world:add(tool, tool_kind)
		world:set(tool, part_id, item.part_id)
		world:add(tool, jecs.pair(owner_link, entity))
	end
	world:remove(entity, old)
end
```

Arrays nest the same way: a tool that carried `parts = { { kind = "arm" } }` becomes a
tool entity owning part entities, and the tool's own fields move onto it:

```luau
function(world, entity, context)
	for _, item in context.stored.inventory do
		local tool = world:entity()
		world:add(tool, tool_kind)
		world:set(tool, part_id, item.part_id)
		world:add(tool, jecs.pair(owner_link, entity))
		for _, stored_part in item.parts or {} do
			local part = world:entity()
			world:add(part, part_kind)
			world:set(part, part_id, stored_part.kind)
			world:add(part, jecs.pair(part_link, tool))
		end
	end
	world:remove(entity, context.legacy("inventory"))
end
```

A container's own lists (unlocked zones, placed decorations) are simpler as dictionary
saveables scoped to the container kind than as children: one `field_of` pair, one put,
no ids to keep. An imported container that keeps a plain dictionary under a nested
kind's key (`containers.plot.zones = { ["1"] = 2 }`) is skipped entry by entry with a
warning until a migration reshapes it; attached ids are strings in the record:

```luau
function(world, entity, context)
	for id, stored in context.stored.containers or {} do
		local plot = world:entity()
		world:add(plot, container)
		world:set(plot, container_id, id)
		world:add(plot, jecs.pair(holds, entity))
		for index, rarity in stored.zones or {} do
			local zone = world:entity()
			world:add(zone, zone_kind)
			world:set(zone, zone_index, tonumber(index))
			world:set(zone, crystal_rarity, rarity)
			world:add(zone, jecs.pair(container_link, plot))
		end
	end
end
```

## roblox-ts

```ts
import { component, meta, pair, tag, world as create_world } from "@rbxts/jecs";
import miumiu from "@rbxts/miumiu";

const player_data = tag();
meta(player_data, miumiu.collection, "PlayerData");

const money = component<number>();
meta(money, miumiu.saveable, "money");
meta(money, money, 0);

const world = create_world();

function link(player: Player) {
	const entity = world.entity();
	world.set(entity, pair(miumiu.data_link, player_data), `${player.UserId}`);
	return entity;
}
```

Every export is typed in `src/index.d.ts`. `Set<string>` and `Map<string, T>` are plain
string-keyed tables already and need no serdes; `Set<number>` and `Map<number, T>` do.

## Warnings

`miumiu.set_warn(fn)` routes every warning the library emits (guard rejections on stored
values, failed writes that are being retried, a final write refused by a newer server or
given up by `close` and the changes it lost, a write on an entity that does not hold the
saveable, a pair on an unnamed or ambiguously named target, two entities sharing a
`jecs.Name`, a stored name nobody carries). A warning about a shape the game keeps
producing fires once per world and subject, so a per-frame loop cannot flood the log.
The default is `warn`.
