# Changelog

## 0.1.0 (2026-09-07)

First release candidate. Lockless sessions on jecs 0.11.

Core: saveable components and tags, operations captured from world writes, per-key
last-writer-wins stamps, a commit store for multi-key groups, guards, serdes, initial
values, `get_session`, `close` with a budget. Session hooks `pulled`, `closed(closure)`
and `writing`; `get_closure` reporting `clean`, `refused` or `abandoned`; `sync` as the
durability point of a plain write. `idle_interval = math.huge` turns idle reads off.
`set_warn`. Group, record and child ids are GUIDs; no `job_id` config. An unlink, a load
or a `close` whose listeners throw still detaches, marks and unloads. Cleanups queued by
an event land in the same `step`.

Batches: `batch` and `delta` run their function, journal the group and return a `Batch`
handle without yielding (`get_outcome`, `is_settled`, `hook(landed | refused)`, `await`,
`is_batch`); the commit runs in the background and `await` is the durability point for
receipts. A failed commit undoes only the values its own writes still hold, repairs a
child a plain write touched meanwhile, fires `refused`, and warns when nothing hooked
it; a rollback that throws still settles the batch.

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
that preceded them, recorded normally inside `batch`, refused inside `delta`.

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
