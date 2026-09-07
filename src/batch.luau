local types = require("./types")
local commit = require("./commit")
local contexts = require("./contexts")
local logging = require("./logging")
local messages = require("./messages")
local ops = require("./ops")
local relations = require("./relations")
local state = require("./state")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type Capture = types.Capture
type CaptureEntry = types.CaptureEntry
type Context = types.Context
type ResolvedCollectionConfig = types.ResolvedCollectionConfig
type Undo = types.Undo

local function still_ours(context: Context, undo: Undo): boolean
	local world = context.world
	if undo.kind == "component" then
		return world:get(undo.entity, undo.id) == undo.value
	end
	if undo.kind == "relation" then
		local packed =
			relations.pack(world, undo.entry, undo.entity, nil, context.schema.named, context.world_state.warned)
		return ops.deep_equal(packed, undo.value)
	end
	return world:has(undo.entity, undo.id) ~= undo.present
end

local function undo_one(context: Context, undo: Undo)
	local world = context.world
	if undo.kind == "relation" then
		relations.apply(
			world,
			undo.entry,
			undo.entity,
			context.schema.named,
			undo.previous or {},
			context.world_state.warned
		)
		return
	end
	if undo.kind == "tag" or undo.kind == "pair" then
		if undo.present then
			world:add(undo.entity, undo.id)
		else
			world:remove(undo.entity, undo.id)
		end
	elseif undo.previous ~= nil then
		world:set(undo.entity, undo.id, undo.previous)
	else
		world:remove(undo.entity, undo.id)
	end
end

local function applied_id(undo: Undo): Entity<any>?
	if undo.kind == "pair" then
		return nil
	end
	if undo.kind == "relation" then
		return undo.entry.id
	end
	return undo.id
end

local function undo_all(context: Context, capture: Capture): { [Entity]: boolean }
	local world, world_state = context.world, context.world_state
	local touched: { [Entity]: boolean } = {}
	for index = #capture.undo, 1, -1 do
		local undo = capture.undo[index]
		if not world:contains(undo.entity) or not still_ours(context, undo) then
			continue
		end
		touched[undo.entity] = true
		state.with_applying(world_state, undo.entity, applied_id(undo), function()
			undo_one(context, undo)
		end)
	end
	return touched
end

local function rollback(context: Context, capture: Capture)
	for entity in undo_all(context, capture) do
		state.entity_state(context.world_state, entity).shadow =
			state.read_values(context, entity, context.schema.entries)
	end
end

local function pull_all(entries: { CaptureEntry })
	util.join_all(entries, function(entry)
		entry.session:sync()
	end)
end

local function open_entries(entries: { CaptureEntry }): { CaptureEntry }
	local open: { CaptureEntry } = {}
	for _, entry in entries do
		if entry.session:is_open() then
			table.insert(open, entry)
		end
	end
	return open
end

local function settle(entries: { CaptureEntry }, id: string)
	task.spawn(function()
		local settled, err = pcall(pull_all, open_entries(entries))
		if not settled and #open_entries(entries) > 0 then
			logging.warn(messages.warnings.settle_failed(id, err))
		end
	end)
end

local function abandon_all(entries: { CaptureEntry }, id: string)
	for _, entry in open_entries(entries) do
		entry.session:abandon(id)
	end
end

local function shared_config(entries: { CaptureEntry }, id: string): ResolvedCollectionConfig
	local first = entries[1].session:get_config()
	for _, entry in entries do
		local config = entry.session:get_config()
		if
			config.data_store_service ~= first.data_store_service
			or config.commit_store ~= first.commit_store
			or config.commit_timeout ~= first.commit_timeout
		then
			error(messages.errors.batch_mixed_stores(id), 0)
		end
	end
	return first
end

local function fail(context: Context, capture: Capture, id: string, err: unknown)
	abandon_all(capture.entries, id)
	rollback(context, capture)
	error(err, 0)
end

local function commit_single(context: Context, capture: Capture, entry: CaptureEntry)
	local session = entry.session
	local id = util.create_guid()
	local ok, err = pcall(function()
		session:journal({ id = id, ops = entry.ops, kind = "single" })
		session:sync()
	end)
	if ok then
		return
	end
	if session:has_landed(id) then
		session:abandon(id)
		settle(capture.entries, id)
		return
	end
	fail(context, capture, id, err)
end

local function mark_or_confirm(config: ResolvedCollectionConfig, id: string, created: number)
	local ok, err = pcall(commit.mark, config, id)
	if ok or commit.fetch(config, id, created) == "committed" then
		return
	end
	error(err, 0)
end

local function commit_shared(context: Context, capture: Capture)
	local entries = capture.entries
	local id = util.create_guid()
	local created = os.time()

	local ok, err = pcall(function()
		local config = shared_config(entries, id)
		util.run_all(entries, function(entry)
			entry.session:journal({ id = id, ops = entry.ops, kind = "shared" })
		end)
		pull_all(entries)
		if os.time() - created >= config.commit_timeout / 2 then
			error(messages.errors.batch_expired(id), 0)
		end
		mark_or_confirm(config, id, created)
	end)
	if not ok then
		fail(context, capture, id, err)
	end
	settle(entries, id)
end

local function commit_capture(context: Context, capture: Capture)
	local entries = capture.entries
	if #entries == 0 then
		return
	end
	if #entries == 1 then
		commit_single(context, capture, entries[1])
		return
	end
	commit_shared(context, capture)
end

local function run(world: World, fn: () -> (), is_delta: boolean)
	local world_state = state.get(world)
	local outer = world_state.capture
	if outer then
		local was_delta = outer.delta
		outer.delta = was_delta or is_delta
		local ok, err = pcall(fn)
		outer.delta = was_delta
		if not ok then
			error(err, 0)
		end
		return
	end

	local context = contexts.create_context(world)
	local capture: Capture = { delta = is_delta, undo = {}, entries = {} }
	world_state.capture = capture
	local ok, err = pcall(fn)
	world_state.capture = nil
	if not ok then
		rollback(context, capture)
		error(err, 0)
	end
	commit_capture(context, capture)
end

local function batch(world: World, fn: () -> ())
	run(world, fn, false)
end

local function delta(world: World, fn: () -> ())
	run(world, fn, true)
end

return table.freeze({
	batch = batch,
	delta = delta,
})
