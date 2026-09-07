local types = require("./types")
local children = require("./children")
local codec = require("./codec")
local commit = require("./commit")
local contexts = require("./contexts")
local handle = require("./handle")
local logging = require("./logging")
local messages = require("./messages")
local ops = require("./ops")
local reconcile = require("./reconcile")
local relations = require("./relations")
local state = require("./state")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type Batch = types.Batch
type Capture = types.Capture
type CaptureEntry = types.CaptureEntry
type ChildKind = types.ChildKind
type Context = types.Context
type Data = types.Data
type ResolvedCollectionConfig = types.ResolvedCollectionConfig
type SchemaEntry = types.SchemaEntry
type Undo = types.Undo

local function child_fields(context: Context, entity: Entity, kind: ChildKind): Data
	return children.pack_fields(
		context.world,
		context.world_state.entities,
		entity,
		kind.entries,
		context.schema.named,
		context.world_state.warned
	)
end

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
	if undo.kind == "child" then
		return undo.value == nil or ops.deep_equal(child_fields(context, undo.entity, undo.child), undo.value)
	end
	return world:has(undo.entity, undo.id) ~= undo.present
end

local function restore_entry(context: Context, entity: Entity, entry: SchemaEntry, stored: any)
	local world = context.world
	if entry.kind == "tag" then
		if stored == true then
			world:add(entity, entry.id)
		else
			world:remove(entity, entry.id)
		end
	elseif entry.kind == "relation" then
		relations.apply(world, entry, entity, context.schema.named, stored or {}, context.world_state.warned)
	elseif stored == nil then
		world:remove(entity, entry.id)
	else
		world:set(entity, entry.id, codec.runtime_form(entry, stored))
	end
end

local function repair_child(context: Context, entity: Entity, kind: ChildKind, previous: Data, value: Data)
	local current = child_fields(context, entity, kind)
	local entries: { SchemaEntry } = kind.entries
	for _, entry in entries do
		local key = entry.key
		if ops.deep_equal(current[key], value[key]) and not ops.deep_equal(value[key], previous[key]) then
			restore_entry(context, entity, entry, previous[key])
		end
	end
end

local function undo_one(context: Context, undo: Undo)
	local world = context.world
	if undo.kind == "child" then
		reconcile.restore_fields(context, undo.entity, undo.child.entries, undo.previous)
		return
	end
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
	if undo.kind == "pair" or undo.kind == "child" then
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
	local first_error: any = nil
	for index = #capture.undo, 1, -1 do
		local undo = capture.undo[index]
		if not world:contains(undo.entity) then
			continue
		end
		if not still_ours(context, undo) then
			if undo.kind == "child" and undo.value ~= nil then
				local ok, err = pcall(repair_child, context, undo.entity, undo.child, undo.previous, undo.value)
				if not ok and first_error == nil then
					first_error = err
				end
			end
			continue
		end
		touched[undo.entity] = true
		local ok, err = pcall(state.with_applying, world_state, undo.entity, applied_id(undo), function()
			undo_one(context, undo)
		end)
		if not ok and first_error == nil then
			first_error = err
		end
	end
	if first_error ~= nil then
		error(first_error, 0)
	end
	return touched
end

local function rollback(context: Context, capture: Capture)
	if context.world_state.closed then
		return
	end
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

local function keys_of(entries: { CaptureEntry }): { string }
	local keys: { string } = {}
	for _, entry in entries do
		table.insert(keys, entry.session:get_key())
	end
	return keys
end

local function fail(context: Context, capture: Capture, id: string, err: unknown)
	abandon_all(capture.entries, id)
	local ok, rollback_err = pcall(rollback, context, capture)
	if not ok then
		logging.warn(messages.warnings.rollback_failed(id, rollback_err))
	end
	capture.batch:refuse(id, keys_of(capture.entries), tostring(err))
end

local function commit_single(context: Context, capture: Capture, entry: CaptureEntry)
	local session = entry.session
	local id = util.create_guid()
	local ok, err = pcall(function()
		session:journal({ id = id, ops = entry.ops, kind = "single" })
		session:sync()
	end)
	if ok then
		capture.batch:land()
		return
	end
	if session:has_landed(id) then
		session:abandon(id)
		settle(capture.entries, id)
		capture.batch:land()
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
		return
	end
	settle(entries, id)
	capture.batch:land()
end

local function commit_capture(context: Context, capture: Capture)
	local entries = capture.entries
	if #entries == 0 then
		capture.batch:land()
		return
	end
	if #entries == 1 then
		commit_single(context, capture, entries[1])
		return
	end
	commit_shared(context, capture)
end

local function run(world: World, fn: () -> (), is_delta: boolean): Batch
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
		return outer.batch
	end

	local context = contexts.create_context(world)
	local capture: Capture = { delta = is_delta, undo = {}, entries = {}, children = {}, batch = handle.create_batch() }
	world_state.capture = capture
	local ok, err = pcall(fn)
	world_state.capture = nil
	if not ok then
		local rolled, rollback_err = pcall(rollback, context, capture)
		if not rolled then
			logging.warn(messages.warnings.rollback_failed("capture", rollback_err))
		end
		error(err, 0)
	end
	for _, undo in capture.undo do
		if undo.kind == "child" then
			undo.value = child_fields(context, undo.entity, undo.child)
		end
	end
	task.spawn(commit_capture, context, capture)
	return capture.batch
end

local function batch(world: World, fn: () -> ()): Batch
	return run(world, fn, false)
end

local function delta(world: World, fn: () -> ()): Batch
	return run(world, fn, true)
end

return table.freeze({
	batch = batch,
	delta = delta,
})
