local ReplicatedStorage = game:GetService("ReplicatedStorage")

local types = require(ReplicatedStorage.Packages.miumiu.types)
local datastore = require(ReplicatedStorage.Packages.miumiu.datastore)
local jecs = require(ReplicatedStorage.Packages.jecs)
local miumiu = require(ReplicatedStorage.Packages.miumiu)
local session = require(ReplicatedStorage.Packages.miumiu.session)
local state = require(ReplicatedStorage.Packages.miumiu.state)

type World = miumiu.World
type Batch = miumiu.Batch
type Session = miumiu.Session
type Entity<T = nil> = miumiu.Entity<T>
type DataStore = types.DataStore
type DataStoreGetOptions = types.DataStoreGetOptions
type DataStorePages = types.DataStorePages
type DataStoreService = types.DataStoreService
type Event = types.Event
type OrderedConfig = types.OrderedConfig
type OrderedDataStore = types.OrderedDataStore
type OrderedEntry = types.OrderedEntry
type LinkState = types.LinkState
type Migration = miumiu.Migration
type Op = miumiu.Op
type ResolvedCollectionConfig = miumiu.ResolvedCollectionConfig
type Serdes = miumiu.Serdes
type SessionInternal = types.SessionInternal

local function find_package(prefix: string): Instance
	for _, child in ReplicatedStorage.DevPackages._Index:GetChildren() do
		if string.sub(child.Name, 1, #prefix) == prefix then
			return child
		end
	end
	error(`spec: no dev package starting with "{prefix}"`)
end

local mock_package =
	find_package("buildthomas_mockdatastoreservice@"):FindFirstChild("mockdatastoreservice") :: Instance
local mock: any = require(mock_package.MockDataStoreService)
local mock_constants: any = require(mock_package.MockDataStoreService.MockDataStoreConstants)

mock_constants.YIELD_TIME_MIN = 0
mock_constants.YIELD_TIME_MAX = 0
mock_constants.YIELD_TIME_UPDATE_MIN = 0
mock_constants.YIELD_TIME_UPDATE_MAX = 0
mock_constants.WRITE_COOLDOWN = 0
mock_constants.GET_COOLDOWN = 0
mock_constants.BUDGETING_ENABLED = false
mock_constants.BUDGET_UPDATE_INTERVAL = 0.01

export type FailMode = "before" | "after"

export type Delay = {
	op: string,
	seconds: number,
	mode: FailMode,
	skip: number,
}

export type Failure = {
	op: string,
	mode: FailMode,
	message: string,
	skip: number,
}

export type Backend = {
	name: string,
	service: DataStoreService,
	plain_service: DataStoreService,
	store: DataStore,
	ordered: (self: Backend, name: string) -> OrderedDataStore,
	sorted: (self: Backend, name: string) -> { OrderedEntry },
	failures: { Failure },
	delays: { Delay },
	calls: { [string]: number },
	fresh_reads: number,
	warnings: { string },
	fail_next: (self: Backend, op: string, mode: FailMode, message: string?, skip: number?) -> (),
	delay_next: (self: Backend, op: string, seconds: number, mode: FailMode?, skip: number?) -> (),
	dump: (self: Backend, key: string) -> any,
	seed: (self: Backend, key: string, value: any) -> (),
	seed_raw: (self: Backend, key: string, value: any) -> (),
}

export type Overrides = {
	pull_interval: number?,
	idle_interval: number?,
	retry_attempts: number?,
	retry_base: number?,
	commit_store: string?,
	commit_timeout: number?,
	migrations: { Migration }?,
	user_ids: ((key: string) -> { number })?,
}

export type Fixture = {
	backend: Backend,
	world: World,
	money: Entity<number>,
	items: Entity<{ any }>,
	tutorial: Entity,
	player_data: Entity,
	link: Entity<string>,
	loading: Entity,
	loaded: Entity,
	data_error: Entity<string>,
}

local timings = {
	pull_interval = 0.05,
	idle_interval = 0.05,
	never = 10,
	grace = 0.1,
	long = 3,
	in_flight = 0.05,
	short = 0.02,
	fast = 0.01,
	window = 0.1,
	slow = 0.3,
	overdue = 1.1,
	poll = 0.005,
	patience = 1,
	retry_attempts = 5,
	retry_base = 0.005,
	commit_timeout = 1,
	budget = 5,
}

local counter = 0

local function take_failure(backend: Backend, op: string): Failure?
	for index, failure in backend.failures do
		if failure.op == "*" or failure.op == op then
			if failure.skip > 0 then
				failure.skip -= 1
				return nil
			end
			table.remove(backend.failures, index)
			return failure
		end
	end
	return nil
end

local function take_delay(backend: Backend, op: string): Delay?
	for index, delay in backend.delays do
		if delay.op == op then
			if delay.skip > 0 then
				delay.skip -= 1
				return nil
			end
			table.remove(backend.delays, index)
			return delay
		end
	end
	return nil
end

local function guarded<T>(backend: Backend, op: string, body: () -> T): T
	backend.calls[op] = (backend.calls[op] or 0) + 1
	local delay = take_delay(backend, op)
	if delay and delay.mode == "before" then
		task.wait(delay.seconds)
	end
	local failure = take_failure(backend, op)
	if failure and failure.mode == "before" then
		error(failure.message)
	end
	local result = body()
	if delay and delay.mode == "after" then
		task.wait(delay.seconds)
	end
	if failure and failure.mode == "after" then
		error(failure.message)
	end
	return result
end

local function proxy_store(backend: Backend, inner: any): DataStore
	return {
		GetAsync = function(_, key: string, options: DataStoreGetOptions?)
			if options and options.UseCache == false then
				backend.fresh_reads += 1
			end
			return guarded(backend, "GetAsync", function()
				return inner:GetAsync(key)
			end)
		end,
		SetAsync = function(_, key: string, value: any)
			return guarded(backend, "SetAsync", function()
				return inner:SetAsync(key, value)
			end)
		end,
		UpdateAsync = function(_, key: string, transform: (any) -> any)
			return guarded(backend, "UpdateAsync", function()
				return inner:UpdateAsync(key, transform)
			end)
		end,
	}
end

local function proxy_pages(backend: Backend, inner: any): DataStorePages
	local pages: DataStorePages
	pages = {
		IsFinished = inner.IsFinished,
		GetCurrentPage = function()
			return inner:GetCurrentPage()
		end,
		AdvanceToNextPageAsync = function()
			guarded(backend, "AdvanceToNextPageAsync", function()
				inner:AdvanceToNextPageAsync()
			end)
			pages.IsFinished = inner.IsFinished
		end,
	}
	return pages
end

local function proxy_ordered(backend: Backend, inner: any): OrderedDataStore
	return {
		GetAsync = function(_, key: string)
			return guarded(backend, "OrderedGetAsync", function()
				return inner:GetAsync(key)
			end)
		end,
		SetAsync = function(_, key: string, value: number)
			return guarded(backend, "OrderedSetAsync", function()
				return inner:SetAsync(key, value)
			end)
		end,
		RemoveAsync = function(_, key: string)
			return guarded(backend, "OrderedRemoveAsync", function()
				return inner:RemoveAsync(key)
			end)
		end,
		GetSortedAsync = function(_, ascending: boolean, page_size: number)
			return guarded(backend, "GetSortedAsync", function()
				return proxy_pages(backend, inner:GetSortedAsync(ascending, page_size))
			end)
		end,
	}
end

local function ordered(self: Backend, name: string): OrderedDataStore
	return mock:GetOrderedDataStore(`{self.name}/{name}`)
end

local function sorted(self: Backend, name: string): { OrderedEntry }
	local entries: { OrderedEntry } = {}
	for _, entry in self:ordered(name):GetSortedAsync(false, 100):GetCurrentPage() do
		table.insert(entries, { key = entry.key, score = entry.value })
	end
	return entries
end

local function fail_next(self: Backend, op: string, mode: FailMode, message: string?, skip: number?)
	table.insert(self.failures, {
		op = op,
		mode = mode,
		message = message or `spec: injected {mode} failure on {op}`,
		skip = skip or 0,
	})
end

local function delay_next(self: Backend, op: string, seconds: number, mode: FailMode?, skip: number?)
	table.insert(self.delays, { op = op, seconds = seconds, mode = mode or "after", skip = skip or 0 })
end

local function dump(self: Backend, key: string): any
	return self.store:GetAsync(key)
end

local function seed_raw(self: Backend, key: string, value: any)
	self.store:SetAsync(key, value)
end

local function seed(self: Backend, key: string, value: any)
	if type(value) == "table" and value.version == nil then
		value = table.clone(value)
		value.version = 1
	end
	seed_raw(self, key, value)
end

local live_backends: { Backend } = {}

local function fan_out(message: string)
	for _, backend in live_backends do
		table.insert(backend.warnings, message)
	end
end

local function create_backend(): Backend
	counter += 1
	local name = `Spec{counter}`
	local backend: Backend
	local plain_service = {
		GetDataStore = function(_, store_name: string): DataStore
			return proxy_store(backend, mock:GetDataStore(store_name))
		end,
	}
	backend = {
		name = name,
		service = {
			GetDataStore = plain_service.GetDataStore,
			GetOrderedDataStore = function(_, store_name: string): OrderedDataStore
				return proxy_ordered(backend, mock:GetOrderedDataStore(`{name}/{store_name}`))
			end,
		},
		plain_service = plain_service :: any,
		store = mock:GetDataStore(name),
		ordered = ordered,
		sorted = sorted,
		failures = {},
		delays = {},
		calls = {},
		fresh_reads = 0,
		warnings = {},
		fail_next = fail_next,
		delay_next = delay_next,
		dump = dump,
		seed = seed,
		seed_raw = seed_raw,
	}

	table.insert(live_backends, backend)
	miumiu.set_warn(fan_out)

	return backend
end

local function warning_count(backend: Backend, needle: string): number
	local count = 0
	for _, warning in backend.warnings do
		if string.find(warning, needle, 1, true) then
			count += 1
		end
	end
	return count
end

local function warned(backend: Backend, needle: string): boolean
	for _, warning in backend.warnings do
		if string.find(warning, needle, 1, true) then
			return true
		end
	end
	return false
end

local function commit_store(backend: Backend, config: ResolvedCollectionConfig): DataStore
	return backend.service:GetDataStore(config.commit_store)
end

local function create_config(backend: Backend, overrides: Overrides?): ResolvedCollectionConfig
	local given: Overrides = overrides or {}
	local pull_interval = given.pull_interval or timings.pull_interval
	return {
		name = backend.name,
		data_store_service = backend.service,
		pull_interval = pull_interval,
		idle_interval = given.idle_interval or math.max(timings.idle_interval, pull_interval),
		retry_attempts = given.retry_attempts or timings.retry_attempts,
		retry_base = given.retry_base or timings.retry_base,
		commit_store = given.commit_store or `{backend.name}_commits`,
		commit_timeout = given.commit_timeout or timings.commit_timeout,
		migrations = given.migrations or {},
		foreign = nil,
		user_ids = given.user_ids,
	}
end

local live_sessions: { SessionInternal } = {}
local live_worlds: { World } = {}

local function open_store(backend: Backend): DataStore
	return datastore.open(backend.service, backend.name)
end

local function open_session(backend: Backend, key: string, overrides: Overrides?): SessionInternal
	local config = create_config(backend, overrides)
	local loaded = session.load_session(
		{ config = config, store = open_store(backend), ordered = {} },
		key,
		function(truth)
			return truth
		end
	)
	table.insert(live_sessions, loaded)
	return loaded
end

local id_counter = 0

local function fresh_id(prefix: string?): string
	id_counter += 1
	return `{prefix or "spec"}-{id_counter}-{os.time()}`
end

local function journal(loaded: SessionInternal, ops: { Op }, id: string?, shared: boolean?)
	loaded:journal({
		id = id or fresh_id(),
		ops = ops,
		kind = if shared then "shared" else "single",
	})
end

local function cleanup()
	for _, world in live_worlds do
		miumiu.close(world, 0)
	end
	table.clear(live_worlds)
	for _, loaded in live_sessions do
		if loaded:is_open() then
			pcall(loaded.unload, loaded)
		end
	end
	table.clear(live_sessions)
	table.clear(live_backends)
end

local function take_over(backend: Backend, key: string)
	open_session(backend, key, { pull_interval = timings.never, migrations = { function() end } }):unload()
end

local function create_collection(world: World, backend: Backend, overrides: Overrides?): Entity
	local config = create_config(backend, overrides)
	local collection = world:entity()
	world:set(collection, jecs.Name, backend.name)
	world:set(collection, miumiu.collection, backend.name)
	world:set(collection, miumiu.config, {
		data_store_service = config.data_store_service,
		pull_interval = config.pull_interval,
		idle_interval = config.idle_interval,
		retry_attempts = config.retry_attempts,
		retry_base = config.retry_base,
		commit_store = config.commit_store,
		commit_timeout = config.commit_timeout,
		user_ids = config.user_ids,
	})
	return collection
end

local function scope(world: World, ids: { Entity<any> }, targets: { Entity })
	for _, id in ids do
		for _, target in targets do
			world:add(id, jecs.pair(miumiu.field_of, target))
		end
	end
end

local function declare_saveable(
	world: World,
	kind: "component" | "tag",
	key: string?,
	targets: { Entity },
	name: string?
): Entity<any>
	local id = if kind == "component" then world:component() else world:entity()
	world:set(id, jecs.Name, name or key or "unnamed")
	if key then
		world:set(id, miumiu.saveable, key)
	else
		world:add(id, miumiu.saveable)
	end
	scope(world, { id }, targets)
	return id
end

export type Kinds = {
	owns: Entity,
	item: Entity,
	holds: Entity,
	container: Entity,
	container_kind: Entity<string>,
}

local function declare_kinds(world: World, root: Entity): Kinds
	local owns = world:entity()
	world:add(owns, jecs.Exclusive)
	local item = world:entity()
	world:set(item, jecs.Name, "item")
	world:set(item, miumiu.child, { via = owns, key = "inventory", mode = "owned" })
	local holds = world:entity()
	world:add(holds, jecs.Exclusive)
	local container_kind = world:component()
	local container = world:entity()
	world:set(container, jecs.Name, "container")
	world:set(container, miumiu.child, { via = holds, key = "containers", mode = "attached", id = container_kind })
	scope(world, { item, container }, { root })
	return { owns = owns, item = item, holds = holds, container = container, container_kind = container_kind }
end

export type Relations = {
	has_buff: Entity,
	fire: Entity,
	ice: Entity,
}

local function declare_relations(world: World, targets: { Entity }): Relations
	local has_buff = world:entity()
	world:set(has_buff, jecs.Name, "has_buff")
	world:set(has_buff, miumiu.saveable, "buffs")
	world:add(has_buff, miumiu.pairs)
	scope(world, { has_buff }, targets)
	local fire = world:entity()
	world:set(fire, jecs.Name, "fire")
	local ice = world:entity()
	world:set(ice, jecs.Name, "ice")
	return { has_buff = has_buff, fire = fire, ice = ice }
end

local function anything(): boolean
	return true
end

local function declare_ordered(world: World, collection: Entity, name: string, config: OrderedConfig): Entity
	local entity = world:entity()
	world:set(entity, jecs.Name, name)
	world:add(entity, jecs.pair(miumiu.field_of, collection))
	world:set(entity, miumiu.ordered, config)
	return entity
end

local function create_fixture(overrides: Overrides?): Fixture
	local backend = create_backend()
	local world = jecs.world()
	table.insert(live_worlds, world)
	local player_data = create_collection(world, backend, overrides)
	local money = declare_saveable(world, "component", "money", { player_data })
	world:set(money, miumiu.guard, anything)
	local items = declare_saveable(world, "component", "items", { player_data })
	world:set(items, miumiu.guard, anything)
	local tutorial = declare_saveable(world, "tag", "tutorial", { player_data })
	return {
		backend = backend,
		world = world,
		money = money,
		items = items,
		tutorial = tutorial,
		player_data = player_data,
		link = jecs.pair(miumiu.data_link, player_data),
		loading = jecs.pair(miumiu.data_loading, player_data),
		loaded = jecs.pair(miumiu.data_loaded, player_data),
		data_error = jecs.pair(miumiu.data_error, player_data),
	}
end

local function create_set_serdes(): Serdes
	return {
		serialize = function(set)
			local list = {}
			for code in set do
				table.insert(list, code)
			end
			table.sort(list)
			return list
		end,
		deserialize = function(list)
			if type(list) ~= "table" then
				error("not a list")
			end
			local set = {}
			for _, code in list do
				set[code] = true
			end
			return set
		end,
	}
end

local function link_state(fixture: Fixture, key: string): LinkState?
	local by_key = state.get(fixture.world).link_states[fixture.player_data]
	return if by_key then by_key[key] else nil
end

local function session_of(fixture: Fixture, key: string): SessionInternal
	local open = state.open_session(link_state(fixture, key))
	if open then
		return open
	end
	error(`spec: no loaded session for "{key}"`)
end

local function events(fixture: Fixture): { Event }
	return state.get(fixture.world).events
end

local function orphans(fixture: Fixture): number
	local count = 0
	for _ in state.get(fixture.world).orphans do
		count += 1
	end
	return count
end

local function other_server(fixture: Fixture, key: string): SessionInternal
	return open_session(fixture.backend, key, { pull_interval = timings.never })
end

local function set(key: string, value: any, at: number): Op
	return { kind = "set", key = key, value = value, at = at }
end

local function remove(key: string, at: number): Op
	return { kind = "remove", key = key, at = at }
end

local function add(key: string, delta: number): Op
	return { kind = "add", key = key, delta = delta }
end

local function wait_until(condition: () -> boolean, timeout: number?): boolean
	local remaining = timeout or timings.patience
	while remaining > 0 do
		if condition() then
			return true
		end
		remaining -= task.wait(timings.poll)
	end
	return condition()
end

local function wait_closed(loaded: Session): boolean
	return wait_until(function()
		return not loaded:is_open()
	end)
end

local function wait_settled(batch: Batch): boolean
	return wait_until(function()
		return batch:is_settled()
	end)
end

local function wait_for_events(fixture: Fixture, count: number): boolean
	return wait_until(function()
		return #events(fixture) >= count
	end)
end

local function settle(fixture: Fixture, entity: Entity): boolean
	miumiu.step(fixture.world)
	return wait_until(function()
		miumiu.step(fixture.world)
		return fixture.world:has(entity, fixture.loaded) or fixture.world:has(entity, fixture.data_error)
	end)
end

local function give(fixture: Fixture, kinds: Kinds, owner: Entity, money: number): Entity
	local entity = fixture.world:entity()
	fixture.world:add(entity, kinds.item)
	fixture.world:set(entity, fixture.money, money)
	fixture.world:add(entity, jecs.pair(kinds.owns, owner))
	return entity
end

local function make_container(fixture: Fixture, kinds: Kinds, id: any): Entity
	local container = fixture.world:entity()
	fixture.world:add(container, kinds.container)
	fixture.world:set(container, kinds.container_kind, id)
	return container
end

local function id_of(fixture: Fixture, entity: Entity): string
	return fixture.world:get(entity, miumiu.child_id)
end

local function items_of(fixture: Fixture, kinds: Kinds, owner: Entity): { [string]: Entity }
	local found = {}
	for entity in fixture.world:each(jecs.pair(kinds.owns, owner)) do
		if fixture.world:has(entity, kinds.item) then
			found[id_of(fixture, entity)] = entity
		end
	end
	return found
end

local function count(dictionary: { [any]: any }): number
	local total = 0
	for _ in dictionary do
		total += 1
	end
	return total
end

local function link_entity(fixture: Fixture, key: string, values: { [string]: any }?): Entity
	local entity = fixture.world:entity()
	fixture.world:set(entity, fixture.link, key)
	settle(fixture, entity)
	local saveables: { [string]: Entity<any> } =
		{ money = fixture.money, items = fixture.items, tutorial = fixture.tutorial }
	local given: { [string]: any } = values or {}
	for name, value in given do
		fixture.world:set(entity, saveables[name], value)
	end
	if next(given) ~= nil then
		session_of(fixture, key):sync()
	end
	return entity
end

return table.freeze({
	timings = timings,
	create_backend = create_backend,
	warned = warned,
	warning_count = warning_count,
	commit_store = commit_store,
	create_config = create_config,
	open_store = open_store,
	open_session = open_session,
	fresh_id = fresh_id,
	journal = journal,
	cleanup = cleanup,
	create_collection = create_collection,
	declare_saveable = declare_saveable,
	scope = scope,
	declare_kinds = declare_kinds,
	declare_relations = declare_relations,
	create_fixture = create_fixture,
	create_set_serdes = create_set_serdes,
	declare_ordered = declare_ordered,
	link_state = link_state,
	session_of = session_of,
	events = events,
	orphans = orphans,
	other_server = other_server,
	link_entity = link_entity,
	give = give,
	make_container = make_container,
	id_of = id_of,
	items_of = items_of,
	count = count,
	set = set,
	remove = remove,
	add = add,
	wait_until = wait_until,
	wait_closed = wait_closed,
	wait_settled = wait_settled,
	take_over = take_over,
	wait_for_events = wait_for_events,
	settle = settle,
})
