--!strict

-- Shared type definitions for the world (init.luau) and the query engine
-- (engine.luau). Both modules alias what they need from here.

export type u24 = number
export type u53 = number
export type ArchetypeId = number
export type Bitset = number
export type Column = Array<any>
export type Cleanup = () -> ()

export type Map<T, V> = { [T]: V }
export type Array<T> = { T }

export type Entity<T = any> = { __T: T }
export type Component<T = any> = { __T: T }
export type Id<T = any> = { __T: T }
export type Pair<R, T> = Id<R>

export type ArchetypeChangedHook = (source: Archetype, destination: Archetype) -> ()

export type SetHook<T = any> = (entity: Entity, id: Id<T>, value: T) -> ()
export type RemovedHook<T = any> = ((entity: Entity, id: Id<T>) -> () -> ()?) | (entity: Entity, id: Id<T>) -> ()?

export type ArchetypeMatch = (archetype: Archetype) -> boolean

export type ArchetypeObserverCallback = (archetype: Archetype) -> ()
export type ArchetypeObserver = { match: ArchetypeMatch, callback: ArchetypeObserverCallback }

-- archetype is the destination for added callbacks and the source for removed ones
export type QueryMonitorCallback = (entity: u53, operation_id: number?, archetype: Archetype?) -> ()

export type QueryIdMonitor = {
	match: ArchetypeMatch,
	added: QueryMonitorCallback?,
	removed: QueryMonitorCallback?,
}

export type QueryIdObserver = {
	match: ArchetypeMatch,
	callback: QueryMonitorCallback,
}

export type Monitor = {
	cleanup: Cleanup,
	added: ((entity: Entity) -> ()) -> (),
	removed: ((entity: Entity) -> ()) -> (),
}

export type QueryChanged<T...> = typeof(setmetatable(
	{} :: {
		iter: () -> () -> (Entity, T...),
		cleanup: Cleanup,
	},
	{} :: {
		__iter: () -> () -> (Entity, T...),
	}
))

export type Query<T...> = typeof(setmetatable(
	{} :: {
		is_cached: boolean,

		with: (Query<T...>, ...Component) -> Query<T...>,
		without: (Query<T...>, ...Component) -> Query<T...>,
		clone: (Query<T...>) -> Query<T...>,
		rematch: (Query<T...>) -> { Archetype },
		archetypes: (Query<T...>) -> { Archetype },
		columns: (Query<T...>) -> () -> ...{ any },

		match: (Query<T...>, Archetype) -> boolean,
		has: (Query<T...>, entity: Entity) -> boolean,
		empty: (Query<T...>) -> boolean,
		count: (Query<T...>) -> number,
		entities: (Query<T...>) -> { Entity },
		random: (Query<T...>) -> Entity?,
		first: (Query<T...>, predicator: ((Entity, T...) -> boolean)?) -> (Entity, T...),

		cached: (Query<T...>) -> Query<T...>,
		cleanup: (Query<T...>) -> (),
		iter: (Query<T...>) -> () -> (Entity, T...),
		patch: (Query<T...>, mapper: (entity: Entity, T...) -> T...) -> (),

		monitor: (Query<T...>) -> Monitor,
		observe: (Query<T...>, callback: (entity: Entity) -> ()) -> Cleanup,
		changed: (Query<T...>) -> QueryChanged<T...>,
	},
	{} :: {
		__iter: () -> () -> (Entity, T...),
	}
))

export type QueryInternal = Query<any> & {
	terms: { u53 },
	with_ids: { u53 },
	without_ids: { u53 }?,
	cache_cleanup: (() -> ())?,

	world: World,
	compatible_archetypes: Array<Archetype>,
	compatible_archetypes_map: Map<ArchetypeId, number>,
}

export type Archetype = {
	archetype_id: ArchetypeId,
	hash: string,
	-- alive: holds at least one entity. destroyed: removed from the world,
	-- edges cleared and component records unlinked; must never be reused.
	alive: boolean,
	destroyed: boolean,

	entities: { Entity },
	columns: Array<Column>,
	components: Array<u53>,

	columns_map: { [u53]: Column },
	-- (R, *) wildcard id -> the single (R, T) pair this archetype holds, for
	-- every exclusive relation R. Lets add/set/bulk ops find the pair to swap
	-- out with one lookup.
	exclusive_pairs: Map<u53, u53>,
	forward_edges: Map<u53, Archetype>,
	backwards_edges: Map<u53, Archetype>,
	swapped_edges: Map<u53, u53>,

	traversable_count: number,
	traversable_ids: { u53 },
}

export type EntityRecord = {
	archetype: Archetype,
	archetype_row: number,
	dense: u24,
	deleting: boolean,

	archetype_changed: { ArchetypeChangedHook }?,
}

export type ReachableElement = {
	archetype: Archetype,
	record: EntityRecord,
	entity: u53,
}

export type ReachableCache = {
	generation: number,
	current: number,
	cached: Map<u53, true>,
	reachable: Map<u53, ReachableElement>,
}

export type PairRecord = ComponentRecord & {
	pairs_count: Map<ArchetypeId, number>,

	-- all records that share the same relation: (R, *)
	first_records: Map<u53, PairRecord>,
	-- all records that share the same target: (*, T)
	second_records: Map<u53, PairRecord>,
	-- all records with a traversable relation that share the same target:
	-- (R, T) where R is any id with ECS_TRAVERSABLE trait
	trav_records: Map<u53, PairRecord>,

	-- To find which components are reachable through the relation
	reachable: ReachableCache,
}

export type ComponentRecord = {
	-- archetype id -> column index of this id inside that archetype. Lookup only.
	column_index: Map<ArchetypeId, number>,
	-- dense list of every archetypeid with this component.
	archetype_ids: { ArchetypeId },
	-- archetype id -> position in archetype_ids, for swap-remove
	archetype_slots: Map<ArchetypeId, number>,

	flags: Bitset,

	on_added: Array<{ SetHook }>?,
	on_changed: Array<{ SetHook }>?,
	on_removed: Array<{ RemovedHook }>?,

	monitors: Array<{ QueryIdMonitor }>?,

	-- observers_added will fire when the entity's archetype changes
	-- observers_changed will fire when the column value changes
	observers_added: Array<{ QueryIdObserver }>?,
	observers_changed: Array<{ QueryIdObserver }>?,
}

export type ComponentsLookup = Map<u53, ComponentRecord>

export type EntityIndex = {
	dense: Array<u53>,
	sparse: Map<u24, EntityRecord>,
	alive: number,
}

export type WorldInternal = {
	entity_index: EntityIndex,
	component_record_ensure: (id: u53) -> ComponentRecord,

	get_entity_any: (entity_id: u24) -> u53?,
	get_entity_alive: (entity_id: u24) -> u53?,

	get_entity_record: (entity: u53) -> EntityRecord?,
	get_entity_record_alive: (entity: u53) -> EntityRecord?,
	get_entity_record_asserts_alive: (entity: u53) -> EntityRecord?,

	archetype_creation_observers: Map<u53, { ArchetypeObserver }>,
	archetype_destruction_observers: Map<u53, { ArchetypeObserver }>,

	-- entity index
	get_new_entity_id: () -> u53,
	delete_entity_id: (id: u24, record: EntityRecord) -> (),

	-- component records
	component_record_create: (id: u53) -> ComponentRecord,
	wildcard_record_ensure: (wildcard: u53) -> PairRecord,
	check_is_component: (relation: u53, target: u53?) -> boolean,

	-- archetype graph
	archetype_create: (ids: { u53 }, hash: string) -> Archetype,
	archetype_ensure: (ids: { u53 }) -> Archetype,
	archetype_destroy: (archetype: Archetype) -> (),
	archetype_find_with: (source: Archetype, id: u53) -> Archetype,
	archetype_find_without: (source: Archetype, id: u53) -> Archetype,
	archetype_find_swap_with: (source: Archetype, old: u53, new: u53, column: number) -> Archetype,

	-- archetype rows
	archetype_insert_entity: (entity: u53, archetype: Archetype) -> number,
	archetype_assign_entity: (entity: u53, record: EntityRecord, archetype: Archetype) -> (),
	archetype_move_entity: (entity: u53, record: EntityRecord, source: Archetype, destination: Archetype) -> (),
	archetype_delete_entity: (archetype: Archetype, row: number) -> (),

	-- module level helpers (stateless)
	ENTITY_MASK: number,
	GENERATION_MASK: number,
	MAX_COMPONENT_ID: number,
	ENTITY_ID: (e: u53) -> u24,
	ENTITY_GENERATION: (e: u53) -> u24,
	APPEND_GENERATION: (id: number, generation: number) -> u53,
	INCREMENT_GENERATION: (e: u53) -> u53,
	FIND_INSERT: (ids: { u53 }, added: u53) -> number,
	HASH_IDS: (ids: { u53 }) -> string,
	REMOVE_ALL_PAIRS: (
		components: { u53 },
		components_count: number,
		pair_start: number,
		pair_count: number
	) -> { u53 },
	INSERT_COMPONENT_HOOK: <T>(callback: T, hooks: { T }?) -> ({ T }, Cleanup),
	MATCH_ARCHETYPE: (with_ids: { number }, without_ids: { number }?, archetype: Archetype) -> boolean,
	FIND_MATCHED_ARCHETYPES: (
		world: World,
		with_ids: { number },
		without_ids: { number }?,
		ignore_empty: boolean
	) -> { Archetype },
	OBSERVE_MATCHED_ARCHETYPES: (
		world: World,
		with_ids: { number },
		without_ids: { number }?
	) -> ({ Archetype }, Map<ArchetypeId, number>, Cleanup),
	MONITOR_ATTACH: (world: World, ids: { u53 }, monitor: QueryIdMonitor) -> Cleanup,
	OBSERVER_ATTACH: (world: World, ids: { u53 }, observer: QueryIdObserver) -> Cleanup,
	monitor_new: (world: World, with_ids: { u53 }, without_ids: { u53 }?) -> Monitor,

	get_archetypes_count: () -> number,

	ECS_PAIR: (first: u53, second: u53) -> u53,
	PAIR_FIRST: (id: u53) -> u24,
	PAIR_SECOND: (id: u53) -> u24,
	IS_PAIR: (id: u53) -> boolean,
	ECS_WILDCARD: u53,
	ECS_TRANSITIVE: u53,
	NULL_ARRAY: { any },
}

export type World = {
	components_lookup: Map<u53, ComponentRecord>,
	archetypes_lookup: Map<string, Archetype>,
	internal: WorldInternal,

	archetypes: Map<ArchetypeId, Archetype>,
	ROOT_ARCHETYPE: Archetype,

	tag: () -> Entity,
	component: <T>() -> Component<T>,
	entity: () -> Entity,

	exists: (entity: Entity) -> boolean,
	alive: (entity: Entity) -> boolean,
	deleting: (entity: Entity) -> boolean,

	has: (entity: Entity, id: Component) -> boolean,
	get: & (<A>(Entity, Component<A>) -> A)
		& (<A, B>(Entity, Component<A>, Component<B>) -> (A, B))
		& (<A, B, C>(Entity, Component<A>, Component<B>, Component<C>) -> (A, B, C))
		& (<A, B, C, D>(Entity, Component<A>, Component<B>, Component<C>, Component<D>) -> (A, B, C, D))
		& (<A, B, C, D, E>(
			Entity,
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>
		) -> (A, B, C, D, E))
		& (<A, B, C, D, E, F>(
			Entity,
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>
		) -> (A, B, C, D, E, F))
		& (<A, B, C, D, E, F, G>(
			Entity,
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>,
			Component<G>
		) -> (A, B, C, D, E, F, G))
		& (<A, B, C, D, E, F, G, H>(
			Entity,
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>,
			Component<G>,
			Component<H>
		) -> (A, B, C, D, E, F, G, H))
		& (<A, B, C, D, E, F, G, H>(
			Entity,
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>,
			Component<G>,
			Component<H>,
			...Component
		) -> (A, B, C, D, E, F, G, H, ...any)),

	parent: (child: Entity) -> Entity,
	children: (parent: Entity) -> () -> Entity,
	target: (entity: Entity, relation: Id, index: number?) -> Entity,
	traverse: <T>(entity: Entity, relation: Id, id: Component<T>) -> (Entity, T),
	pairs: (entity: Entity, relation: Id) -> () -> Entity,

	add: (entity: Entity, id: Component) -> (),
	set: <T>(entity: Entity, id: Component<T>, data: T) -> (),
	remove: (entity: Entity, id: Component) -> (),
	delete: (entity: Entity) -> (),

	wipe: (component: Id) -> (),
	clear: (entity: Entity) -> (),

	bulk_add: (entity: Entity, ids: { Id }) -> (),
	bulk_set: (entity: Entity, ids: { Id }, values: { any }) -> (),
	bulk_remove: (entity: Entity, ids: { Id }) -> (),

	added: <T>(id: Id<T>, callback: SetHook<T>) -> Cleanup,
	changed: <T>(id: Id<T>, callback: SetHook<T>) -> Cleanup,
	removed: <T>(id: Id<T>, callback: RemovedHook<T>) -> Cleanup,

	pair_first: <T>(Pair<T, any>) -> Id<T>,
	pair_second: <T>(Pair<any, T>) -> Id<T>,
	is_component: (Id) -> boolean,
	is_tag: (Id) -> boolean,

	each: (id: Component) -> () -> Entity,
	query_build: () -> QueryBuilder,
	query: (() -> Query<nil>)
		& (<A>(Component<A>) -> Query<A>)
		& (<A, B>(Component<A>, Component<B>) -> Query<A, B>)
		& (<A, B, C>(Component<A>, Component<B>, Component<C>) -> Query<A, B, C>)
		& (<A, B, C, D>(Component<A>, Component<B>, Component<C>, Component<D>) -> Query<A, B, C, D>)
		& (<A, B, C, D, E>(
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>
		) -> Query<A, B, C, D, E>)
		& (<A, B, C, D, E, F>(
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>
		) -> Query<A, B, C, D, E, F>)
		& (<A, B, C, D, E, F, G>(
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>,
			Component<G>
		) -> Query<A, B, C, D, E, F, G>)
		& (<A, B, C, D, E, F, G, H>(
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>,
			Component<G>,
			Component<H>,
			...Component<any>
		) -> Query<A, B, C, D, E, F, G, H>),
}

-------------------------------------------------------------------------------
-- query engine
-------------------------------------------------------------------------------

export type QueryBuilder = {
	term: (self: QueryBuilder, id: any) -> QueryBuilder,
	with: (self: QueryBuilder, id: any) -> QueryBuilder,
	without: (self: QueryBuilder, id: any) -> QueryBuilder,

	optional: (self: QueryBuilder) -> QueryBuilder,
	bor: (self: QueryBuilder) -> QueryBuilder,
	wildcard: (self: QueryBuilder) -> QueryBuilder,
	target: (self: QueryBuilder, target: any) -> QueryBuilder,
	from: (self: QueryBuilder, source: string) -> QueryBuilder,
	up: (self: QueryBuilder, relation: any) -> QueryBuilder,
	self: (self: QueryBuilder) -> QueryBuilder,
	transitive: (self: QueryBuilder) -> QueryBuilder,

	build: (self: QueryBuilder) -> EngineQuery,
}

-- Query produced by QueryBuilder:build(). Distinct from Query<T...>, the
-- world.query() object.
export type EngineQuery = typeof(setmetatable(
	{} :: {
		iter: (self: EngineQuery) -> () -> ...any,
		archetypes: (self: EngineQuery) -> { any },
		match: (self: EngineQuery, archetype: any) -> boolean,
		rematch: (self: EngineQuery) -> { any },
		cached: (self: EngineQuery) -> EngineQuery,
		cleanup: (self: EngineQuery) -> (),
		var: (self: EngineQuery, name: string) -> any,
		monitor: (self: EngineQuery) -> Monitor,
		is_cached: boolean,
	},
	{} :: { __iter: (self: EngineQuery) -> () -> ...any }
))

return nil
