import type { Entity, Tag, World } from "@rbxts/jecs";

declare namespace miumiu {
	/** Stored shape of one key: saveable key → stored form of its value. */
	export type Data = Record<string, unknown>;

	/** One captured write. `set`/`remove` carry a timestamp per key, `put`/`drop` one per path; `init`, `add`, `insert` and `erase` are deltas that compose. */
	export type Op =
		| { kind: "set"; key: string; value: unknown; at: number }
		| { kind: "remove"; key: string; at: number }
		| { kind: "init"; key: string; value: unknown }
		| { kind: "add"; key: string; delta: number }
		| { kind: "insert"; key: string; value: unknown }
		| { kind: "erase"; key: string; value: unknown }
		| { kind: "put"; key: string; path: string[]; value: unknown; at: number }
		| { kind: "drop"; key: string; path: string[]; at: number };

	/** Timestamp of the last `set`/`remove` that landed per key, and of the last `put`/`drop` per `key/path`. */
	export type Stamps = Record<string, number>;

	/** A multi-key batch entry waiting for its commit decision. */
	export interface PendingEntry {
		created: number;
		ops: Op[];
	}

	/** Multi-key batch entries by group id. */
	export type Pending = Record<string, PendingEntry>;

	/** What one DataStore key holds. */
	export interface StoredRecord {
		data?: Data;
		stamps?: Stamps;
		pending?: Pending;
		landed?: Record<string, number>;
		version?: number;
		written?: string;
		migrations?: number;
	}

	/** The part of a lapis collection the import uses. */
	export interface LapisCollection {
		read(key: string): { expect(): unknown };
	}

	/** The part of the lapis library the import uses; pass the library itself. `O` is its collection options type. */
	export interface LapisLibrary<O = unknown> {
		createCollection(name: string, options: O): LapisCollection;
	}

	/** `meta(collection, miumiu.from_foreign, { type: "lapis", name, source: lapis, options })`: `options` are handed to `source.createCollection` as they are, so keep the lapis migrations in them for as long as unimported keys exist. */
	export interface LapisSource<O = unknown> {
		type: "lapis";
		name: string;
		source: LapisLibrary<O>;
		options: O;
	}

	/** Every foreign source the import understands; lapis is the only one. */
	export type ForeignSource = LapisSource<any>;

	/** `meta(collection, miumiu.config, { ... })`; every field optional. `pull_interval` (default 15) is how often a session with unwritten changes writes; `idle_interval` (default 60) is how often a clean session reads for changes from elsewhere, `math.huge` turns idle reads off. `retry_attempts` (5) and `retry_base` (1 s, doubling) shape storage retries; `commit_store` ("miumiu_commits") and `commit_timeout` (300 s) drive multi-key batches. `default_scope` marks the one collection that takes every saveable and kind without a `field_of` pair when a world declares several. `user_ids(key)` returns the user ids to attach to every write and wipe of that key (GDPR association). */
	export interface CollectionConfig {
		data_store_service?: Pick<DataStoreService, "GetDataStore">;
		pull_interval?: number;
		idle_interval?: number;
		retry_attempts?: number;
		retry_base?: number;
		commit_store?: string;
		commit_timeout?: number;
		default_scope?: boolean;
		user_ids?: (key: string) => number[];
	}

	/** What `Session.get_config()` returns: the config with defaults filled in, plus the collection's name, migrations and foreign source. */
	export interface ResolvedCollectionConfig {
		name: string;
		data_store_service: Pick<DataStoreService, "GetDataStore">;
		pull_interval: number;
		idle_interval: number;
		retry_attempts: number;
		retry_base: number;
		commit_store: string;
		commit_timeout: number;
		migrations: Migration[];
		foreign?: ForeignSource;
		default_scope: boolean;
		user_ids?: (key: string) => number[];
	}

	/** What a migration receives besides the scratch world and its template entity. `S` is the shape of the record as read; give it your old save type. */
	export interface MigrationContext<S = Data> {
		/** The stored key being migrated. */
		readonly key: string;
		/** A component of the scratch world holding a key that is no longer a saveable. Throws for current saveables and absent keys. */
		legacy: <T = unknown>(stored_key: string) => Entity<T>;
		/** The record as it was read, before any migration ran: a deep copy, frozen. Writes go through the scratch world. */
		readonly stored: S;
	}

	/** Runs in a scratch world on a template entity; every write it makes is replayed onto the stored data. Must not yield. */
	export type Migration<S = Data> = (world: World, entity: Entity, context: MigrationContext<S>) => void;
	/** `meta(component, miumiu.guard, check)`: rejects writes (throws) and stored values (skipped, warned). Return `false`, or `$tuple(false, "why")` for a reason in the message. Must not yield. */
	export type Guard = (value: unknown) => boolean | LuaTuple<[boolean, string?]>;

	/** `meta(component, miumiu.snapshot, fn)`: the library evaluates `fn` right before every write, on the linked entity and its children, and sets the component when the result changed. Return `undefined` to leave the value alone. An idle session never evaluates it: a change that only a snapshot would produce waits for the next write or the leave. Must not yield, and must not read its own saveable (keep a non-saveable base value instead). */
	export type Snapshot<T = unknown> = (world: World, entity: Entity) => T | undefined;

	/** `meta(relation, miumiu.pairs, config)`: `targets` restricts the stored pairs to those targets; other pairs on the relation are neither stored nor touched by a supply. */
	export interface PairsConfig {
		targets?: Entity[];
	}

	/** `owned` children live in the record; `attached` ones outlive it and are supplied from it while claimed. */
	export type ChildMode = "owned" | "attached";

	/** `meta(kind_tag, miumiu.child, config)`: entities carrying `kind_tag` and `pair(via, parent)` are stored under `key` on the parent, with the saveables that are `field_of` the kind (nested kinds come along on their own). `via` must be marked `Exclusive`, and an entity is a child under one relation at a time. Owned children live and die with the record and get their id in `child_id`; attached ones outlive it, keep their state in the record and are named by the value of `id`. */
	export type ChildConfig =
		| { via: Entity; key: string; mode: "owned" }
		| { via: Entity; key: string; mode: "attached"; id: Entity<string | number> };

	/** `meta(component, miumiu.serdes, { serialize, deserialize })` for values a DataStore cannot hold: `Set<number>`, `Map<number, T>`, userdata. String-keyed `Set<string>` and `Map<string, T>` are plain tables already and need none. Must not yield. */
	export interface Serdes<T = unknown, S = unknown> {
		serialize: (value: T) => S;
		deserialize: (stored: S) => T;
	}

	/** A typed hook symbol; `Args` is what the callback receives. */
	export interface Hook<Args extends unknown[], Name extends string = string> {
		readonly __hook: Args;
		readonly __name: Name;
	}
	/** Fires after a pull adopted something new, with the merged truth in stored form. */
	export type PulledHook = Hook<[truth: Data], "pulled">;
	/** Fires once when the session closes, with why: final write done, a newer server took the key, or `close` ran out of budget. */
	export type ClosedHook = Hook<[closure: Closure], "closed">;
	/** Fires right before the session writes, while its entities are still linked: snapshots run here. */
	export type WritingHook = Hook<[], "writing">;
	/** Fires once a batch's group is in every record it touched. Connecting after that fires at once. */
	export type LandedHook = Hook<[], "landed">;
	/** Fires once a batch's commit failed: the group was abandoned on every session and the world rolled back (only values the batch still held). Connecting after that fires at once. */
	export type RefusedHook = Hook<[message: string], "refused">;

	/** Where a batch stands: `pending` until its commit finishes, then `landed` or `refused`. */
	export type Outcome = { kind: "pending" } | { kind: "landed" } | { kind: "refused"; message: string };

	/** The handle `batch` and `delta` return. The commit runs in the background; hook or await it. */
	export interface Batch {
		/** `pending`, `landed` or `refused`. */
		get_outcome(): Outcome;
		/** True once landed or refused. */
		is_settled(): boolean;
		/** Connect to `landed` or `refused`; fires at once if already settled. Returns a disconnect. Callbacks are pcalled and a throw is warned, never raised. */
		hook(hook: LandedHook, callback: () => void): () => void;
		hook(hook: RefusedHook, callback: (message: string) => void): () => void;
		/** Yields until settled; returns on `landed`, throws the message on `refused`. The durability point for receipts. */
		await(): void;
	}

	/** Why a session closed: `clean` after its final write; `refused` when a newer server took the key; `abandoned` when `close` gave up on the final write. Both latter kinds lost the unwritten changes. */
	export type Closure = { kind: "clean" } | { kind: "refused"; message: string } | { kind: "abandoned"; message: string };

	/** The hook symbols `Session.hook` (`pulled`, `closed`, `writing`) and `Batch.hook` (`landed`, `refused`) take. */
	export const hooks: {
		readonly pulled: PulledHook;
		readonly closed: ClosedHook;
		readonly writing: WritingHook;
		readonly landed: LandedHook;
		readonly refused: RefusedHook;
	};

	/** One live key. Obtain through `get_session`; owned by the link, never unload it yourself. */
	export interface Session {
		/** The stored key this session holds. */
		get_key(): string;
		/** Merged truth in stored (serialized) form, including this server's unwritten ops. Read-only: the tables are the session's own. */
		get_truth(): Data;
		/** Stamps of the merged truth: per key for `set`/`remove`, per `key/path` for child puts. Read-only. */
		get_stamps(): Stamps;
		/** The collection's resolved config. */
		get_config(): ResolvedCollectionConfig;
		/** Why the session closed, once `is_open()` is false. */
		get_closure(): Closure | undefined;
		/** False once the session closed for any reason. */
		is_open(): boolean;
		/** True while ops are journaled but not yet written, including while a write is in flight. */
		is_dirty(): boolean;
		/** Rebase unwritten changes onto the live record and write them now instead of waiting for `pull_interval`. Yields; returns only once every change journaled before the call is in the record, and throws otherwise (write failed after its retries, session refused or closed). The boolean says whether something new from elsewhere was adopted, not whether the write happened. The durability point for a plain write; receipts await a `batch`. */
		sync(): boolean;
		/** Connect to `pulled`, `closed` or `writing`; returns a disconnect. Callbacks are pcalled and a throw is warned, never raised. */
		hook(hook: PulledHook, callback: (truth: Data) => void): () => void;
		hook(hook: ClosedHook, callback: (closure: Closure) => void): () => void;
		hook(hook: WritingHook, callback: () => void): () => void;
	}

	/** Drain queued link/unlink/load/pull events into the world. Call every Heartbeat. No-op after `close`. Unlink, then `step`, then delete the entity: a root deleted while linked keeps its record, and its owned children are deleted with it on the next `step`. */
	export function step(world: World): void;
	/** Unload every session and stop stepping. Yields until every final write lands or `budget` seconds (default 25) pass. Call from `BindToClose`. */
	export function close(world: World, budget?: number): void;
	/** The open session behind `pair(data_link, collection) = key`, or undefined while loading, failed, unlinked or writing its final record after an unlink. `collection` is the collection tag. */
	export function get_session(world: World, collection: Entity, key: string): Session | undefined;
	/** Erase a key in one write: a fresh empty record, every stored key stamped past its old stamp. A loaded key also drops its unwritten changes and lazy marks, puts initials back on every linked entity, deletes its owned children and resets attached ones; a key nobody here holds is wiped straight in the store. Yields; throws if the write fails, keeping everything. */
	export function wipe(world: World, collection: Entity, key: string): void;
	/** Every write inside lands as one group, on every key it touches, or none. Runs `fn` now, journals the group and returns without yielding; the commit runs in the background and the returned `Batch` reports it (`await` for receipts). A write `fn` cannot make (guard, unloaded entity, `fn` throwing) throws here and rolls the world back at once; a commit refused later rolls back only the values the batch still holds and fires `refused`. A nested call joins the outer batch and returns the outer handle. A batch that captured no saveable write lands at once; snapshots are evaluated at write time outside any batch. */
	export function batch(world: World, fn: () => void): Batch;
	/** Like `batch`, but each `set` on a root saveable is diffed against the previous value into `add`/`insert`/`erase`/`put`/`drop`. Build new values from the old ones. A write inside a child is a whole put, never a diff. */
	export function delta(world: World, fn: () => void): Batch;
	/** True for a `Session` returned by `get_session`. */
	export function is_session(value: unknown): value is Session;
	/** True for a `Batch` returned by `batch` or `delta`. */
	export function is_batch(value: unknown): value is Batch;
	/** Route the library's warnings; omit to restore `warn`. */
	export function set_warn(sink?: (message: string) => void): void;

	/** `meta(c, miumiu.collection, "StoreName")` names a DataStore. Declare it before `world()` (or with `world.set` before the first `step`). */
	export const collection: Entity<string>;
	/** `meta(c, miumiu.config, { ... })`; see `CollectionConfig`. */
	export const config: Entity<CollectionConfig>;
	/** Ordered, append-only list; the record stores how many ran. */
	export const migrations: Entity<Migration<any>[]>;
	/** `meta(c, miumiu.from_foreign, source)`: a key with no record yet is read once from another library's store; see `LapisSource`. */
	export const from_foreign: Entity<ForeignSource>;
	/** `meta(id, miumiu.saveable, "key")`: the stored key of a component or tag. Never changes once shipped. */
	export const saveable: Entity<string>;
	/** `meta(id, pair(miumiu.field_of, target))` scopes a saveable or a child kind to a collection's root or to another kind. With one collection a saveable without any `field_of` pair lives on its root and on no kind, a kind without any nests under the root and every kind; with pairs either lives exactly where they point. Once a world declares several collections every saveable and kind needs a pair, unless one collection sets `default_scope`. */
	export const field_of: Tag;
	/** `meta(component, miumiu.guard, check)`; see `Guard`. */
	export const guard: Entity<Guard>;
	/** `meta(component, miumiu.serdes, serdes)`; see `Serdes`. The `any` parameters are not tied to the component's type, so check the pairing yourself. */
	export const serdes: Entity<Serdes<any, any>>;
	/** `meta(component, miumiu.snapshot, fn)`; see `Snapshot`. */
	export const snapshot: Entity<Snapshot<any>>;
	/** `meta(component, miumiu.lazy)`: a saveable written often (every frame) that the library reads at write time instead of journaling per write. Writes update the entity as usual; the value is packed once per write cycle. Components only. */
	export const lazy: Tag;
	/** `meta(relation, miumiu.saveable, "key")` plus `meta(relation, miumiu.pairs)` (or `meta(relation, miumiu.pairs, { targets: [...] })` to store only those targets): the pairs `pair(relation, target)` on an entity are stored under `key` as a dictionary keyed by each target's `jecs.Name` (`true` for a tag relation, the pair value for a component one; a component pair without a value is not stored). A target's name is a stored key: keep it unique and stable. A target without a name or with a name another entity also carries is left out with a warning, a stored name no entity carries is skipped with a warning. Stored whole: no guard, serdes, snapshot, lazy or delta. */
	export const pairs: Entity<PairsConfig>;
	/** Declares a child kind on its tag; see `ChildConfig`. */
	export const child: Entity<ChildConfig>;
	/** The id an owned child is stored under; assigned by the library as soon as the entity carries both the kind tag and the pair, in either order, readable by the game. Nil until the first `step` on a child created before it. */
	export const child_id: Entity<string>;

	/** `world.set(e, pair(data_link, c), key)` links an entity to a key and starts the load; `world.remove` unlinks, the final write follows, and the `closed` hook reports it. */
	export const data_link: Entity<string>;
	/** `pair(data_loading, c)` while the first pull is in flight. Initial values are already on the entity. */
	export const data_loading: Tag;
	/** `pair(data_loaded, c)` once stored values are on the entity. Gate reads and writes on this. */
	export const data_loaded: Tag;
	/** Add `pair(data_shallow, c)` before linking to skip spawning the record's owned children for that entity (a gift link to another player). Writes under it still journal. */
	export const data_shallow: Tag;
	/** `pair(data_error, c) = message` when the load failed or the session closed, possibly on an entity that was loaded. The link stays. A failed load is retried by removing and re-setting the link; a session refused by a newer server means this server is outdated, so relinking fails again. */
	export const data_error: Entity<string>;
}

export = miumiu;
