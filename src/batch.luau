local types = require("./types")
local callbacks = require("./callbacks")
local capture = require("./capture")
local children = require("./children")
local commit = require("./commit")
local contexts = require("./contexts")
local handle = require("./handle")
local hooks = require("./hooks")
local ids = require("./ids")
local jecs = require("./dependencies/jecs")
local link = require("./link")
local listeners = require("./listeners")
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
type SettledOutcome = types.SettledOutcome
type Touched = types.Touched
type Undo = types.Undo

local function still_ours(context: Context, undo: Undo): boolean
	local world = context.world
	if undo.kind == "component" then
		return world:get(undo.entity, undo.entry.id) == undo.value
	end
	if undo.kind == "relation" then
		local packed =
			relations.pack(world, undo.entry, undo.entity, nil, context.schema.named, context.world_state.warned)
		return ops.deep_equal(packed, undo.value)
	end
	if undo.kind == "child" then
		return ops.deep_equal(children.pack_fields_of(context, undo.entity, undo.child), undo.value)
	end
	if undo.kind == "pair" and undo.present and children.child_of(context.world_state.children, undo.entity) then
		return false
	end
	return world:has(undo.entity, undo.id) ~= undo.present
end

local function is_carried(undo: Undo): boolean
	if undo.kind == "pair" or undo.kind == "mark" then
		return false
	end
	return undo.carried
end

local function undo_one(context: Context, undo: Undo, carried: boolean)
	local world = context.world
	if undo.kind == "pair" then
		local kind = undo.child
		if undo.present then
			if not world:contains(undo.parent) then
				return
			end
			local id_component = if kind.mode == "owned" then ids.child_id else kind.id
			if undo.stored_id ~= nil and not world:has(undo.entity, id_component) then
				world:set(undo.entity, id_component, undo.stored_id)
			end
			world:add(undo.entity, kind.tag)
			world:add(undo.entity, jecs.pair(kind.via, undo.parent))
			if kind.mode == "attached" then
				capture.supply_claimed(context, undo.entity, kind)
			end
			return
		end
		world:remove(undo.entity, undo.id)
		if kind.mode == "attached" then
			reconcile.reset_child(context, undo.entity, kind)
		end
		return
	end
	if undo.kind == "mark" then
		if undo.present then
			world:add(undo.entity, undo.id)
		else
			world:remove(undo.entity, undo.id)
		end
		return
	end
	if undo.kind == "child" then
		if carried then
			reconcile.rewrite_fields(context, undo.entity, undo.child, undo.previous)
		else
			reconcile.restore_fields(context, undo.entity, undo.child, undo.previous)
		end
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
	if undo.kind == "tag" then
		if undo.present then
			world:add(undo.entity, undo.id)
		else
			world:remove(undo.entity, undo.id)
		end
	elseif undo.previous ~= nil then
		world:set(undo.entity, undo.entry.id, undo.previous)
	else
		world:remove(undo.entity, undo.entry.id)
	end
end

local function applied_id(undo: Undo): Entity<any>?
	if undo.kind == "pair" or undo.kind == "child" then
		return nil
	end
	if undo.kind == "component" or undo.kind == "relation" then
		return undo.entry.id
	end
	return undo.id
end

local function collect_keys(touched: Touched, undo: Undo)
	local keys = touched[undo.entity]
	if not keys then
		keys = {}
		touched[undo.entity] = keys
	end
	if undo.kind == "component" or undo.kind == "relation" then
		keys[undo.entry.key] = true
	elseif undo.kind == "tag" then
		keys[undo.key] = true
	elseif undo.kind == "child" then
		local entries: { SchemaEntry } = undo.child.entries
		for _, entry in entries do
			keys[entry.key] = true
		end
	end
end

local function undo_all(context: Context, captured: Capture, touched: Touched)
	local world, world_state = context.world, context.world_state
	local first_error: any = nil
	for index = #captured.undo, 1, -1 do
		local undo = captured.undo[index]
		if not world:contains(undo.entity) then
			continue
		end
		if not still_ours(context, undo) then
			if undo.kind == "child" then
				local ok, err =
					pcall(reconcile.repair_fields, context, undo.entity, undo.child, undo.previous, undo.value)
				if not ok and first_error == nil then
					first_error = err
				end
			end
			continue
		end
		collect_keys(touched, undo)
		local ok, err
		if is_carried(undo) then
			ok, err = pcall(undo_one, context, undo, true)
		else
			ok, err = pcall(state.with_applying, world_state, undo.entity, applied_id(undo), function()
				undo_one(context, undo, false)
			end)
		end
		if not ok and first_error == nil then
			first_error = err
		end
	end
	if first_error ~= nil then
		error(first_error, 0)
	end
end

local function inherit_field(mine_previous: Data, mine_value: Data, other_previous: Data, key: string)
	local value = mine_value[key]
	if ops.deep_equal(other_previous[key], value) and not ops.deep_equal(value, mine_previous[key]) then
		other_previous[key] = mine_previous[key]
	end
end

local function inherit_previous(mine: Undo, other: Undo)
	if mine.entity ~= other.entity or mine.kind ~= other.kind then
		return
	end
	if mine.kind == "child" and other.kind == "child" then
		for key in mine.value do
			inherit_field(mine.previous, mine.value, other.previous, key)
		end
		for key in mine.previous do
			if mine.value[key] == nil then
				inherit_field(mine.previous, mine.value, other.previous, key)
			end
		end
	elseif mine.kind == "component" then
		if other.kind == "component" and mine.entry == other.entry and ops.deep_equal(other.previous, mine.value) then
			other.previous = mine.previous
		end
	elseif mine.kind == "relation" then
		if other.kind == "relation" and mine.entry == other.entry and ops.deep_equal(other.previous, mine.value) then
			other.previous = mine.previous
		end
	elseif mine.kind == "tag" then
		if other.kind == "tag" and mine.id == other.id and other.present ~= mine.present then
			other.present = mine.present
		end
	elseif mine.kind == "pair" then
		if other.kind == "pair" and mine.id == other.id and other.present ~= mine.present then
			other.present = mine.present
		end
	elseif mine.kind == "mark" then
		if other.kind == "mark" and mine.id == other.id and other.present ~= mine.present then
			other.present = mine.present
		end
	end
end

local function disinherit(context: Context, captured: Capture)
	local captures = context.world_state.captures
	local mine_index = table.find(captures, captured) :: number
	for index = mine_index + 1, #captures do
		local other = captures[index]
		for _, mine in captured.undo do
			for _, undo in other.undo do
				inherit_previous(mine, undo)
			end
		end
	end
end

local function forget_capture(context: Context, captured: Capture)
	local captures = context.world_state.captures
	local index = table.find(captures, captured)
	if index then
		table.remove(captures, index)
	end
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

local function rollback(context: Context, captured: Capture)
	local world_state = context.world_state
	if world_state.closed then
		return
	end
	disinherit(context, captured)
	local touched: Touched = {}
	local ok, err = pcall(undo_all, context, captured, touched)
	for entity, keys in touched do
		local existing = world_state.entities[entity]
		if existing then
			existing.shadow = state.read_values(context, entity, context.schema.entries)
			existing.tree = nil
			for key in keys do
				existing.supplied[key] = nil
			end
		end
	end
	for _, entry in open_entries(captured.entries) do
		link.resupply(context, entry.session)
	end
	if not ok then
		error(err, 0)
	end
end

local function try_rollback(context: Context, captured: Capture, id: string)
	local ok, err = pcall(rollback, context, captured)
	if not ok then
		logging.warn(messages.warnings.rollback_failed(id, err))
	end
end

local function pull_all(entries: { CaptureEntry })
	util.join_all(entries, function(entry)
		entry.session:sync()
	end)
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

local function fail(context: Context, captured: Capture, id: string, err: unknown)
	abandon_all(captured.entries, id)
	try_rollback(context, captured, id)
	forget_capture(context, captured)
	local heard = context.world_state.hooks[hooks.refused]
	local message = tostring(err)
	captured.batch:refuse(id, keys_of(captured.entries), message, heard ~= nil and #heard > 0)
	callbacks.fire(context.world_state.hooks, hooks.refused, captured.batch, captured.batch, message)
end

local function settle_single(context: Context, captured: Capture, outcome: SettledOutcome)
	if outcome.kind == "landed" then
		forget_capture(context, captured)
		captured.batch:land()
		return
	end
	fail(context, captured, captured.id, outcome.message)
end

local function flush_single(context: Context, captured: Capture, entry: CaptureEntry)
	local batch = captured.batch
	if batch:is_settled() or captured.flushing then
		return
	end
	captured.flushing = true
	local session = entry.session
	local id = captured.id
	local _, err = pcall(session.sync, session)
	captured.flushing = false
	if batch:is_settled() then
		return
	end
	if session:has_landed(id) then
		session:abandon(id)
		settle(captured.entries, id)
		forget_capture(context, captured)
		batch:land()
		return
	end
	fail(context, captured, id, err)
end

local function commit_single(context: Context, captured: Capture, entry: CaptureEntry)
	local session = entry.session
	local id = captured.id
	local ok, err = pcall(session.journal, session, { id = id, ops = entry.ops, kind = "single" })
	if not ok then
		fail(context, captured, id, err)
		return
	end
	session:watch(id, function(outcome)
		settle_single(context, captured, outcome)
	end)
	captured.batch:flush_with(function()
		flush_single(context, captured, entry)
	end)
end

local function mark_or_confirm(config: ResolvedCollectionConfig, id: string, created: number)
	local ok, err = pcall(commit.mark, config, id)
	if ok or commit.fetch(config, id, created) == "committed" then
		return
	end
	error(err, 0)
end

local function commit_shared(context: Context, captured: Capture)
	local entries = captured.entries
	local id = captured.id
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
		fail(context, captured, id, err)
		return
	end
	settle(entries, id)
	forget_capture(context, captured)
	captured.batch:land()
end

local function commit_capture(context: Context, captured: Capture)
	local entries = captured.entries
	if #entries == 0 then
		forget_capture(context, captured)
		captured.batch:land()
		return
	end
	if #entries == 1 then
		commit_single(context, captured, entries[1])
		return
	end
	commit_shared(context, captured)
end

local function run(world: World, fn: () -> any, is_delta: boolean): Batch
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
	listeners.install(context)
	local captured: Capture = {
		id = util.create_guid(),
		delta = is_delta,
		flushing = false,
		undo = {},
		entries = {},
		children = {},
		batch = handle.create_batch(),
	}
	table.insert(world_state.captures, captured)
	world_state.capture = captured
	local ok, result = pcall(fn)
	world_state.capture = nil
	if ok and #captured.entries > 1 then
		ok, result = pcall(shared_config, captured.entries, captured.id)
	end
	if not ok then
		try_rollback(context, captured, captured.id)
		forget_capture(context, captured)
		error(result, 0)
	end
	captured.batch:hold(result)
	task.spawn(commit_capture, context, captured)
	return captured.batch
end

local function batch(world: World, fn: () -> any): Batch
	return run(world, fn, false)
end

local function delta(world: World, fn: () -> any): Batch
	return run(world, fn, true)
end

return table.freeze({
	batch = batch,
	delta = delta,
})
