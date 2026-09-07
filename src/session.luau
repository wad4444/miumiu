local types = require("./types")
local callbacks = require("./callbacks")
local commit = require("./commit")
local datastore = require("./datastore")
local foreign = require("./foreign")
local hooks = require("./hooks")
local messages = require("./messages")
local mutex = require("./mutex")
local ops = require("./ops")
local pull_loop = require("./pull_loop")
local symbol = require("./symbol")
local util = require("./util")

type Callback = types.Callback
type Closure = types.Closure
type CollectionState = types.CollectionState
type Data = types.Data
type Group = types.Group
type Landed = types.Landed
type Landing = types.Landing
type Merge = types.Merge
type MergedPull = types.MergedPull
type Migrate = types.Migrate
type Migrated = types.Migrated
type Mutex = types.Mutex
type Op = types.Op
type Pending = types.Pending
type PullResult = types.PullResult
type Resolution = types.Resolution
type ResolvedCollectionConfig = types.ResolvedCollectionConfig
type RetryConfig = types.RetryConfig
type SessionInternal = types.SessionInternal
type Stamps = types.Stamps
type State = types.State
type StoredRecord = types.StoredRecord
type Symbol = types.Symbol

local session_symbol = symbol.create_symbol("Session")

local function empty_state(): State
	return { truth = {}, stamps = {} }
end

local function state_of(record: StoredRecord): State
	return { truth = record.data or {}, stamps = record.stamps or {} }
end

local function validate_open(self: SessionInternal)
	if not self.internal_values.open then
		error(messages.errors.session_closed(self.internal_values.key), 0)
	end
end

local function close(self: SessionInternal, closure: Closure)
	local values = self.internal_values
	if not values.open then
		return
	end
	values.open = false
	values.closure = closure
	self.internal_mutex:close(messages.errors.session_closed(values.key))
	callbacks.fire(self.internal_hooks, hooks.closed, self, closure)
end

local function discard(self: SessionInternal, message: string)
	close(self, { kind = "abandoned", message = message })
end

local function get_key(self: SessionInternal): string
	return self.internal_values.key
end

local function get_config(self: SessionInternal): ResolvedCollectionConfig
	return self.internal_collection.config
end

local function get_closure(self: SessionInternal): Closure?
	return self.internal_values.closure
end

local function get_pulls(self: SessionInternal): number
	return self.internal_values.pulls
end

local function get_state(self: SessionInternal): State
	local cached = self.internal_cache
	if cached then
		return cached
	end
	local state = self.internal_base
	for _, group in self.internal_awaiting do
		state = ops.replay(state, group.ops)
	end
	for _, group in self.internal_unwritten do
		state = ops.replay(state, group.ops)
	end
	self.internal_cache = state
	return state
end

local function forget_state(self: SessionInternal)
	self.internal_cache = nil
	self.internal_before_last = nil
end

local function get_truth(self: SessionInternal): Data
	return get_state(self).truth
end

local function get_stamps(self: SessionInternal): Stamps
	return get_state(self).stamps
end

local function is_open(self: SessionInternal): boolean
	return self.internal_values.open
end

local function is_dirty(self: SessionInternal): boolean
	return #self.internal_unwritten > 0 or self.internal_values.touched
end

local function touch(self: SessionInternal)
	validate_open(self)
	self.internal_values.touched = true
end

local function floor_of(state: State, op: Op): number
	if op.kind == "set" or op.kind == "remove" then
		return state.stamps[op.key] or 0
	end
	if op.kind == "put" or op.kind == "drop" then
		return ops.path_floor(state.stamps, op.key, op.path)
	end
	return 0
end

local function bump(op: Op, floor: number): Op
	if (op.kind == "set" or op.kind == "remove" or op.kind == "put" or op.kind == "drop") and op.at <= floor then
		local bumped = table.clone(op)
		bumped.at = floor + 1
		return bumped
	end
	return op
end

local function stamp_after(state: State, group_ops: { Op }): { Op }
	local adjusted: { Op } = {}
	for _, op in group_ops do
		local stamped = bump(op, floor_of(state, op))
		table.insert(adjusted, stamped)
		state = ops.replay(state, { stamped })
	end
	return adjusted
end

local function coalesced_slot(self: SessionInternal, coalesce: string?): number?
	if coalesce == nil then
		return nil
	end
	local unwritten = self.internal_unwritten
	local last = unwritten[#unwritten]
	if last and last.coalesce == coalesce then
		return #unwritten
	end
	return nil
end

local function journal(self: SessionInternal, group: Group)
	validate_open(self)
	if #group.ops == 0 then
		return
	end
	local slot = coalesced_slot(self, group.coalesce)
	local base: State
	if slot then
		table.remove(self.internal_unwritten, slot)
		local before_last = self.internal_before_last
		if before_last then
			base = before_last
		else
			forget_state(self)
			base = get_state(self)
		end
	else
		base = get_state(self)
	end
	local adjusted = stamp_after(base, group.ops)
	table.insert(self.internal_unwritten, {
		id = group.id,
		ops = adjusted,
		kind = group.kind,
		coalesce = group.coalesce,
	})
	self.internal_before_last = base
	self.internal_cache = ops.replay(base, adjusted)
end

local function remove_group(groups: { Group }, id: string)
	for index = #groups, 1, -1 do
		if groups[index].id == id then
			table.remove(groups, index)
		end
	end
end

local function abandon(self: SessionInternal, id: string)
	remove_group(self.internal_unwritten, id)
	remove_group(self.internal_awaiting, id)
	forget_state(self)
end

local function has_landed(self: SessionInternal, id: string): boolean
	local collection = self.internal_collection
	local ok, record = pcall(datastore.get_async, collection.store, self.internal_values.key, collection.config)
	return ok and type(record) == "table" and type(record.landed) == "table" and record.landed[id] ~= nil
end

local function forget_written(self: SessionInternal, written: { Group }): { Group }
	local unwritten = self.internal_unwritten
	local removed: { Group } = {}
	for _, group in written do
		local index = table.find(unwritten, group)
		if index then
			table.remove(unwritten, index)
			table.insert(removed, group)
		end
	end
	return removed
end

local function await_shared(self: SessionInternal, groups: { Group })
	for _, group in groups do
		if group.kind == "shared" then
			table.insert(self.internal_awaiting, group)
		end
	end
end

local function forget_settled(self: SessionInternal, record: StoredRecord, decided: { string })
	for _, id in decided do
		remove_group(self.internal_awaiting, id)
	end
	local pending = record.pending or {}
	local awaiting = self.internal_awaiting
	for index = #awaiting, 1, -1 do
		if pending[awaiting[index].id] == nil then
			table.remove(awaiting, index)
		end
	end
end

local function same_record(self: SessionInternal, old: StoredRecord): boolean
	local values = self.internal_values
	if old.written ~= nil or values.written ~= nil then
		return old.written == values.written
	end
	return old.version == values.version
end

local function base_state(self: SessionInternal, old: StoredRecord?): State
	if old == nil then
		return if self.internal_values.version == 0 then self.internal_base else empty_state()
	end
	if same_record(self, old) then
		return self.internal_base
	end
	return state_of(old)
end

local function applied_migrations(self: SessionInternal, old: StoredRecord?, seeded: boolean): number
	if old then
		return old.migrations or 0
	end
	return if seeded then 0 else #self.internal_collection.config.migrations
end

local function migrate_state(self: SessionInternal, old: StoredRecord?, state: State, seeded: boolean): Migrated
	local declared = #self.internal_collection.config.migrations
	local applied = applied_migrations(self, old, seeded)
	if applied > declared then
		return { kind = "newer", message = messages.errors.newer_record(self.internal_values.key, applied, declared) }
	end
	if applied < declared then
		return {
			kind = "state",
			state = { truth = self.internal_migrate(state.truth, applied), stamps = state.stamps },
			migrated = true,
		}
	end
	return { kind = "state", state = state, migrated = false }
end

local function land_groups(state: State, pending: Pending, landed: Landed, groups: { Group }, now: number): Landing
	local next_pending = pending
	local next_landed = landed
	for _, group in groups do
		if landed[group.id] then
			continue
		end
		next_landed = util.own(landed, next_landed)
		next_landed[group.id] = now
		if group.kind == "shared" then
			next_pending = util.own(pending, next_pending)
			next_pending[group.id] = { created = now, ops = group.ops }
		else
			state = ops.replay(state, group.ops)
		end
	end
	return { state = state, pending = next_pending, landed = next_landed }
end

local function prune_landed(landed: Landed, now: number, ttl: number): Landed
	local next_landed = landed
	for id, at in landed do
		if now - at > ttl then
			next_landed = util.own(landed, next_landed)
			next_landed[id] = nil
		end
	end
	return next_landed
end

local function prune_stamps(state: State, now: number, ttl: number): Stamps
	local stamps = state.stamps
	local next_stamps = stamps
	for stamp_key, at in stamps do
		local slash = string.find(stamp_key, "/", 1, true)
		if slash == nil or now - at <= ttl then
			continue
		end
		local path = string.split(string.sub(stamp_key, slash + 1), "/")
		if ops.resolve(state.truth, string.sub(stamp_key, 1, slash - 1), path, #path) == nil then
			next_stamps = util.own(stamps, next_stamps)
			next_stamps[stamp_key] = nil
		end
	end
	return next_stamps
end

local function build_record(self: SessionInternal, record: StoredRecord, landing: Landing, now: number): StoredRecord
	local config = self.internal_collection.config
	local next_landed = prune_landed(landing.landed, now, config.commit_timeout)
	return {
		data = landing.state.truth,
		stamps = prune_stamps(landing.state, now, config.commit_timeout),
		pending = if next(landing.pending) ~= nil then landing.pending else nil,
		landed = if next(next_landed) ~= nil then next_landed else nil,
		version = (record.version or 0) + 1,
		written = util.create_guid(),
		migrations = #config.migrations,
	}
end

local function merge(self: SessionInternal, old: StoredRecord?): Merge
	local groups = table.clone(self.internal_unwritten)
	for _, group in groups do
		group.coalesce = nil
	end
	local record: StoredRecord = old or {}
	local state = base_state(self, old)

	local seeded = old == nil and self.internal_seed ~= nil
	if seeded then
		state = { truth = table.clone(self.internal_seed :: Data), stamps = state.stamps }
	end

	local migrated = migrate_state(self, old, state, seeded)
	local resolution: Resolution = { truth = {}, stamps = {}, pending = {}, unknown = {}, decided = {} }
	if migrated.kind == "newer" then
		return { kind = "newer", message = migrated.message, groups = groups, resolution = resolution }
	end

	local original: Pending = record.pending or {}
	resolution = commit.resolve(migrated.state, original)

	local now = os.time()
	local landed = record.landed or {}
	local landing =
		land_groups({ truth = resolution.truth, stamps = resolution.stamps }, resolution.pending, landed, groups, now)

	local unchanged = landing.landed == landed
		and landing.pending == original
		and not migrated.migrated
		and not seeded
		and not (old ~= nil and record.version == nil)
	if unchanged then
		return { kind = "unchanged", groups = groups, resolution = resolution }
	end
	return {
		kind = "merged",
		record = build_record(self, record, landing, now),
		groups = groups,
		resolution = resolution,
	}
end

local function with_written(merged: Merge, record: StoredRecord?, written: boolean): PullResult
	if merged.kind == "newer" then
		return {
			kind = "newer",
			message = merged.message,
			groups = merged.groups,
			resolution = merged.resolution,
			written = written,
		}
	end
	return {
		kind = "merged",
		record = record,
		groups = merged.groups,
		resolution = merged.resolution,
		written = written,
	}
end

local function user_ids_of(collection: CollectionState, key: string): { number }?
	local user_ids = collection.config.user_ids
	if user_ids == nil then
		return nil
	end
	return user_ids(key)
end

local function run_update(self: SessionInternal, retry: RetryConfig): PullResult
	local collection = self.internal_collection
	local merged: Merge? = nil
	local result = datastore.update_async(collection.store, self.internal_values.key, function(old: StoredRecord?)
		local next_merge = merge(self, old)
		merged = next_merge
		if next_merge.kind == "merged" then
			return next_merge.record
		end
		return nil
	end, retry, user_ids_of(collection, self.internal_values.key))
	return with_written(merged :: Merge, result.value, result.written)
end

local function is_idle(self: SessionInternal): boolean
	return #self.internal_unwritten == 0 and self.internal_seed == nil and not self.internal_values.touched
end

local function run_read(self: SessionInternal, retry: RetryConfig): PullResult?
	local collection = self.internal_collection
	local record: StoredRecord? = datastore.get_async(collection.store, self.internal_values.key, retry)
	local declared = #collection.config.migrations
	if record ~= nil and (record.version == nil or (record.migrations or 0) < declared) then
		return nil
	end
	local merged = merge(self, record)
	if merged.kind == "merged" then
		return nil
	end
	return with_written(merged, record, false)
end

local function adopt(self: SessionInternal, pull: MergedPull): boolean
	local values = self.internal_values
	local record = pull.record
	forget_state(self)
	if record == nil then
		if values.version == 0 then
			return false
		end
		self.internal_base = empty_state()
		table.clear(self.internal_awaiting)
		values.version = 0
		values.written = nil
		return true
	end

	self.internal_seed = nil
	await_shared(self, forget_written(self, pull.groups))
	local adopted = pull.written or not same_record(self, record)
	if adopted then
		self.internal_base = state_of(record)
		values.version = record.version or 0
		values.written = record.written
	end
	forget_settled(self, record, pull.resolution.decided)
	return adopted
end

local function fetch_unknown(self: SessionInternal, pull: MergedPull): boolean
	local pending = pull.resolution.pending
	local any_decided = false
	for _, id in pull.resolution.unknown do
		local entry = pending[id]
		if commit.fetch(self.internal_collection.config, id, entry.created) ~= "undecided" then
			any_decided = true
		end
	end
	return any_decided
end

local function accept(self: SessionInternal, pull: PullResult): MergedPull
	if pull.kind == "newer" then
		close(self, { kind = "refused", message = pull.message })
		error(pull.message, 0)
	end
	return pull
end

local function pull_now(self: SessionInternal, retry: RetryConfig): boolean
	local first = if is_idle(self) then run_read(self, retry) else nil
	local pull = accept(self, first or run_update(self, retry))
	local adopted = adopt(self, pull)

	if fetch_unknown(self, pull) then
		pull = accept(self, run_update(self, retry))
		adopted = adopt(self, pull) or adopted
	end
	forget_state(self)

	if self.internal_values.closing and #self.internal_unwritten == 0 then
		close(self, { kind = "clean" })
	end
	return adopted
end

local function pull_with(self: SessionInternal, retry: RetryConfig): boolean
	validate_open(self)
	if not is_idle(self) or self.internal_values.closing then
		callbacks.fire(self.internal_hooks, hooks.writing, self)
		self.internal_values.touched = false
	end
	local adopted = false
	self.internal_mutex:with(function()
		adopted = pull_now(self, retry)
		self.internal_values.pulls += 1
	end)
	if adopted and self.internal_values.open then
		callbacks.fire(self.internal_hooks, hooks.pulled, self, get_truth(self))
	end
	return adopted
end

local function sync(self: SessionInternal): boolean
	return pull_with(self, self.internal_collection.config)
end

local function is_closed_clean(self: SessionInternal): boolean
	local closure = self.internal_values.closure
	return closure ~= nil and closure.kind == "clean" and #self.internal_unwritten == 0
end

local function unload(self: SessionInternal, retry: RetryConfig?)
	validate_open(self)
	if is_idle(self) and #self.internal_awaiting == 0 then
		close(self, { kind = "clean" })
		return
	end
	self.internal_values.closing = true
	local ok, err = pcall(pull_with, self, retry or self.internal_collection.config)
	if ok or is_closed_clean(self) or not self.internal_values.closing then
		return
	end
	error(err, 0)
end

local function reopen(self: SessionInternal)
	validate_open(self)
	self.internal_values.closing = false
end

local function wiped_record(old: StoredRecord?, declared: number): StoredRecord
	local now = os.time()
	local stamps: Stamps = {}
	if old then
		local data: Data = old.data or {}
		local previous: Stamps = old.stamps or {}
		for key in data do
			stamps[key] = now
		end
		for stamp_key, at in previous do
			local key = string.match(stamp_key, "^[^/]*")
			stamps[key] = math.max(stamps[key] or now, at + 1)
		end
	end
	return {
		data = {},
		stamps = stamps,
		version = ((old and old.version) or 0) + 1,
		written = util.create_guid(),
		migrations = declared,
	}
end

local function wipe_key(collection: CollectionState, key: string): StoredRecord
	local declared = #collection.config.migrations
	local result = datastore.update_async(collection.store, key, function(old: StoredRecord?)
		return wiped_record(old, declared)
	end, collection.config, user_ids_of(collection, key))
	return result.value :: StoredRecord
end

local function wipe(self: SessionInternal)
	validate_open(self)
	local values = self.internal_values
	self.internal_mutex:with(function()
		local record = wipe_key(self.internal_collection, values.key)
		table.clear(self.internal_unwritten)
		table.clear(self.internal_awaiting)
		self.internal_seed = nil
		values.touched = false
		self.internal_base = state_of(record)
		values.version = record.version or 0
		values.written = record.written
		forget_state(self)
	end)
end

local function hook(self: SessionInternal, hook_symbol: Symbol, callback: Callback): () -> ()
	return callbacks.connect(self.internal_hooks, hook_symbol, callback)
end

local function is_session(value: unknown): boolean
	return symbol.is_marked(value, session_symbol)
end

local template = {
	symbol = session_symbol,
	internal_values = {
		key = "",
		open = true,
		closing = false,
		closure = nil :: Closure?,
		version = 0,
		written = nil :: string?,
		pulls = 0,
		touched = false,
	},
	internal_collection = (nil :: any) :: CollectionState,
	internal_base = empty_state(),
	internal_migrate = (nil :: any) :: Migrate,
	internal_seed = nil :: Data?,
	internal_hooks = {},
	internal_mutex = (nil :: any) :: Mutex,
	internal_unwritten = {},
	internal_awaiting = {},
	internal_cache = nil :: State?,
	internal_before_last = nil :: State?,

	get_key = get_key,
	get_truth = get_truth,
	get_stamps = get_stamps,
	get_config = get_config,
	get_closure = get_closure,
	get_state = get_state,
	get_pulls = get_pulls,
	is_open = is_open,
	is_dirty = is_dirty,
	journal = journal,
	touch = touch,
	abandon = abandon,
	has_landed = has_landed,
	sync = sync,
	unload = unload,
	discard = discard,
	wipe = wipe,
	reopen = reopen,
	hook = hook,
}

local meta = {
	__tostring = function(self: SessionInternal)
		return `Session({self.internal_values.key})`
	end,
}

local function create_session(collection: CollectionState, key: string, migrate: Migrate): SessionInternal
	local session = table.clone(template)
	session.internal_values = table.clone(template.internal_values)
	session.internal_values.key = key
	session.internal_collection = collection
	session.internal_base = empty_state()
	session.internal_migrate = migrate
	session.internal_hooks = {}
	session.internal_mutex = mutex.create_mutex()
	session.internal_unwritten = {}
	session.internal_awaiting = {}
	setmetatable(session, meta)
	return session :: SessionInternal
end

local function load_session(collection: CollectionState, key: string, migrate: Migrate): SessionInternal
	local session = create_session(collection, key, migrate)
	local config = collection.config
	pull_now(session, config)
	if config.foreign and session.internal_values.version == 0 then
		session.internal_seed = foreign.read(config.foreign, key)
		if session.internal_seed ~= nil then
			pull_now(session, config)
		end
	end
	pull_loop.start(session)
	return session
end

return table.freeze({
	load_session = load_session,
	is_session = is_session,
	wipe_key = wipe_key,
})
