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
		/** The record-format version this build writes (1). A record in a higher format closes the session, like a newer migration count. */
		format?: number;
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

	/** `meta(collection, miumiu.config, { ... })`; every field optional. `pull_interval` (default 15) is how often a session with unwritten changes writes and how long an unawaited single-key batch stays pending, warned under 6 s (the DataStore write cooldown); `idle_interval` (default 60, never under `pull_interval`) is how often a clean session reads for changes from elsewhere, `math.huge` turns idle reads off; `pull_interval = math.huge` runs no loop at all (only `sync`, `await`, unlink and `close` write). `retry_attempts` (5) and `retry_base` (1 s, doubling) shape storage retries; `commit_store` ("miumiu_commits") and `commit_timeout` (300 s) drive multi-key batches. `user_ids(key)` returns the user ids to attach to every write and wipe of that key (GDPR association). Config is validated at link time: a bad value does not throw at `meta`, it lands as `pair(data_error, collection)` on every entity that links. */
	export interface CollectionConfig {
		data_store_service?: Pick<DataStoreService, "GetDataStore"> & Partial<Pick<DataStoreService, "GetOrderedDataStore">>;
		pull_interval?: number;
		idle_interval?: number;
		retry_attempts?: number;
		retry_base?: number;
		commit_store?: string;
		commit_timeout?: number;
		user_ids?: (key: string) => number[];
	}

	/** What `Session.get_config()` returns: the config with defaults filled in, plus the collection's name, migrations and foreign source. */
	export interface ResolvedCollectionConfig {
		name: string;
		data_store_service: Pick<DataStoreService, "GetDataStore"> & Partial<Pick<DataStoreService, "GetOrderedDataStore">>;
		pull_interval: number;
		idle_interval: number;
		retry_attempts: number;
		retry_base: number;
		commit_store: string;
		commit_timeout: number;
		migrations: Migration<any>[];
		foreign?: ForeignSource;
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

	/** `meta(kind_tag, miumiu.child, config)`: entities carrying `kind_tag` and `pair(via, parent)` are stored under `key` on the parent, with the saveables that are `field_of` the kind and the kinds that are `field_of` it. The kind tag itself needs at least one `pair(field_of, collection or kind)` saying where it nests. `via` must be marked `Exclusive`, and an entity is a child under one relation at a time. Owned children live and die with the record and get their id in `child_id`; attached ones outlive it, keep their state in the record and are named by the value of `id`. */
	export type ChildConfig =
		| { via: Entity; key: string; mode: "owned" }
		| { via: Entity; key: string; mode: "attached"; id: Entity<string | number> };

	/** `meta(component, miumiu.serdes, { serialize, deserialize })` for values a DataStore cannot hold: `Set<number>`, `Map<number, T>`, userdata. String-keyed `Set<string>` and `Map<string, T>` are plain tables already and need none. Must not yield. */
	export interface Serdes<T = unknown, S = unknown> {
		serialize: (value: T) => S;
		deserialize: (stored: S) => T;
	}

	/** One period of a periodic ordered store: `index` names its store (`name_index`) and is what `get_top`, `get_score` and `on_period_change` take; `start` and `finish` bound it, and `finish` is the next reset. */
	export interface Period {
		index: number;
		start: number;
		finish: number;
	}

	/** `period` of an ordered store: a length in seconds (counted from the Unix epoch, so a week rolls over Thursday 00:00 UTC), `{ length, epoch }` to align it, or a function of now returning the `Period`; the index must never decrease as now grows. */
	export type PeriodConfig = number | { length: number; epoch?: number } | ((now: number) => Period);

	/** `map` of an ordered store: the integer the OrderedDataStore holds for the field's stored form, or `undefined` to leave the key unranked. The default floors a number and leaves anything else unranked. A negative or non-finite result is unranked with a warning. Must not yield. */
	export type Map<S = unknown> = (stored: S) => number | undefined;

	/** `on_period_change` of an ordered store: runs once per key and finished period on the key's next load, on its loaded entity, inside a batch with the library's own claim, so the writes it makes (a reward) land with the claim or not at all; a throw is warned and it runs again on the next load. `value` is the field's final stored value for that period, `place` its rank among the top `period_threshold` or `undefined` beyond them, `period` the finished period's index. Must not yield. The library knows entities, not players: map the entity back to its `Player` yourself. */
	export type OnPeriodChange<S = unknown> = (world: World, entity: Entity, value: S, place: number | undefined, period: number) => void;

	/** `meta(entity, miumiu.ordered, config)` plus `meta(entity, pair(miumiu.field_of, collection))`: the entity's `Name` (at most 40 characters, and its period suffix must fit the 50-character DataStore limit) names the OrderedDataStore that ranks `component`, a root field of that collection, by `map` of its stored form. With `period` the store is per period (`name_index`) and the field resets to its initial when a record crosses into a new one, unless `reset` is `false`; `period_threshold` (default 10) is how many ranks `on_period_change` resolves and `poll_interval` (default 60) how many seconds after a period's end its final ranking is read. `S` is the field's stored form. */
	export interface OrderedConfig<S = unknown> {
		component: Entity<any>;
		period?: PeriodConfig;
		/** Needs `period`; defaults to `true`. `false` keeps the field across a crossing, so each period's ranking holds the value as it stands (a monthly board of a lifetime total) instead of what was earned inside that period; such a store may share its field with other ordered stores, since it resets nothing. */
		reset?: boolean;
		map?: Map<S>;
		period_threshold?: number;
		poll_interval?: number;
		on_period_change?: OnPeriodChange<S>;
	}

	/** One ranked key. */
	export interface OrderedEntry {
		key: string;
		score: number;
	}

	/** Options of `Ordered.get_top`: `period` picks a period's store by index (default the current one; not allowed on an all-time store), `ascending` reads lowest first. */
	export interface TopOptions {
		period?: number;
		ascending?: boolean;
	}

	/** The handle `get_ordered` returns: reads only, the sessions push scores. */
	export interface Ordered {
		/** The store's name, its entity's `Name`. */
		get_name(): string;
		/** The current period, without a request, or `undefined` for an all-time store. */
		get_period(): Period | undefined;
		/** The top `count` entries in rank order. Yields: one `GetSortedAsync` per hundred entries; a finished period's ranking is served from the cache once read. */
		get_top(count: number, options?: TopOptions): OrderedEntry[];
		/** The score stored for `key`, or `undefined` when it is not ranked. Yields, one `GetAsync`. */
		get_score(key: string, period?: number): number | undefined;
	}

	/** A typed hook symbol; `Args` is what the callback receives. */
	export interface Hook<Args extends unknown[], Name extends string = string> {
		readonly __hook: Args;
		readonly __name: Name;
	}
	/** Fires after a pull adopted something new, with the merged truth in stored form. Runs on the pull thread after the session's lock is released: the entities are updated on the next `step`, so read `truth`, not the world. The one hook that may `sync` again. */
	export type PulledHook = Hook<[truth: Data], "pulled">;
	/** Fires once when the session closes, with why: final write done, a newer server took the key, or `close` ran out of budget; the latter two refuse every riding batch not already carried by a write in flight. */
	export type ClosedHook = Hook<[closure: Closure], "closed">;
	/** What `Session.get_status()` returns. */
	export type SessionStatus = { kind: "open" } | { kind: "closing" } | { kind: "closed"; closure: Closure };
	/** Fires right before the session writes, while its entities are still linked. Snapshots and lazy flushes have already run: a plain write from the callback joins this write, a lazy one the next. Never yield or `sync` in it. */
	export type WritingHook = Hook<[], "writing">;
	/** Fires once a batch's group is in every record it touched. Connecting after that fires at once. */
	export type LandedHook = Hook<[], "landed">;
	/** Fires once the batch is refused (a newer server took the key, `close` gave up, `wipe`, an `await`'s write failed after its retries, a multi-key commit failed): the group was dropped from every session and the world rolled back (only values the batch still held). Connecting after that fires at once. A write made in the callback is an ordinary journaled write, except when the refusal closed the session: the key no longer saves. */
	export type RefusedHook = Hook<[message: string], "refused">;

	/** A batch that is no longer pending: `landed`, or `refused` with the message. */
	export type SettledOutcome = { kind: "landed" } | { kind: "refused"; message: string };
	/** Where a batch stands: `pending` until it settles, then `landed` or `refused`. */
	export type Outcome = { kind: "pending" } | SettledOutcome;

	/** The handle `batch` and `delta` return. A group on one key rides the session's next write and `await` writes it now; a group over several keys commits in the background. Hook or await it. `T` is what the function returned. */
	export interface Batch<T = void> {
		/** `pending`, `landed` or `refused`. */
		get_outcome(): Outcome;
		/** What the function returned, available as soon as `batch` returns. A nested call returns the outer handle, so it reports the outer function's result. `undefined` for a batch refused on a closed world, whose function never ran. */
		get_result(): T;
		/** The stored keys the batch touched, in the order they were first written; empty for a batch that captured nothing. Available as soon as `batch` returns. */
		get_keys(): readonly string[];
		/** True once landed or refused. */
		is_settled(): boolean;
		/** Connect to `landed` or `refused`; fires at once if already settled. Returns a disconnect. Callbacks are pcalled and a throw is warned, never raised. */
		hook<H extends LandedHook | RefusedHook>(hook: H, callback: (...args: H["__hook"]) => void): () => void;
		/** Writes a single-key batch now, then yields until settled and returns the outcome (`landed`, or `refused` with the message); never throws, except when called inside the batch's own function. The result is the decision: branch on it, never discard it. The durability point for receipts. A refusal warns when nothing hooked `refused` or awaited the batch in the same frame. */
		await(): SettledOutcome;
	}

	/** Why a session closed: `clean` after its final write; `refused` when a newer server took the key; `abandoned` when `close` gave up on the final write. Both latter kinds lost the unwritten changes and refused every riding batch not already carried by a write in flight. */
	export type Closure = { kind: "clean" } | { kind: "refused"; message: string } | { kind: "abandoned"; message: string };

	/** The hook symbols `Session.hook` (`pulled`, `closed`, `writing`), `Batch.hook` (`landed`, `refused`) and the world-level `hook` (`refused`) take. */
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
		get_truth(): Readonly<Data>;
		/** Stamps of the merged truth: per key for `set`/`remove`, per `key/path` for child puts. Read-only. */
		get_stamps(): Readonly<Stamps>;
		/** The collection's resolved config, shared with the session: read-only. */
		get_config(): Readonly<ResolvedCollectionConfig>;
		/** `open`, `closing` while the final write of an unlink runs, or `closed` with why. */
		get_status(): SessionStatus;
		/** False once the session closed for any reason. */
		is_open(): boolean;
		/** True while ops are journaled but not yet written, including while a write is in flight. */
		is_dirty(): boolean;
		/** Rebase unwritten changes onto the live record and write them now instead of waiting for `pull_interval`. Yields; returns only once every change journaled before the call is in the record, and throws otherwise (write failed after its retries, session refused or closed). The boolean says whether something new from elsewhere was adopted, not whether the write happened. The durability point for a plain write; receipts await a `batch`. Lands every single-key batch journaled before the call and fires its hooks here; a refusal inside (newer server, closed) refuses them, a failed write leaves them pending. */
		sync(): boolean;
		/** Connect to `pulled`, `closed` or `writing`; returns a disconnect. Callbacks are pcalled and a throw is warned, never raised. */
		hook<H extends PulledHook | ClosedHook | WritingHook>(hook: H, callback: (...args: H["__hook"]) => void): () => void;
	}

	/** Drain queued link/unlink/load/pull events into the world. Call every Heartbeat. No-op after `close`. Unlink, then `step`, then delete the entity: a root deleted while linked keeps its record, and its owned children are deleted with it on the next `step`. */
	export function step(world: World): void;
	/** Unload every session and stop stepping. The first thing it does is detach every link, so write leave-time state before calling it or in a `writing` hook; a saveable write made after it began is dropped. Yields until every final write lands or `budget` seconds (default 25) pass. Call from `BindToClose`. */
	export function close(world: World, budget?: number): void;
	/** The open session behind `pair(data_link, collection) = key`, or undefined while loading, failed, unlinked or writing its final record after an unlink. `collection` is the collection tag. */
	export function get_session(world: World, collection: Entity, key: string): Session | undefined;
	/** Erase a key in one write: a fresh empty record, every stored key stamped past its old stamp. A loaded key also drops its unwritten changes and lazy marks, refuses every single-key batch still riding it (their hooks fire inside the call), puts initials back on every linked entity, deletes its owned children and resets attached ones; a key nobody here holds is wiped straight in the store. Yields; throws if the write fails, keeping everything. A multi-key batch mid-commit on the key is not refused: its pending entry goes with the record while its other keys may still land it. */
	export function wipe(world: World, collection: Entity, key: string): void;
	/** Every write inside lands as one group, on every key it touches, or none. Runs `fn` now, journals the group and returns without yielding; on one key the group rides the session's next write (`await` writes it now, for receipts), across keys it commits in the background, and the returned `Batch` reports it. A write `fn` cannot make (guard, unloaded entity, `fn` throwing) or keys on collections with different commit stores throw here and roll the world back at once; a commit refused later rolls back only the values the batch still holds and fires `refused`. A nested call joins the outer batch and returns the outer handle. A batch that captured no saveable write lands at once; snapshots are evaluated at write time outside any batch. */
	export function batch<T = void>(world: World, fn: () => T): Batch<T>;
	/** Like `batch`, but each `set` on a root saveable is diffed against the previous value into `add`/`insert`/`erase`/`put`/`drop`. Build new values from the old ones. A write inside a child is a whole put, never a diff. */
	export function delta<T = void>(world: World, fn: () => T): Batch<T>;
	/** True for a `Session` returned by `get_session`. */
	export function is_session(value: unknown): value is Session;
	/** Connect a world-level `refused` listener: fires for every batch on this world that is refused, after the batch's own hooks, with the handle and the message. Returns a disconnect. One listener here silences the unhooked-refusal warning for every batch. */
	export function hook(world: World, hook: RefusedHook, callback: (batch: Batch<unknown>, message: string) => void): () => void;
	/** True for a `Batch` returned by `batch` or `delta`. */
	export function is_batch(value: unknown): value is Batch<unknown>;
	/** The `Ordered` handle behind `meta(entity, miumiu.ordered, config)`, one per world and entity; builds the schema on first use. Throws for an entity without the meta and for a collection whose config or `data_store_service` (no `GetOrderedDataStore`) is bad. */
	export function get_ordered(world: World, entity: Entity): Ordered;
	/** True for an `Ordered` returned by `get_ordered`. */
	export function is_ordered(value: unknown): value is Ordered;
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
	/** `meta(id, pair(miumiu.field_of, target))` scopes a saveable or a child kind to a collection's root or to another kind. Every saveable and every kind needs at least one pair and lives exactly where its pairs point; one without any fails the schema build. */
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
	/** The id an owned child is stored under; assigned by the library as soon as the entity carries both the kind tag and the pair, in either order, readable by the game. `undefined` until the first `step` on a child created before it. */
	export const child_id: Entity<string>;
	/** Declares an OrderedDataStore ranking one root field of a collection; see `OrderedConfig`. Read it through `get_ordered`. */
	export const ordered: Entity<OrderedConfig<any>>;

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
