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

export type DataStorePages = {
	IsFinished: boolean,
	GetCurrentPage: (self: DataStorePages) -> { { key: string, value: any } },
	AdvanceToNextPageAsync: (self: DataStorePages) -> (),
}

export type OrderedDataStore = {
	GetAsync: (self: OrderedDataStore, key: string) -> any,
	SetAsync: (self: OrderedDataStore, key: string, value: number) -> (),
	RemoveAsync: (self: OrderedDataStore, key: string) -> any,
	GetSortedAsync: (self: OrderedDataStore, ascending: boolean, page_size: number) -> DataStorePages,
}

export type DataStoreService = {
	GetDataStore: (self: DataStoreService, name: string) -> DataStore,
	GetOrderedDataStore: (self: DataStoreService, name: string) -> OrderedDataStore,
}

export type UpdateResult<T> = { kind: "written", value: T } | { kind: "unchanged", value: T? }

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
	format: number?,
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

export type Migrated =
	{ kind: "migrated", state: State }
	| { kind: "unchanged", state: State }
	| { kind: "newer", message: string }

export type Guard = (value: any) -> (boolean, string?)

export type Serdes = {
	serialize: (value: any) -> any,
	deserialize: (stored: any) -> any,
}

export type SyncKind = "batch" | "guard" | "serialize" | "deserialize" | "migration" | "snapshot" | "map" | "period"

export type Snapshot = (world: World, entity: Entity) -> any

export type Holders = { [Entity]: boolean }

export type Initial = { kind: "none" } | { kind: "value", value: any }

export type ComponentEntry = {
	kind: "component",
	id: Entity<any>,
	key: string,
	initial: Initial,
	guard: Guard?,
	serdes: Serdes?,
	snapshot: Snapshot?,
	lazy: boolean,
	holders: Holders,
}

export type TagEntry = {
	kind: "tag",
	id: Entity,
	key: string,
	initial: Initial,
	holders: Holders,
}

export type PairsConfig = {
	targets: { Entity }?,
}

export type RelationEntry = {
	kind: "relation",
	id: Entity<any>,
	key: string,
	initial: Initial,
	tagged: boolean,
	targets: { [Entity]: boolean }?,
	holders: Holders,
}

export type SchemaEntry = ComponentEntry | TagEntry | RelationEntry

export type Named = { [string]: Entity }

export type Warned = { [string]: boolean }

export type StoredChildren = {
	named: { [string]: Data },
	skipped: boolean,
}

export type Fields = {
	entries: { SchemaEntry },
	snapshots: { ComponentEntry },
	kinds: { ChildKind },
	ordered: { OrderedStore },
}

export type Period = { index: number, start: number, finish: number }

export type PeriodState = { kind: "none" } | { kind: "period", period: Period } | { kind: "failed" }

export type PeriodFunction = (now: number) -> Period

export type PeriodConfig = number | { length: number, epoch: number? } | PeriodFunction

export type ScoreMap = (stored: any) -> number?

export type OnPeriodChange = (world: World, entity: Entity, value: any, place: number, period: number) -> ()

export type OrderedConfig = {
	component: Entity<any>,
	period: PeriodConfig?,
	reset: boolean?,
	map: ScoreMap?,
	period_threshold: number?,
	poll_interval: number?,
	on_period_change: OnPeriodChange?,
}

export type OrderedStore = {
	entity: Entity,
	name: string,
	collection: Entity,
	entry: ComponentEntry,
	initial: any,
	initial_score: number?,
	period: PeriodFunction?,
	reset: boolean,
	map: ScoreMap,
	period_threshold: number,
	poll_interval: number,
	on_period_change: OnPeriodChange?,
	warned: Warned,
}

export type Push = { name: string, score: number? }

export type Owed = {
	from: number,
	last: number,
	values: { [string]: any },
	taken: string?,
	taken_at: number?,
}

export type Claim = { id: string, timeout: number, receiving: boolean }

export type OrderedRecord = { period: number?, pushed: number?, owed: Owed? }

export type Rolled = { state: State, ops: { Op }, pushes: { Push }, resets: { [string]: number } }

export type Periods = { [string]: number }

export type PeriodPlace = { period: number, value: any, place: number }

export type Placing = { store: OrderedStore, from: number, last: number, periods: { PeriodPlace } }

export type FailedChange = { from: number, last: number }

export type OrderedEntry = { key: string, score: number }

export type TopCache = { entries: { OrderedEntry }, complete: boolean }

export type TopOptions = { period: number?, ascending: boolean? }

export type Ordered = {
	get_name: (Ordered) -> string,
	get_period: (Ordered) -> Period?,
	get_top: (Ordered, count: number, options: TopOptions?) -> { OrderedEntry },
	get_score: (Ordered, key: string, period: number?) -> number?,
}

export type OrderedInternal = Ordered & {
	symbol: Symbol,
	internal_values: {
		store: OrderedStore,
		config: ResolvedCollectionConfig,
	},
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
		holders: Holders,
		entries: { SchemaEntry },
		snapshots: { ComponentEntry },
		kinds: { ChildKind },
		mode: "owned",
	}
	| {
		tag: Entity,
		via: Entity,
		key: string,
		holders: Holders,
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
	named: Named,
	ordered: { [Entity]: OrderedStore },
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

export type RelationWrite = {
	kind: "relation",
	entity: Entity,
	child: ChildKind,
	parent: Entity,
	trigger: Entity,
	change: "added" | "removed",
	deleted: boolean,
}

export type MarkWrite = {
	kind: "mark",
	entity: Entity,
	child: ChildKind,
	change: "added" | "removed",
}

export type Write = ComponentWrite | RelationWrite | MarkWrite

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

export type PendingDrop = {
	entity: Entity,
	ancestry: Ancestry,
	kept: boolean,
}

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

export type ErrorGuard = {
	run: (fn: () -> ()) -> (),
	rethrow: () -> (),
	get_error: () -> any,
}

export type Detached = {
	sessions: { SessionInternal },
	err: any,
}

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
	user_ids: ((key: string) -> { number })?,
}

export type CollectionState = {
	entity: Entity,
	config: ResolvedCollectionConfig,
	store: DataStore,
	ordered: { OrderedStore },
	holder: string,
}

export type Mutex = {
	close: (Mutex, reason: string) -> (),
	with: (Mutex, fn: () -> ()) -> (),
	is_locked: (Mutex) -> boolean,
}

export type MutexPhase = { kind: "free" } | { kind: "locked" } | { kind: "closed", reason: string }

export type MutexInternal = Mutex & {
	internal_values: {
		phase: MutexPhase,
	},
	internal_waiters: { thread },
	lock: (MutexInternal) -> (),
	unlock: (MutexInternal) -> (),
}

export type RefusedClosure = { kind: "refused", message: string }
export type Closure = { kind: "clean" } | RefusedClosure | { kind: "abandoned", message: string }
export type SessionStatus = { kind: "open" } | { kind: "closing" } | { kind: "closed", closure: Closure }

export type LandedHook = Symbol<"landed">
export type RefusedHook = Symbol<"refused">

export type SettledOutcome = { kind: "landed" } | { kind: "refused", message: string }
export type BatchKey = { collection: Entity, key: string }

export type Outcome = { kind: "pending" } | SettledOutcome

export type BatchHook =
	((Batch, LandedHook, callback: () -> ()) -> () -> ())
	& ((Batch, RefusedHook, callback: (message: string) -> ()) -> () -> ())

export type Batch = {
	get_outcome: (Batch) -> Outcome,
	get_result: (Batch) -> any,
	get_keys: (Batch) -> { BatchKey },
	is_settled: (Batch) -> boolean,
	hook: BatchHook,
	await: (Batch) -> SettledOutcome,
	silence: (Batch) -> (),
}

export type BatchPhase = { kind: "running" } | { kind: "held", result: any }

export type BatchInternal = Batch & {
	symbol: Symbol,
	internal_values: {
		outcome: Outcome,
		phase: BatchPhase,
		awaited: boolean,
		silenced: boolean,
		flush: (() -> ())?,
	},
	internal_hooks: CallbackRegistry,
	internal_waiters: { thread },
	internal_keys: { BatchKey },
	enter: (BatchInternal) -> (),
	hold: (BatchInternal, result: any, keys: { BatchKey }) -> (),
	land: (BatchInternal) -> (),
	refuse: (BatchInternal, id: string, message: string, heard: boolean) -> (),
	flush_with: (BatchInternal, flush: () -> ()) -> (),
}

export type Watcher = (outcome: SettledOutcome) -> ()

export type PulledHook = Symbol<"pulled">
export type ClosedHook = Symbol<"closed">
export type WritingHook = Symbol<"writing">

export type WorldHook = (world: World, hook: RefusedHook, callback: (batch: Batch, message: string) -> ()) -> () -> ()

export type SessionHook =
	((Session, PulledHook, callback: (truth: Data) -> ()) -> () -> ())
	& ((Session, ClosedHook, callback: (closure: Closure) -> ()) -> () -> ())
	& ((Session, WritingHook, callback: () -> ()) -> () -> ())

export type Session = {
	get_key: (Session) -> string,
	get_truth: (Session) -> Data,
	get_stamps: (Session) -> Stamps,
	get_config: (Session) -> ResolvedCollectionConfig,
	get_status: (Session) -> SessionStatus,
	is_open: (Session) -> boolean,
	is_dirty: (Session) -> boolean,
	sync: (Session) -> boolean,
	hook: SessionHook,
}

export type Merge =
	{ kind: "newer", message: string, groups: { Group }, resolution: Resolution }
	| { kind: "unchanged", groups: { Group }, resolution: Resolution }
	| {
		kind: "merged",
		record: StoredRecord,
		groups: { Group },
		resolution: Resolution,
		pushes: { Push },
		resets: { [string]: number },
	}

export type Pull = {
	merge: Merge,
	record: StoredRecord?,
	wrote: boolean,
	pushes: { [string]: Push },
}

export type SessionInternal = Session & {
	get_collection: (SessionInternal) -> Entity,
	symbol: Symbol,
	internal_values: {
		key: string,
		status: SessionStatus,
		adopted: boolean,
		version: number,
		written: string?,
		pulls: number,
		touched: boolean,
		prepare: (() -> ())?,
		push_failing: boolean,
		top_failing: boolean,
	},
	internal_collection: CollectionState,
	internal_receiving: () -> boolean,
	internal_pushes: { [string]: Push },
	internal_resets: { [string]: number },
	internal_placings: { [string]: Placing },
	internal_failed_changes: { [string]: FailedChange },
	internal_base: State,
	internal_migrate: Migrate,
	internal_seed: Data?,
	internal_hooks: CallbackRegistry,
	internal_mutex: Mutex,
	internal_unwritten: { Group },
	internal_awaiting: { Group },
	internal_watchers: { [string]: Watcher },
	internal_landed: { string },
	internal_cache: State?,
	internal_before_last: State?,

	get_state: (SessionInternal) -> State,
	get_pulls: (SessionInternal) -> number,
	wipe: (SessionInternal) -> (),
	reopen: (SessionInternal) -> (),
	prepare_with: (SessionInternal, fn: (() -> ())?) -> (),
	journal: (SessionInternal, group: Group) -> (),
	watch: (SessionInternal, id: string, watcher: Watcher) -> (),
	touch: (SessionInternal) -> (),
	drop_group: (SessionInternal, id: string) -> (),
	resolve_group: (SessionInternal, id: string, message: string) -> SettledOutcome,
	unload: (SessionInternal, retry: RetryConfig?) -> (),
	discard: (SessionInternal, message: string) -> (),
	get_placings: (SessionInternal) -> { [string]: Placing },
	forget_placing: (SessionInternal, name: string, placing: Placing, failed: boolean) -> (),
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

export type DropReason = { kind: "failed", message: string } | { kind: "unloaded" } | { kind: "closed", closure: Closure }

export type Event =
	{ kind: "link", entity: Entity, collection: Entity, key: string }
	| { kind: "unlink", entity: Entity, collection: Entity }
	| { kind: "loaded", link: LinkState, session: SessionInternal }
	| { kind: "load_failed", link: LinkState, err: string }
	| { kind: "pulled", link: LinkState }
	| { kind: "closed", link: LinkState, session: SessionInternal }

export type ChildUndo = {
	kind: "child",
	entity: Entity,
	child: ChildKind,
	previous: Data,
	value: Data,
	carried: boolean,
}

export type Undo = { kind: "tag", entity: Entity, id: Entity, key: string, present: boolean, carried: boolean } | {
	kind: "component",
	entity: Entity,
	entry: SchemaEntry,
	previous: any,
	value: any,
	carried: boolean,
} | {
	kind: "relation",
	entity: Entity,
	entry: RelationEntry,
	previous: Data?,
	value: Data?,
	carried: boolean,
} | ChildUndo | {
	kind: "pair",
	entity: Entity,
	id: Entity,
	present: boolean,
	child: ChildKind,
	parent: Entity,
	stored_id: any,
} | { kind: "mark", entity: Entity, id: Entity, present: boolean }

export type Touched = { [Entity]: { [string]: boolean } }

export type CaptureEntry = {
	session: SessionInternal,
	ops: { Op },
	coalesced: { [string]: number },
}

export type Capture = {
	id: string,
	delta: boolean,
	undo: { Undo },
	entries: { CaptureEntry },
	children: { [Entity]: ChildUndo },
	batch: BatchInternal,
}

export type Applying = { kind: "entity", entity: Entity } | { kind: "field", entity: Entity, id: Entity<any> }

export type EntityState = {
	shadow: Data,
	supplied: { [string]: any },
	tree: Data?,
	baseline: Data,
	lazy: { [string]: boolean },
	removing: { [string]: Removal },
	dropped: boolean,
}

export type WorldPhase = { kind: "idle" } | { kind: "stepping" } | { kind: "closed" }

export type WorldState = {
	collections: { [Entity]: CollectionState },
	schema: Schema?,
	disconnects: { () -> () },
	phase: WorldPhase,
	closing: { thread }?,
	applying: Applying?,
	capture: Capture?,
	entities: { [Entity]: EntityState },
	children: ChildIndex,
	deleting: { [Entity]: boolean },
	cleanups: { Cleanup },
	pending_drops: { [Entity]: { PendingDrop } },
	pending_puts: { [Entity]: boolean },
	pending_root_puts: { [Entity]: { [string]: { Op } } },
	dropped_entities: { Entity },
	captures: { Capture },
	hooks: CallbackRegistry,
	warned: Warned,
	links: { [Entity]: { [Entity]: string } },
	link_states: { [Entity]: { [string]: LinkState } },
	orphans: { [SessionInternal]: () -> () },
	pending_loads: { [Entity]: { [string]: number } },
	load_waiters: { [thread]: () -> () },
	events: { Event },
	ordered: { [Entity]: OrderedInternal },
}

export type Context = {
	world: World,
	world_state: WorldState,
	schema: Schema,
}

export type MigrationScratch = {
	world: World,
	entity: Entity,
	kinds: { ChildKind },
	sink: RecorderSink,
	children: ChildIndex,
	named: Named,
	warned: Warned,
	recording: boolean,
	ops: { Op },
	touched: { [string]: TouchedChild },
}

return nil
