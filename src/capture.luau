local types = require("./types")
local children = require("./children")
local codec = require("./codec")
local delta = require("./delta")
local logging = require("./logging")
local messages = require("./messages")
local reconcile = require("./reconcile")
local state = require("./state")
local util = require("./util")

type Entity<T = nil> = types.Entity<T>
type Ancestry = types.Ancestry
type Capture = types.Capture
type CaptureEntry = types.CaptureEntry
type ChildRecord = types.ChildRecord
type ChildUndo = types.ChildUndo
type ComponentWrite = types.ComponentWrite
type Context = types.Context
type Data = types.Data
type Held = types.Held
type Holders = types.Holders
type Op = types.Op
type Owner = types.Owner
type RelationWrite = types.RelationWrite
type SchemaEntry = types.SchemaEntry
type SessionInternal = types.SessionInternal
type SplitPath = types.SplitPath
type Undo = types.Undo
type WorldState = types.WorldState
type Write = types.Write

local function root_owner(context: Context, entity: Entity, holders: Holders): Owner
	local world_state = context.world_state
	local sessions: { SessionInternal } = {}
	local unsaved = true
	for collection, key in world_state.links[entity] do
		if not holders[collection] then
			continue
		end
		unsaved = false
		local open = state.open_session(state.link_states_of(world_state, collection)[key])
		if open then
			table.insert(sessions, open)
		end
	end
	if unsaved then
		return { kind = "unsaved" }
	end
	return { kind = "root", sessions = sessions }
end

local function owner_of(context: Context, entity: Entity, entry: SchemaEntry): Owner
	local world_state = context.world_state
	if world_state.links[entity] then
		return root_owner(context, entity, entry.holders)
	end
	local held = children.child_of(world_state.children, entity)
	if held and not entry.holders[held.kind.tag] then
		return { kind = "unsaved" }
	end
	local ancestry = children.ancestry(world_state, entity)
	if not ancestry then
		return { kind = "root", sessions = {} }
	end
	local root = root_owner(context, ancestry.root, ancestry.kind.holders)
	if root.kind == "unsaved" then
		return root
	end
	return { kind = "child", sessions = root.sessions, ancestry = ancestry }
end

local function sessions_of(owner: Owner): { SessionInternal }
	if owner.kind == "unsaved" then
		return {}
	end
	return owner.sessions
end

local function ancestry_sessions(context: Context, ancestry: Ancestry): { SessionInternal }
	local owner = root_owner(context, ancestry.root, ancestry.kind.holders)
	return sessions_of(owner)
end

local function warn_unsaved(context: Context, write: ComponentWrite)
	local world = context.world
	local held = children.child_of(context.world_state.children, write.entity)
	local holder = if held then held.kind.tag else write.entity
	logging.warn_once(
		context.world_state.warned,
		`{write.entry.key}/{holder}`,
		messages.warnings.unsaved_write(
			write.entry.key,
			util.describe(world, write.entity),
			util.describe(world, holder)
		)
	)
end

local function remember(world_state: WorldState, write: ComponentWrite): any
	local entity_state = state.entity_state(world_state, write.entity)
	local shadow = entity_state.shadow
	local key = write.entry.key
	local previous = shadow[key]
	if write.entry.kind == "tag" then
		shadow[key] = write.change ~= "removed"
	elseif write.change == "removed" then
		shadow[key] = nil
	else
		shadow[key] = write.value
	end
	entity_state.supplied[key] = nil
	entity_state.tree = nil
	return previous
end

local function restore(context: Context, write: ComponentWrite, previous: any)
	local entity, entry = write.entity, write.entry
	state.with_applying(context.world_state, entity, entry.id, function()
		reconcile.write_entry(context, entity, entry, previous)
	end)
end

local function validate_write(context: Context, write: ComponentWrite)
	local entry = write.entry
	if entry.kind ~= "component" or write.change == "removed" then
		return
	end
	local checked = codec.check_guard(entry, write.value)
	if checked.kind == "ok" then
		return
	end
	restore(context, write, state.entity_state(context.world_state, write.entity).shadow[entry.key])
	error(
		messages.errors.guard_rejected(
			entry.key,
			util.describe(context.world, write.entity),
			write.value,
			checked.reason
		),
		0
	)
end

local function delta_ops(session: SessionInternal, entry: SchemaEntry, previous: any, value: any): { Op }
	local stored_previous = codec.stored_form(entry, previous)
	local group_ops = delta.diff(entry.key, stored_previous, codec.stored_form(entry, value))
	local known = session:get_state()
	if previous ~= nil and known.truth[entry.key] == nil and known.stamps[entry.key] == nil then
		table.insert(group_ops, 1, { kind = "init", key = entry.key, value = stored_previous })
	end
	return group_ops
end

local function entry_for(capture: Capture, session: SessionInternal): CaptureEntry
	for _, entry in capture.entries do
		if entry.session == session then
			return entry
		end
	end
	local created: CaptureEntry = { session = session, ops = {}, coalesced = {} }
	table.insert(capture.entries, created)
	return created
end

local function split_path(ancestry: Ancestry): SplitPath
	local path = table.clone(ancestry.path)
	local key = table.remove(path, 1) :: string
	return { key = key, path = path }
end

local function child_put(context: Context, ancestry: Ancestry): Op
	local split = split_path(ancestry)
	local world_state = context.world_state
	local index = world_state.children
	local entity = children.lookup_entity(index, ancestry.root, ancestry.path)
	local held = children.child_of(index, entity) :: ChildRecord
	return {
		kind = "put",
		key = split.key,
		path = split.path,
		value = children.pack(
			context.world,
			world_state.entities,
			index,
			entity,
			held.kind,
			context.schema.named,
			world_state.warned
		),
		at = os.time(),
	}
end

local function child_drop(ancestry: Ancestry): Op
	local split = split_path(ancestry)
	return { kind = "drop", key = split.key, path = split.path, at = os.time() }
end

local function coalesce_key(ancestry: Ancestry): string
	return table.concat(ancestry.path, "/")
end

local function journal_ops(sessions: { SessionInternal }, group_ops: { Op }, coalesce: string?)
	for _, session in sessions do
		session:journal({
			id = util.create_guid(),
			ops = group_ops,
			kind = "single",
			coalesce = coalesce,
		})
	end
end

local function capture_ops(capture: Capture, sessions: { SessionInternal }, group_ops: { Op }, coalesce: string?)
	for _, session in sessions do
		local target = entry_for(capture, session)
		if coalesce then
			local existing = target.coalesced[coalesce]
			if existing then
				table.remove(target.ops, existing)
				for other, slot in target.coalesced do
					if slot > existing then
						target.coalesced[other] = slot - 1
					end
				end
			end
			target.coalesced[coalesce] = #target.ops + 1
		end
		for _, op in group_ops do
			table.insert(target.ops, op)
		end
	end
end

local function record_ops(context: Context, session: SessionInternal, group_ops: { Op })
	capture_ops(context.world_state.capture :: Capture, { session }, group_ops, nil)
end

local function forget_removal(world_state: WorldState, write: ComponentWrite)
	if write.change == "removed" or write.entry.kind == "relation" then
		state.forget_removing(world_state, write.entity, write.entry.key)
	end
end

local function shadow_fields(shadow: Data, entries: { SchemaEntry }): Data
	local fields: Data = {}
	for _, entry in entries do
		local value = shadow[entry.key]
		if entry.kind == "tag" then
			if value == true then
				fields[entry.key] = true
			elseif entry.initial.kind == "value" then
				fields[entry.key] = false
			end
		elseif value ~= nil then
			fields[entry.key] = codec.stored_form(entry, value)
		end
	end
	return fields
end

local function record_child(context: Context, capture: Capture, entity: Entity)
	local world_state = context.world_state
	local held = children.child_of(world_state.children, entity) :: ChildRecord
	local value = children.pack_fields_of(context, entity, held.kind)
	local existing = capture.children[entity]
	if existing then
		existing.value = value
		return
	end
	local shadow = state.entity_state(world_state, entity).shadow
	local undo: ChildUndo = {
		kind = "child",
		entity = entity,
		child = held.kind,
		previous = shadow_fields(shadow, held.kind.entries),
		value = value,
		carried = false,
	}
	capture.children[entity] = undo
	table.insert(capture.undo, undo)
end

local function is_prefix_of(prefix: { string }, path: { string }): boolean
	if #path < #prefix then
		return false
	end
	for index, segment in prefix do
		if path[index] ~= segment then
			return false
		end
	end
	return true
end

local function each_undo(world_state: WorldState, fn: (Undo) -> ())
	for _, capture in world_state.captures do
		for _, undo in capture.undo do
			fn(undo)
		end
	end
end

local function mark_carried(world_state: WorldState, entity: Entity, key: string)
	each_undo(world_state, function(undo)
		if undo.kind == "tag" then
			if undo.entity == entity and undo.key == key then
				undo.carried = true
			end
		elseif undo.kind == "component" or undo.kind == "relation" then
			if undo.entity == entity and undo.entry.key == key then
				undo.carried = true
			end
		end
	end)
end

local function mark_carried_children(world_state: WorldState, ancestry: Ancestry)
	each_undo(world_state, function(undo)
		if undo.kind ~= "child" then
			return
		end
		local other = children.ancestry(world_state, undo.entity)
		if other and other.root == ancestry.root and is_prefix_of(ancestry.path, other.path) then
			undo.carried = true
		end
	end)
end

local function record_component(context: Context, capture: Capture, owner: Held, write: ComponentWrite)
	local entry, entity = write.entry, write.entity
	if owner.kind == "child" then
		record_child(context, capture, entity)
		remember(context.world_state, write)
		capture_ops(capture, owner.sessions, { child_put(context, owner.ancestry) }, coalesce_key(owner.ancestry))
		return
	end
	if capture.delta then
		local reason = if entry.kind == "tag"
			then messages.reasons.tag
			elseif entry.kind == "relation" then messages.reasons.pair
			elseif write.change == "removed" then messages.reasons.removed
			else nil
		if reason then
			forget_removal(context.world_state, write)
			if write.change ~= "removed" then
				restore(context, write, state.entity_state(context.world_state, entity).shadow[entry.key])
			end
			error(messages.errors.not_a_delta(entry.key, reason), 0)
		end
	end
	local previous = remember(context.world_state, write)
	if entry.kind == "tag" then
		table.insert(capture.undo, {
			kind = "tag",
			entity = entity,
			id = entry.id,
			key = entry.key,
			present = previous == true,
			carried = false,
		})
	elseif entry.kind == "relation" then
		table.insert(capture.undo, {
			kind = "relation",
			entity = entity,
			entry = entry,
			previous = previous,
			value = write.value,
			carried = false,
		})
	else
		table.insert(capture.undo, {
			kind = "component",
			entity = entity,
			entry = entry,
			previous = previous,
			value = write.value,
			carried = false,
		})
	end

	for _, session in owner.sessions do
		local group_ops = if capture.delta
			then delta_ops(session, entry, previous, write.value)
			else { codec.op_for(entry, write.change, write.value) }
		capture_ops(capture, { session }, group_ops, nil)
	end
end

local function undo_trigger(context: Context, write: RelationWrite)
	state.with_applying(context.world_state, write.entity, nil, function()
		context.world:remove(write.entity, write.trigger)
	end)
end

local function reject_unloaded(context: Context, write: Write)
	local world = context.world
	if write.kind == "component" then
		forget_removal(context.world_state, write)
	end
	if write.kind == "component" and write.change == "added" then
		state.with_applying(context.world_state, write.entity, write.entry.id, function()
			world:remove(write.entity, write.entry.id)
		end)
	elseif write.kind == "relation" and write.change == "added" then
		undo_trigger(context, write)
	end
	error(messages.errors.not_loaded(util.describe(world, write.entity)), 0)
end

local function is_lazy(entry: SchemaEntry): boolean
	return entry.kind == "component" and entry.lazy
end

local function journal_component(context: Context, write: ComponentWrite, flushing: boolean)
	local world_state = context.world_state
	local owner = owner_of(context, write.entity, write.entry)
	local capture = world_state.capture
	if owner.kind == "unsaved" then
		warn_unsaved(context, write)
		return
	end
	if #owner.sessions == 0 then
		local existing = world_state.entities[write.entity]
		if capture and not (existing and existing.dropped) then
			reject_unloaded(context, write)
		end
		forget_removal(world_state, write)
		return
	end

	validate_write(context, write)
	local entity_state = state.entity_state(world_state, write.entity)
	if capture and not flushing then
		if capture.delta and is_lazy(write.entry) then
			restore(context, write, entity_state.shadow[write.entry.key])
			error(messages.errors.not_a_delta(write.entry.key, messages.reasons.lazy), 0)
		end
		record_component(context, capture, owner, write)
		return
	end
	if not flushing and write.change == "changed" and entity_state.shadow[write.entry.key] == write.value then
		return
	end
	if is_lazy(write.entry) and not flushing then
		remember(world_state, write)
		entity_state.lazy[write.entry.key] = true
		for _, session in owner.sessions do
			session:touch()
		end
		return
	end

	local previous = entity_state.shadow[write.entry.key]
	local encoded, op = pcall(function(): Op
		if owner.kind == "child" then
			return child_put(context, owner.ancestry)
		end
		return codec.op_for(write.entry, write.change, write.value)
	end)
	if not encoded then
		restore(context, write, previous)
		error(op, 0)
	end
	remember(world_state, write)
	if owner.kind == "child" then
		mark_carried_children(world_state, owner.ancestry)
		journal_ops(owner.sessions, { op }, coalesce_key(owner.ancestry))
		return
	end
	mark_carried(world_state, write.entity, write.entry.key)
	journal_ops(owner.sessions, { op }, write.entry.key)
end

local function flush_lazy(context: Context, entity: Entity, entries: { SchemaEntry })
	local world = context.world
	if not world:contains(entity) then
		return
	end
	local entity_state = state.entity_state(context.world_state, entity)
	for _, entry in entries do
		if not is_lazy(entry) or not entity_state.lazy[entry.key] then
			continue
		end
		entity_state.lazy[entry.key] = nil
		local value = world:get(entity, entry.id)
		journal_component(context, {
			kind = "component",
			entity = entity,
			entry = entry,
			change = if value == nil then "removed" else "changed",
			value = value,
			deleted = false,
		}, true)
	end
	children.each_child(context.world_state.children, entity, function(child, held)
		flush_lazy(context, child, held.kind.entries)
	end)
end

local function emit_child(context: Context, ancestry: Ancestry?, op_for: (Ancestry) -> Op, undo: (Capture) -> ())
	local world_state = context.world_state
	local capture = world_state.capture
	if capture then
		undo(capture)
	end
	if not ancestry then
		return
	end
	local sessions = ancestry_sessions(context, ancestry)
	if #sessions == 0 then
		return
	end
	local coalesce = coalesce_key(ancestry)
	local op = op_for(ancestry)
	if capture then
		capture_ops(capture, sessions, { op }, coalesce)
		return
	end
	if op.kind == "put" then
		mark_carried_children(world_state, ancestry)
	end
	journal_ops(sessions, { op }, coalesce)
end

return table.freeze({
	ancestry_sessions = ancestry_sessions,
	split_path = split_path,
	child_put = child_put,
	child_drop = child_drop,
	emit_child = emit_child,
	undo_trigger = undo_trigger,
	reject_unloaded = reject_unloaded,
	flush_lazy = flush_lazy,
	journal_component = journal_component,
	record_ops = record_ops,
})
