local types = require("./types")
local datastore = require("./datastore")
local logging = require("./logging")
local messages = require("./messages")
local ops = require("./ops")
local util = require("./util")

type CommitKnown = types.CommitKnown
type CommitStatus = types.CommitStatus
type DataStore = types.DataStore
type DataStoreService = types.DataStoreService
type Pending = types.Pending
type Resolution = types.Resolution
type RetryConfig = types.RetryConfig
type ResolvedCollectionConfig = types.ResolvedCollectionConfig
type State = types.State

local cache: { [string]: CommitKnown } = {}
local stores = setmetatable({} :: { [DataStoreService]: { [string]: DataStore } }, { __mode = "k" })

local function get_store(config: ResolvedCollectionConfig): DataStore
	return util.cached(stores, config.data_store_service, config.commit_store, function()
		return datastore.open(config.data_store_service, config.commit_store)
	end)
end

local function remember(id: string, committed: boolean)
	cache[id] = { committed = committed, at = os.time() }
end

local function prune(config: ResolvedCollectionConfig)
	local now = os.time()
	for id, known in cache do
		if now - known.at > config.commit_timeout * 2 then
			cache[id] = nil
		end
	end
end

local function get_status(id: string): CommitStatus
	local known = cache[id]
	if known == nil then
		return "unknown"
	end

	return if known.committed then "committed" else "failed"
end

local function fetch(config: ResolvedCollectionConfig, retry: RetryConfig, id: string, created: number): CommitStatus
	local known = get_status(id)
	if known ~= "unknown" then
		return known
	end
	prune(config)

	local ok, result = pcall(function()
		return datastore.get_async(get_store(config), id, retry)
	end)
	if not ok then
		logging.warn(messages.warnings.commit_lookup_failed(id, result))
		return "undecided"
	end

	if result then
		remember(id, true)
		return "committed"
	end

	if type(created) ~= "number" or os.time() - created >= config.commit_timeout then
		remember(id, false)
		return "failed"
	end

	return "undecided"
end

local function mark(config: ResolvedCollectionConfig, id: string)
	prune(config)
	datastore.set_async(get_store(config), id, true, datastore.single_attempt)
	remember(id, true)
end

local function is_op_list(ops: any): boolean
	if type(ops) ~= "table" then
		return false
	end

	for _, op in ops do
		if type(op) ~= "table" or type(op.kind) ~= "string" then
			return false
		end
	end

	return true
end

local function resolve(state: State, pending: Pending): Resolution
	local next_pending = pending
	local unknown: { string } = {}
	local decided: { string } = {}

	for id, entry in pending do
		if type(entry) ~= "table" or not is_op_list(entry.ops) then
			next_pending = util.own(pending, next_pending)
			next_pending[id] = nil
			continue
		end

		local known = get_status(id)
		if known == "unknown" then
			table.insert(unknown, id)
			continue
		end

		if known == "committed" then
			state = ops.replay(state, entry.ops)
		end
		next_pending = util.own(pending, next_pending)
		next_pending[id] = nil
		table.insert(decided, id)
	end

	return { truth = state.truth, stamps = state.stamps, pending = next_pending, unknown = unknown, decided = decided }
end

return table.freeze({
	fetch = fetch,
	mark = mark,
	resolve = resolve,
})
