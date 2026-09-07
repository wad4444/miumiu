local jecs = require("./dependencies/jecs")

export type World = typeof(jecs.world())
export type Entity<T = nil> = { __T: T }

export type Callback = (...any) -> ...any
export type Symbol<T = any> = { __do_not_use_this_or_you_will_be_fired: never, __name: T }
export type CallbackRegistry = { [Symbol]: { Callback } }

export type DataStoreGetOptions = { UseCache: boolean }

export type DataStore = {
	GetAsync: (self: DataStore, key: string, options: DataStoreGetOptions?) -> any,
	SetAsync: (self: DataStore, key: string, value: any, user_ids: { number }?) -> (),
	UpdateAsync: (self: DataStore, key: string, transform: (old: any) -> (any, { number }?)) -> any,
}

export type DataStoreService = {
	GetDataStore: (self: DataStoreService, name: string) -> DataStore,
}

export type UpdateResult<T> = {
	value: T?,
	written: boolean,
}

export type Data = { [string]: any }

export type Op =
	{ kind: "set", key: string, value: any, at: number }
	| { kind: "remove", key: string, at: number }
	| { kind: "init", key: string, value: any }
	| { kind: "add", key: string, delta: number }
	| { kind: "insert", key: string, value: any }
	| { kind: "erase", key: string, value: any }
	| { kind: "put", key: string, path: { string }, value: any, at: number }
	| { kind: "drop", key: string, path: { string }, at: number }

export type Stamps = { [string]: number }

export type State = {
	truth: Data,
	stamps: Stamps,
}

export type GroupKind = "single" | "shared"

export type Group = {
	id: string,
	ops: { Op },
	kind: GroupKind,
	coalesce: string?,
}

export type PendingEntry = {
	created: number,
	ops: { Op },
}

export type Pending = { [string]: PendingEntry }

export type Landed = { [string]: number }

export type StoredRecord = {
	data: Data?,
	stamps: Stamps?,
	pending: Pending?,
	landed: Landed?,
	version: number?,
	written: string?,
	migrations: number?,
}

export type CommitStatus = "committed" | "failed" | "undecided" | "unknown"

export type CommitKnown = {
	committed: boolean,
	at: number,
}

export type Resolution = {
	truth: Data,
	stamps: Stamps,
	pending: Pending,
	unknown: { string },
	decided: { string },
}

export type Landing = {
	state: State,
	pending: Pending,
	landed: Landed,
}

export type MigrationContext = {
	key: string,
	legacy: (stored_key: string) -> Entity<any>,
	stored: Data,
}

export type Migration = (world: World, entity: Entity, context: MigrationContext) -> ()
export type Migrate = (truth: Data, applied: number) -> Data

export type Migrated = { kind: "state", state: State, migrated: boolean } | { kind: "newer", message: string }

export type Guard = (value: any) -> (boolean, string?)

export type Serdes = {
	serialize: (value: any) -> any,
	deserialize: (stored: any) -> any,
}

export type SyncKind = "guard" | "serialize" | "deserialize" | "migration" | "snapshot"

export type Snapshot = (world: World, entity: Entity) -> any

export type Scopes = {
	unscoped: boolean,
	targets: { [Entity]: boolean },
}

export type ComponentEntry = {
	kind: "component",
	id: Entity<any>,
	key: string,
	has_initial: boolean,
	initial: any,
	guard: Guard?,
	serdes: Serdes?,
	snapshot: Snapshot?,
	lazy: boolean,
	scopes: Scopes,
}

export type TagEntry = {
	kind: "tag",
	id: Entity,
	key: string,
	has_initial: boolean,
	scopes: Scopes,
}

export type PairsConfig = {
	targets: { Entity }?,
}

export type RelationEntry = {
	kind: "relation",
	id: Entity<any>,
	key: string,
	has_initial: false,
	tagged: boolean,
	targets: { [Entity]: boolean }?,
	scopes: Scopes,
}

export type SchemaEntry = ComponentEntry | TagEntry | RelationEntry

export type Named = { [string]: Entity }

export type Warned = { [string]: boolean }

export type Fields = {
	entries: { SchemaEntry },
	snapshots: { ComponentEntry },
	kinds: { ChildKind },
}

export type ChildMode = "owned" | "attached"

export type ChildConfig =
	{ via: Entity, key: string, mode: "owned" }
	| { via: Entity, key: string, mode: "attached", id: Entity<any> }

export type ChildKind =
	{
		tag: Entity,
		via: Entity,
		key: string,
		scopes: Scopes,
		entries: { SchemaEntry },
		snapshots: { ComponentEntry },
		kinds: { ChildKind },
		mode: "owned",
	}
	| {
		tag: Entity,
		via: Entity,
		key: string,
		scopes: Scopes,
		entries: { SchemaEntry },
		snapshots: { ComponentEntry },
		kinds: { ChildKind },
		mode: "attached",
		id: Entity<any>,
	}

export type Schema = {
	entries: { SchemaEntry },
	by_key: { [string]: SchemaEntry },
	kinds: { ChildKind },
	kinds_by_relation: { [Entity]: { ChildKind } },
	roots: { [Entity]: Fields },
	default_root: Entity?,
	named: Named,
}

export type Change = "added" | "changed" | "removed"

export type ComponentWrite = {
	kind: "component",
	entity: Entity,
	entry: SchemaEntry,
	change: Change,
	value: any,
	deleted: boolean,
}

export type Removal = { kind: "field" } | { kind: "targets", targets: { [Entity]: boolean } }

export type ErrorGuard = {
	run: (fn: () -> ()) -> (),
	rethrow: () -> (),
	get_error: () -> any,
}

export type Detached = {
	sessions: { SessionInternal },
	err: any,
}

export type RelationWrite = {
	kind: "relation",
	entity: Entity,
	child: ChildKind,
	parent: Entity,
	trigger: Entity,
	change: "added" | "removed",
	deleted: boolean,
}

export type Write = ComponentWrite | RelationWrite

export type ChildRecord = {
	kind: ChildKind,
	parent: Entity,
	id: string,
}

export type ChildIndex = {
	by_entity: { [Entity]: ChildRecord },
	by_parent: { [Entity]: { [string]: { [string]: Entity } } },
}

export type Ancestry = {
	root: Entity,
	path: { string },
	kind: ChildKind,
}

export type Held =
	{ kind: "root", sessions: { SessionInternal } }
	| { kind: "child", sessions: { SessionInternal }, ancestry: Ancestry }

export type Owner = Held | { kind: "unsaved" }

export type SplitPath = {
	key: string,
	path: { string },
}

export type GuardResult = { kind: "ok" } | { kind: "rejected", reason: string? }

export type Cleanup = { kind: "delete", entity: Entity } | { kind: "reset", entity: Entity, child: ChildKind }

export type TouchedChild = {
	key: string,
	id: string,
}

export type ExistingChild = {
	kind: ChildKind,
	entity: Entity,
	parent: Entity,
}

export type UnloadAttempt = { kind: "done" } | { kind: "failed", reason: string }

export type RecorderSink = (write: Write) -> ()

export type Decoded = { kind: "ok", value: any } | { kind: "rejected" }

export type RetryConfig = {
	retry_attempts: number,
	retry_base: number,
}

export type LapisCollection = {
	read: (self: LapisCollection, key: string) -> { expect: (self: any) -> any },
}

export type LapisLibrary = {
	createCollection: (name: string, options: any) -> LapisCollection,
}

export type LapisSource = {
	type: "lapis",
	name: string,
	source: LapisLibrary,
	options: any,
}

export type ForeignSource = LapisSource

export type CollectionConfig = {
	data_store_service: DataStoreService?,
	pull_interval: number?,
	idle_interval: number?,
	retry_attempts: number?,
	retry_base: number?,
	commit_store: string?,
	commit_timeout: number?,
	default_scope: boolean?,
	user_ids: ((key: string) -> { number })?,
}

export type ResolvedCollectionConfig = {
	name: string,
	data_store_service: DataStoreService,
	pull_interval: number,
	idle_interval: number,
	retry_attempts: number,
	retry_base: number,
	commit_store: string,
	commit_timeout: number,
	migrations: { Migration },
	foreign: ForeignSource?,
	default_scope: boolean,
	user_ids: ((key: string) -> { number })?,
}

export type CollectionState = {
	config: ResolvedCollectionConfig,
	store: DataStore,
}

export type Mutex = {
	lock: (Mutex) -> (),
	unlock: (Mutex) -> (),
	close: (Mutex, reason: string) -> (),
	with: (Mutex, fn: () -> ()) -> (),
}

export type MutexInternal = Mutex & {
	symbol: Symbol,
	internal_values: {
		locked: boolean,
		closed: string?,
	},
	internal_waiters: { thread },
}

export type RefusedClosure = { kind: "refused", message: string }
export type Closure = { kind: "clean" } | RefusedClosure | { kind: "abandoned", message: string }

export type LandedHook = Symbol<"landed">
export type RefusedHook = Symbol<"refused">

export type Outcome = { kind: "pending" } | { kind: "landed" } | { kind: "refused", message: string }

export type BatchHook =
	((Batch, LandedHook, callback: () -> ()) -> () -> ())
	& ((Batch, RefusedHook, callback: (message: string) -> ()) -> () -> ())

export type Batch = {
	get_outcome: (Batch) -> Outcome,
	is_settled: (Batch) -> boolean,
	hook: BatchHook,
	await: (Batch) -> (),
}

export type BatchInternal = Batch & {
	symbol: Symbol,
	internal_values: {
		outcome: Outcome,
	},
	internal_hooks: CallbackRegistry,
	internal_waiters: { thread },
	land: (BatchInternal) -> (),
	refuse: (BatchInternal, id: string, keys: { string }, message: string) -> (),
}

export type PulledHook = Symbol<"pulled">
export type ClosedHook = Symbol<"closed">
export type WritingHook = Symbol<"writing">

export type SessionHook =
	((Session, PulledHook, callback: (truth: Data) -> ()) -> () -> ())
	& ((Session, ClosedHook, callback: (closure: Closure) -> ()) -> () -> ())
	& ((Session, WritingHook, callback: () -> ()) -> () -> ())

export type Session = {
	get_key: (Session) -> string,
	get_truth: (Session) -> Data,
	get_stamps: (Session) -> Stamps,
	get_config: (Session) -> ResolvedCollectionConfig,
	get_closure: (Session) -> Closure?,
	is_open: (Session) -> boolean,
	is_dirty: (Session) -> boolean,
	sync: (Session) -> boolean,
	hook: SessionHook,
}

export type Merge =
	{ kind: "newer", message: string, groups: { Group }, resolution: Resolution }
	| { kind: "unchanged", groups: { Group }, resolution: Resolution }
	| { kind: "merged", record: StoredRecord, groups: { Group }, resolution: Resolution }

export type MergedPull = {
	kind: "merged",
	record: StoredRecord?,
	groups: { Group },
	resolution: Resolution,
	written: boolean,
}

export type PullResult =
	{ kind: "newer", message: string, groups: { Group }, resolution: Resolution, written: boolean }
	| MergedPull

export type SessionInternal = Session & {
	symbol: Symbol,
	internal_values: {
		key: string,
		open: boolean,
		closing: boolean,
		closure: Closure?,
		version: number,
		written: string?,
		pulls: number,
		touched: boolean,
	},
	internal_collection: CollectionState,
	internal_base: State,
	internal_migrate: Migrate,
	internal_seed: Data?,
	internal_hooks: CallbackRegistry,
	internal_mutex: Mutex,
	internal_unwritten: { Group },
	internal_awaiting: { Group },
	internal_cache: State?,
	internal_before_last: State?,

	get_state: (SessionInternal) -> State,
	get_pulls: (SessionInternal) -> number,
	wipe: (SessionInternal) -> (),
	reopen: (SessionInternal) -> (),
	journal: (SessionInternal, group: Group) -> (),
	touch: (SessionInternal) -> (),
	abandon: (SessionInternal, id: string) -> (),
	has_landed: (SessionInternal, id: string) -> boolean,
	unload: (SessionInternal, retry: RetryConfig?) -> (),
	discard: (SessionInternal, message: string) -> (),
}

export type LinkPhase =
	{ kind: "loading", thread: thread }
	| { kind: "loaded", session: SessionInternal, disconnect: () -> () }
	| { kind: "unloading", session: SessionInternal, disconnect: () -> () }

export type LinkState = {
	collection: Entity,
	key: string,
	entities: { [Entity]: boolean },
	phase: LinkPhase,
}

export type LinkStatus = "loading" | "loaded" | "none"

export type Event =
	{ kind: "link", entity: Entity, collection: Entity, key: string }
	| { kind: "unlink", entity: Entity, collection: Entity }
	| { kind: "loaded", link: LinkState, session: SessionInternal }
	| { kind: "load_failed", link: LinkState, err: string }
	| { kind: "pulled", link: LinkState }
	| { kind: "closed", link: LinkState, session: SessionInternal }

export type Undo =
	{ kind: "tag", entity: Entity, id: Entity, present: boolean }
	| { kind: "component", entity: Entity, id: Entity<any>, previous: any, value: any }
	| { kind: "pair", entity: Entity, id: Entity, present: boolean }
	| { kind: "relation", entity: Entity, entry: RelationEntry, previous: Data?, value: Data? }
	| { kind: "child", entity: Entity, child: ChildKind, previous: Data, value: Data? }

export type CaptureEntry = {
	session: SessionInternal,
	ops: { Op },
	coalesced: { [string]: number },
}

export type Capture = {
	delta: boolean,
	undo: { Undo },
	entries: { CaptureEntry },
	children: { [Entity]: boolean },
	batch: BatchInternal,
}

export type Applying = {
	entity: Entity,
	id: Entity<any>?,
}

export type EntityState = {
	shadow: { [string]: any },
	supplied: { [string]: any },
	tree: Data?,
	baseline: Data,
	lazy: { [string]: boolean },
	removing: { [string]: Removal },
	dropped: boolean,
}

export type WorldState = {
	collections: { [Entity]: CollectionState },
	schema: Schema?,
	disconnects: { () -> () },
	closed: boolean,
	stepping: boolean,
	applying: Applying?,
	capture: Capture?,
	entities: { [Entity]: EntityState },
	children: ChildIndex,
	deleting: { [Entity]: boolean },
	cleanups: { Cleanup },
	warned: Warned,
	links: { [Entity]: { [Entity]: string } },
	link_states: { [Entity]: { [string]: LinkState } },
	orphans: { [SessionInternal]: () -> () },
	events: { Event },
}

export type Context = {
	world: World,
	world_state: WorldState,
	schema: Schema,
}

export type MigrationScratch = {
	world: World,
	entity: Entity,
	sink: RecorderSink,
	children: ChildIndex,
	named: Named,
	warned: Warned,
	recording: boolean,
	ops: { Op },
	touched: { [string]: TouchedChild },
}

return nil
