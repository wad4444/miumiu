local types = require("./types")
local callbacks = require("./callbacks")
local commit = require("./commit")
local datastore = require("./datastore")
local foreign = require("./foreign")
local hooks = require("./hooks")
local logging = require("./logging")
local messages = require("./messages")
local mutex = require("./mutex")
local ops = require("./ops")
local pull_loop = require("./pull_loop")
local rankings = require("./rankings")
local symbol = require("./symbol")
local util = require("./util")

type Callback = types.Callback
type Entity<T = nil> = types.Entity<T>
type Claim = types.Claim
type Closure = types.Closure
type CollectionState = types.CollectionState
type Data = types.Data
type Group = types.Group
type Landed = types.Landed
type Landing = types.Landing
type Merge = types.Merge
type Migrate = types.Migrate
type Migrated = types.Migrated
type Mutex = types.Mutex
type Op = types.Op
type Pending = types.Pending
type Owed = types.Owed
type Periods = types.Periods
type Placing = types.Placing
type Pull = types.Pull
type Push = types.Push
type Resolution = types.Resolution
type ResolvedCollectionConfig = types.ResolvedCollectionConfig
type RetryConfig = types.RetryConfig
type SessionInternal = types.SessionInternal
type SessionStatus = types.SessionStatus
type SettledOutcome = types.SettledOutcome
type Stamps = types.Stamps
type State = types.State
type StoredRecord = types.StoredRecord
type Symbol = types.Symbol
type Watcher = types.Watcher

local session_symbol = symbol.create_symbol("Session")
local record_format = 1

local function empty_state(): State
	return { truth = {}, stamps = {} }
end

local function number_or(value: any, fallback: number): number
	return if type(value) == "number" then value else fallback
end

local function stamps_of(record: StoredRecord): Stamps
	local stored = record.stamps
	if type(stored) ~= "table" then
		return {}
	end

	local stamps: Stamps = {}
	for key, at in stored do
		if type(key) == "string" and type(at) == "number" then
			stamps[key] = at
		end
	end

	return stamps
end

local function table_or_empty(value: any): any
	return if type(value) == "table" then value else {}
end

local function state_of(record: StoredRecord): State
	return { truth = if type(record.data) == "table" then record.data else {}, stamps = stamps_of(record) }
end

local function validate_open(self: SessionInternal)
	if self.internal_values.status.kind == "closed" then
		error(messages.errors.session_closed(self.internal_values.key), 0)
	end
end

local function has_landed(self: SessionInternal, id: string): boolean
	local collection = self.internal_collection
	local ok, record = pcall(datastore.get_async, collection.store, self.internal_values.key, collection.config)
	return ok and type(record) == "table" and type(record.landed) == "table" and record.landed[id] ~= nil
end

local function fire_landed(self: SessionInternal)
	local landed = self.internal_landed
	if #landed == 0 then
		return
	end

	self.internal_landed = {}
	local watchers = self.internal_watchers
	for _, id in landed do
		local watcher = watchers[id]
		if watcher then
			watchers[id] = nil
			watcher({ kind = "landed" })
		end
	end
end

local function refuse_watched(self: SessionInternal, message: string)
	local watchers = self.internal_watchers
	self.internal_watchers = {}
	for _, watcher in watchers do
		watcher({ kind = "refused", message = message })
	end
end

local function resolve_watched(self: SessionInternal, message: string)
	local watchers = self.internal_watchers
	if next(watchers) == nil then
		return
	end

	self.internal_watchers = {}
	local collection = self.internal_collection
	local ok, record = pcall(datastore.get_async, collection.store, self.internal_values.key, collection.config)
	local landed = if ok and type(record) == "table" and type(record.landed) == "table" then record.landed else {}
	for id, watcher in watchers do
		if landed[id] ~= nil then
			watcher({ kind = "landed" })
		else
			watcher({ kind = "refused", message = message })
		end
	end
end

local function settle_watched(self: SessionInternal)
	fire_landed(self)
	local status = self.internal_values.status
	if status.kind ~= "closed" then
		return
	end

	local closure = status.closure
	if closure.kind ~= "clean" then
		resolve_watched(self, closure.message)
	end
end

local function close(self: SessionInternal, closure: Closure)
	local values = self.internal_values
	if values.status.kind == "closed" then
		return
	end
	values.status = table.freeze({ kind = "closed", closure = table.freeze(closure) })
	local deferred = self.internal_mutex:is_locked()
	self.internal_mutex:close(messages.errors.session_closed(values.key))
	if not deferred then
		fire_landed(self)
		if closure.kind ~= "clean" then
			refuse_watched(self, closure.message)
		end
	end

	callbacks.fire(self.internal_hooks, hooks.closed, self, closure)
end

local function discard(self: SessionInternal, message: string)
	close(self, { kind = "abandoned", message = message })
end

local function get_collection(self: SessionInternal): Entity
	return self.internal_collection.entity
end

local function get_key(self: SessionInternal): string
	return self.internal_values.key
end

local function get_config(self: SessionInternal): ResolvedCollectionConfig
	return self.internal_collection.config
end

local function get_status(self: SessionInternal): SessionStatus
	return self.internal_values.status
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
	return self.internal_values.status.kind ~= "closed"
end

local function is_dirty(self: SessionInternal): boolean
	return #self.internal_unwritten > 0 or self.internal_values.touched
end

local function touch(self: SessionInternal)
	validate_open(self)
	self.internal_values.touched = true
end

local function floor_of(state: State, op: Op, resets: { [string]: number }): number
	local reset = resets[op.key] or 0
	if op.kind == "set" or op.kind == "remove" then
		return math.max(state.stamps[op.key] or 0, reset)
	end

	if op.kind == "put" or op.kind == "drop" then
		return math.max(ops.path_floor(state.stamps, op.key, op.path), reset)
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

local function stamp_after(state: State, group_ops: { Op }, resets: { [string]: number }): { Op }
	local adjusted: { Op } = {}
	for _, op in group_ops do
		local stamped = bump(op, floor_of(state, op, resets))
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
	for index = #unwritten, 1, -1 do
		if unwritten[index].coalesce == coalesce then
			return index
		end
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
		local was_last = slot == #self.internal_unwritten
		table.remove(self.internal_unwritten, slot)
		local before_last = self.internal_before_last
		if was_last and before_last then
			base = before_last
		else
			forget_state(self)
			base = get_state(self)
		end
	else
		base = get_state(self)
	end

	local adjusted = stamp_after(base, group.ops, self.internal_resets)
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

local function watch(self: SessionInternal, id: string, watcher: Watcher)
	self.internal_watchers[id] = watcher
end

local function drop_group(self: SessionInternal, id: string)
	remove_group(self.internal_unwritten, id)
	remove_group(self.internal_awaiting, id)
	self.internal_watchers[id] = nil
	forget_state(self)
end

local function resolve_group(self: SessionInternal, id: string, message: string): SettledOutcome
	local outcome: SettledOutcome = { kind = "refused", message = message }
	self.internal_mutex:with(function()
		if has_landed(self, id) then
			outcome = { kind = "landed" }
		end
		remove_group(self.internal_unwritten, id)
		forget_state(self)
	end)
	self.internal_watchers[id] = nil
	if self.internal_values.status.kind == "closed" then
		settle_watched(self)
	end

	return outcome
end

local function forget_written(self: SessionInternal, written: { Group }): { Group }
	local unwritten = self.internal_unwritten
	local removed: { Group } = {}
	for _, group in written do
		local index = table.find(unwritten, group)
		if index then
			table.remove(unwritten, index)
			table.insert(removed, group)
			if self.internal_watchers[group.id] then
				table.insert(self.internal_landed, group.id)
			end
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

	local pending = table_or_empty(record.pending)
	local awaiting = self.internal_awaiting
	for index = #awaiting, 1, -1 do
		if pending[awaiting[index].id] == nil then
			table.remove(awaiting, index)
		end
	end
end

local function is_same_record(self: SessionInternal, old: StoredRecord): boolean
	local values = self.internal_values
	if not values.adopted then
		return false
	end

	if old.written ~= nil or values.written ~= nil then
		return old.written == values.written
	end

	return old.version == values.version
end

local function base_state(self: SessionInternal, old: StoredRecord?): State
	if old == nil then
		return if self.internal_values.adopted then empty_state() else self.internal_base
	end

	if is_same_record(self, old) then
		return self.internal_base
	end

	return state_of(old)
end

local function applied_migrations(self: SessionInternal, old: StoredRecord?, seeded: boolean): number
	if old then
		return number_or(old.migrations, 0)
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
			kind = "migrated",
			state = { truth = self.internal_migrate(state.truth, applied), stamps = state.stamps },
		}
	end

	return { kind = "unchanged", state = state }
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
		if type(at) ~= "number" or now - at > ttl then
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
	local next_record = table.clone(record)
	next_record.data = landing.state.truth
	next_record.stamps = prune_stamps(landing.state, now, config.commit_timeout)
	next_record.pending = if next(landing.pending) ~= nil then landing.pending else nil
	next_record.landed = if next(next_landed) ~= nil then next_landed else nil
	next_record.version = number_or(record.version, 0) + 1
	next_record.written = util.create_guid()
	next_record.migrations = #config.migrations
	next_record.format = record_format
	return next_record
end

local function claim_of(self: SessionInternal): Claim?
	local values = self.internal_values
	if values.status.kind ~= "open" then
		return nil
	end

	local collection = self.internal_collection
	return { id = collection.holder, timeout = collection.config.commit_timeout, receiving = self.internal_receiving() }
end

local function merge(self: SessionInternal, old: StoredRecord?): Merge
	local groups = table.clone(self.internal_unwritten)
	for _, group in groups do
		group.coalesce = nil
	end

	local record: StoredRecord = table_or_empty(old)
	local resolution: Resolution = { truth = {}, stamps = {}, pending = {}, unknown = {}, decided = {} }
	if number_or(record.format, record_format) > record_format then
		local message = messages.errors.newer_format(self.internal_values.key, record.format :: number, record_format)
		return { kind = "newer", message = message, groups = groups, resolution = resolution }
	end

	local state = base_state(self, old)

	local seeded = old == nil and self.internal_seed ~= nil
	if seeded then
		state = { truth = table.clone(self.internal_seed :: Data), stamps = state.stamps }
	end

	local migrated = migrate_state(self, old, state, seeded)
	if migrated.kind == "newer" then
		return { kind = "newer", message = migrated.message, groups = groups, resolution = resolution }
	end

	local original: Pending = table_or_empty(record.pending)
	resolution = commit.resolve(migrated.state, original)

	local now = os.time()
	local landed: Landed = table_or_empty(record.landed)
	local landing =
		land_groups({ truth = resolution.truth, stamps = resolution.stamps }, resolution.pending, landed, groups, now)
	local rolled = rankings.roll(landing.state, self.internal_collection.ordered, now, claim_of(self))
	landing.state = rolled.state

	local unchanged = landing.landed == landed
		and landing.pending == original
		and migrated.kind == "unchanged"
		and not seeded
		and not (old ~= nil and type(record.version) ~= "number")
		and #rolled.ops == 0
	if unchanged then
		return { kind = "unchanged", groups = groups, resolution = resolution }
	end

	return {
		kind = "merged",
		record = build_record(self, record, landing, now),
		groups = groups,
		resolution = resolution,
		pushes = rolled.pushes,
		resets = rolled.resets,
	}
end

local function user_ids_of(collection: CollectionState, key: string): { number }?
	local user_ids = collection.config.user_ids
	if user_ids == nil then
		return nil
	end

	return user_ids(key)
end

local function run_update(self: SessionInternal, retry: RetryConfig): Pull
	local collection = self.internal_collection
	local merged: Merge? = nil
	local pushes: { [string]: Push } = {}
	local result = datastore.update_async(collection.store, self.internal_values.key, function(old: StoredRecord?)
		local next_merge = merge(self, old)
		merged = next_merge
		if next_merge.kind == "merged" then
			for _, push in next_merge.pushes do
				pushes[push.name] = push
			end
			for key, at in next_merge.resets do
				self.internal_resets[key] = math.max(self.internal_resets[key] or 0, at)
			end
			return next_merge.record
		end

		return nil
	end, retry, user_ids_of(collection, self.internal_values.key))
	return {
		merge = merged :: Merge,
		record = result.value,
		wrote = result.kind == "written",
		pushes = pushes,
	}
end

local function is_idle(self: SessionInternal): boolean
	return #self.internal_unwritten == 0 and self.internal_seed == nil and not self.internal_values.touched
end

local function run_read(self: SessionInternal, retry: RetryConfig): Pull?
	local collection = self.internal_collection
	local record: StoredRecord? = datastore.get_async(collection.store, self.internal_values.key, retry)
	local declared = #collection.config.migrations
	if record ~= nil and (type(record.version) ~= "number" or number_or(record.migrations, 0) < declared) then
		return nil
	end

	local read_state = if record then state_of(record) else empty_state()
	if #rankings.roll(read_state, collection.ordered, os.time(), claim_of(self)).ops > 0 then
		return nil
	end

	local merged = merge(self, record)
	if merged.kind == "merged" then
		return nil
	end

	return { merge = merged, record = record, wrote = false, pushes = {} }
end

local function adopt_record(self: SessionInternal, record: StoredRecord)
	local values = self.internal_values
	self.internal_base = state_of(record)
	values.adopted = true
	values.version = if type(record.version) == "number" then record.version else 0
	values.written = record.written
end

local function adopt(self: SessionInternal, pull: Pull): boolean
	local values = self.internal_values
	local record = pull.record
	forget_state(self)
	if record == nil then
		if not values.adopted then
			return false
		end

		self.internal_base = empty_state()
		table.clear(self.internal_awaiting)
		values.adopted = false
		values.version = 0
		values.written = nil
		return true
	end

	self.internal_seed = nil
	await_shared(self, forget_written(self, pull.merge.groups))
	local adopted = pull.wrote or not is_same_record(self, record)
	if adopted then
		adopt_record(self, record)
	end
	forget_settled(self, record, pull.merge.resolution.decided)
	return adopted
end

local function fetch_unknown(self: SessionInternal, pull: Pull, retry: RetryConfig): boolean
	local resolution = pull.merge.resolution
	local pending = resolution.pending
	local any_decided = false
	for _, id in resolution.unknown do
		local entry = pending[id]
		if commit.fetch(self.internal_collection.config, retry, id, entry.created) ~= "undecided" then
			any_decided = true
		end
	end

	return any_decided
end

local function accept(self: SessionInternal, pull: Pull): Pull
	local merge = pull.merge
	if merge.kind == "newer" then
		close(self, { kind = "refused", message = merge.message })
		error(merge.message, 0)
	end

	return pull
end

local function queue_pushes(self: SessionInternal, pull: Pull)
	for name, push in pull.pushes do
		self.internal_pushes[name] = push
	end
end

local function push_scores(self: SessionInternal, retry: RetryConfig)
	local values = self.internal_values
	local config = self.internal_collection.config
	local key = values.key
	local failed_name: string? = nil
	local failure: any = nil
	for name, push in self.internal_pushes do
		local ok, err = pcall(rankings.push_one, config, retry, key, push)
		if ok then
			self.internal_pushes[name] = nil
		elseif failed_name == nil then
			failed_name = name
			failure = err
		end
	end

	if failed_name ~= nil then
		if not values.push_failing then
			values.push_failing = true
			logging.warn(messages.warnings.push_failed(key, failed_name, failure))
		end

		return
	end

	if values.push_failing then
		values.push_failing = false
		logging.warn(messages.warnings.push_recovered(key))
	end
end

local function settle_owed(self: SessionInternal, name: string, owed: Owed, placing: Placing)
	self.internal_placings[name] = nil
	journal(self, {
		id = util.create_guid(),
		ops = { rankings.field_op(get_state(self), name, "owed", rankings.remaining(owed, placing.last), os.time()) },
		kind = "single",
	})
end

local function resolve_owed(self: SessionInternal, retry: RetryConfig)
	local collection = self.internal_collection
	local values = self.internal_values
	local truth = get_truth(self)
	local now = os.time()
	if values.status.kind ~= "open" then
		return
	end

	local claim = claim_of(self)

	for _, store in collection.ordered do
		local name = store.name
		local owed = rankings.owed_of(truth, name)
		if owed == nil then
			self.internal_placings[name] = nil
			continue
		end

		if claim == nil or not rankings.is_held(owed, claim, now) then
			self.internal_placings[name] = nil
			continue
		end

		local held = owed
		local current = rankings.current_period(store, now)
		if current.kind ~= "period" then
			continue
		end

		local covered = rankings.covered_last(store, held, current.period, now)
		local failed = self.internal_failed_changes[name]
		if failed ~= nil and failed.from == held.from and failed.last == covered then
			continue
		end

		local cached = self.internal_placings[name]
		if cached and cached.from == held.from and cached.last == covered then
			continue
		end

		local ok, placing =
			pcall(rankings.resolve, collection.config, retry, store, values.key, held, current.period, now)
		if not ok then
			if not values.top_failing then
				values.top_failing = true
				logging.warn(messages.warnings.top_failed(values.key, name, placing))
			end
			continue
		end
		values.top_failing = false
		if #placing.periods == 0 then
			settle_owed(self, name, held, placing)
			continue
		end

		self.internal_placings[name] = placing
	end
end

local function pull_now(self: SessionInternal, retry: RetryConfig): boolean
	local first = if is_idle(self) then run_read(self, retry) else nil
	local pull = accept(self, first or run_update(self, retry))
	local adopted = adopt(self, pull)
	queue_pushes(self, pull)

	if fetch_unknown(self, pull, retry) then
		pull = accept(self, run_update(self, retry))
		adopted = adopt(self, pull) or adopted
		queue_pushes(self, pull)
	end
	forget_state(self)
	table.clear(self.internal_resets)
	push_scores(self, retry)
	resolve_owed(self, retry)

	if self.internal_values.status.kind == "closing" and #self.internal_unwritten == 0 then
		close(self, { kind = "clean" })
	end

	return adopted
end

local function pull_with(self: SessionInternal, retry: RetryConfig): boolean
	validate_open(self)
	local values = self.internal_values
	if not is_idle(self) or values.status.kind == "closing" then
		local prepare = values.prepare
		if prepare then
			callbacks.invoke(hooks.writing, self, prepare)
		end
		values.touched = false
		if values.status.kind == "closing" and is_idle(self) then
			close(self, { kind = "clean" })
			return false
		end
		callbacks.fire(self.internal_hooks, hooks.writing, self)
	end

	local adopted = false
	local entered = false
	local ok, err = pcall(self.internal_mutex.with, self.internal_mutex, function()
		entered = true
		adopted = pull_now(self, retry)
		values.pulls += 1
	end)
	if entered then
		settle_watched(self)
	end

	if not ok then
		error(err, 0)
	end

	if adopted and values.status.kind ~= "closed" then
		callbacks.fire(self.internal_hooks, hooks.pulled, self, get_truth(self))
	end

	return adopted
end

local function sync(self: SessionInternal): boolean
	return pull_with(self, self.internal_collection.config)
end

local function is_closed_clean(self: SessionInternal): boolean
	local status = self.internal_values.status
	return status.kind == "closed" and status.closure.kind == "clean" and #self.internal_unwritten == 0
end

local function unload(self: SessionInternal, retry: RetryConfig?)
	validate_open(self)
	if is_idle(self) then
		if next(self.internal_pushes) ~= nil then
			self.internal_mutex:with(function()
				push_scores(self, retry or self.internal_collection.config)
			end)
		end

		if is_idle(self) then
			close(self, { kind = "clean" })
			return
		end
	end

	self.internal_values.status = table.freeze({ kind = "closing" })
	local ok, err = pcall(pull_with, self, retry or self.internal_collection.config)
	if ok or is_closed_clean(self) or self.internal_values.status.kind == "open" then
		return
	end
	error(err, 0)
end

local function reopen(self: SessionInternal)
	validate_open(self)
	self.internal_values.status = table.freeze({ kind = "open" })
end

local function prepare_with(self: SessionInternal, fn: (() -> ())?)
	self.internal_values.prepare = fn
end

local function wiped_record(old: StoredRecord?, declared: number): StoredRecord
	local now = os.time()
	local stamps: Stamps = {}
	if old then
		local data: Data = table_or_empty(old.data)
		local previous: Stamps = stamps_of(old)
		for key in data do
			stamps[key] = now
		end

		for stamp_key, at in previous do
			local key = string.match(stamp_key, "^[^/]*")
			stamps[key] = math.max(stamps[key] or now, at + 1)
		end
	end

	local wiped: StoredRecord = table.clone(table_or_empty(old))
	wiped.data = {}
	wiped.stamps = stamps
	wiped.pending = nil
	wiped.landed = nil
	wiped.version = number_or(old and old.version, 0) + 1
	wiped.written = util.create_guid()
	wiped.migrations = declared
	wiped.format = record_format
	return wiped
end

local function wipe_key(collection: CollectionState, key: string): StoredRecord
	local declared = #collection.config.migrations
	local periods: Periods = {}
	local result = datastore.update_async(collection.store, key, function(old: StoredRecord?)
		periods = rankings.periods_of(if old then old.data or {} else {})
		return wiped_record(old, declared)
	end, collection.config, user_ids_of(collection, key))
	rankings.unrank(collection.config, collection.config, collection.ordered, key, os.time(), periods)
	return result.value :: StoredRecord
end

local function wipe(self: SessionInternal)
	validate_open(self)
	local values = self.internal_values
	self.internal_mutex:with(function()
		local record = wipe_key(self.internal_collection, values.key)
		table.clear(self.internal_unwritten)
		table.clear(self.internal_awaiting)
		table.clear(self.internal_pushes)
		table.clear(self.internal_resets)
		table.clear(self.internal_placings)
		table.clear(self.internal_failed_changes)
		self.internal_seed = nil
		values.touched = false
		adopt_record(self, record)
		forget_state(self)
	end)
	fire_landed(self)
	refuse_watched(self, messages.errors.record_wiped(values.key))
end

local function get_placings(self: SessionInternal): { [string]: Placing }
	return self.internal_placings
end

local function forget_placing(self: SessionInternal, name: string, placing: Placing, failed: boolean)
	self.internal_placings[name] = nil
	if failed then
		self.internal_failed_changes[name] = { from = placing.from, last = placing.last }
	end
end

local function hook(self: SessionInternal, hook_symbol: Symbol, callback: Callback): () -> ()
	if
		hook_symbol ~= (hooks.pulled :: any)
		and hook_symbol ~= (hooks.closed :: any)
		and hook_symbol ~= (hooks.writing :: any)
	then
		error(messages.errors.hook_unknown(tostring(hook_symbol), "hooks.pulled, hooks.closed or hooks.writing"), 0)
	end

	return callbacks.connect(self.internal_hooks, hook_symbol, callback)
end

local function is_session(value: unknown): boolean
	return symbol.is_marked(value, session_symbol)
end

local template = {
	symbol = session_symbol,
	internal_values = {
		key = "",
		adopted = false,
		status = table.freeze({ kind = "open" }) :: SessionStatus,
		version = 0,
		written = nil :: string?,
		pulls = 0,
		touched = false,
		prepare = nil :: (() -> ())?,
		push_failing = false,
		top_failing = false,
	},
	internal_collection = (nil :: any) :: CollectionState,
	internal_receiving = function()
		return true
	end,
	internal_pushes = {},
	internal_resets = {},
	internal_placings = {},
	internal_failed_changes = {},
	internal_base = empty_state(),
	internal_migrate = (nil :: any) :: Migrate,
	internal_seed = nil :: Data?,
	internal_hooks = {},
	internal_mutex = (nil :: any) :: Mutex,
	internal_unwritten = {},
	internal_awaiting = {},
	internal_watchers = {},
	internal_landed = {},
	internal_cache = nil :: State?,
	internal_before_last = nil :: State?,

	get_collection = get_collection,
	get_key = get_key,
	get_truth = get_truth,
	get_stamps = get_stamps,
	get_config = get_config,
	get_status = get_status,
	get_state = get_state,
	get_pulls = get_pulls,
	is_open = is_open,
	is_dirty = is_dirty,
	journal = journal,
	touch = touch,
	watch = watch,
	drop_group = drop_group,
	resolve_group = resolve_group,
	sync = sync,
	unload = unload,
	discard = discard,
	wipe = wipe,
	reopen = reopen,
	prepare_with = prepare_with,
	hook = hook,
	get_placings = get_placings,
	forget_placing = forget_placing,
}

local meta = {
	__tostring = function(self: SessionInternal)
		return `Session({self.internal_values.key})`
	end,
}

local function create_session(
	collection: CollectionState,
	key: string,
	migrate: Migrate,
	receiving: (() -> boolean)?
): SessionInternal
	local session = table.clone(template)
	session.internal_values = table.clone(template.internal_values)
	session.internal_values.key = key
	session.internal_collection = collection
	session.internal_receiving = receiving or session.internal_receiving
	session.internal_base = empty_state()
	session.internal_migrate = migrate
	session.internal_hooks = {}
	session.internal_mutex = mutex.create_mutex()
	session.internal_unwritten = {}
	session.internal_awaiting = {}
	session.internal_watchers = {}
	session.internal_landed = {}
	session.internal_pushes = {}
	session.internal_resets = {}
	session.internal_placings = {}
	session.internal_failed_changes = {}
	setmetatable(session, meta)
	return session :: SessionInternal
end

local function load_session(
	collection: CollectionState,
	key: string,
	migrate: Migrate,
	receiving: (() -> boolean)?
): SessionInternal
	local session = create_session(collection, key, migrate, receiving)
	local config = collection.config
	pull_now(session, config)
	if config.foreign and not session.internal_values.adopted then
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
