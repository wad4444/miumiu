local types = require("./types")
local children = require("./children")
local codec = require("./codec")
local delta = require("./delta")
local ids = require("./ids")
local jecs = require("./dependencies/jecs")
local logging = require("./logging")
local messages = require("./messages")
local ops = require("./ops")
local reconcile = require("./reconcile")
local recorder = require("./recorder")
local relations = require("./relations")
local schema = require("./schema")
local state = require("./state")
local util = require("./util")

type Entity<T = nil> = types.Entity<T>
type Ancestry = types.Ancestry
type Capture = types.Capture
type CaptureEntry = types.CaptureEntry
type ChildKind = types.ChildKind
type ChildRecord = types.ChildRecord
type ChildUndo = types.ChildUndo
type ComponentWrite = types.ComponentWrite
type Context = types.Context
type Data = types.Data
type ExistingChild = types.ExistingChild
type Held = types.Held
type MarkWrite = types.MarkWrite
type Op = types.Op
type Owner = types.Owner
type RelationWrite = types.RelationWrite
type SchemaEntry = types.SchemaEntry
type Scopes = types.Scopes
type SessionInternal = types.SessionInternal
type SplitPath = types.SplitPath
type Undo = types.Undo
type WorldState = types.WorldState
type Write = types.Write

local function root_owner(context: Context, entity: Entity, scopes: Scopes): Owner
	local world_state = context.world_state
	local sessions: { SessionInternal } = {}
	local unsaved = true
	for collection, key in world_state.links[entity] do
		if not schema.holds(context.schema, scopes, collection) then
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
		return root_owner(context, entity, entry.scopes)
	end
	local held = children.child_of(world_state.children, entity)
	if held and not schema.is_field_of(entry.scopes, held.kind.tag, false) then
		return { kind = "unsaved" }
	end
	local ancestry = children.ancestry(world_state, entity)
	if not ancestry then
		return { kind = "root", sessions = {} }
	end
	local root = root_owner(context, ancestry.root, ancestry.kind.scopes)
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

local function held_kind_of(context: Context, entity: Entity): ChildKind?
	local held = children.child_of(context.world_state.children, entity)
	if held then
		return held.kind
	end
	return children.kind_of(context.world, context.schema.kinds, entity)
end

local function parent_holds(context: Context, kind: ChildKind, parent: Entity): boolean
	local parent_kind = held_kind_of(context, parent)
	if parent_kind then
		return schema.is_field_of(kind.scopes, parent_kind.tag, true)
	end
	local links = context.world_state.links[parent]
	if not links then
		return true
	end
	for collection in links do
		if schema.holds(context.schema, kind.scopes, collection) then
			return true
		end
	end
	return false
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

local function warn_unheld(context: Context, write: RelationWrite)
	local world = context.world
	local parent_kind = held_kind_of(context, write.parent)
	local holder = if parent_kind then parent_kind.tag else write.parent
	logging.warn_once(
		context.world_state.warned,
		`{write.child.tag}/{holder}`,
		messages.warnings.child_unheld(
			util.describe(world, write.entity),
			children.describe_kind(world, write.child),
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
		if entry.kind == "relation" then
			relations.apply(
				context.world,
				entry,
				entity,
				context.schema.named,
				previous or {},
				context.world_state.warned
			)
		elseif entry.kind == "tag" then
			if previous ~= true then
				context.world:remove(entity, entry.id)
			end
		elseif previous == nil then
			context.world:remove(entity, entry.id)
		else
			context.world:set(entity, entry.id, previous)
		end
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

local function forget_removal(world_state: WorldState, write: ComponentWrite)
	local existing = world_state.entities[write.entity]
	if existing and (write.change == "removed" or write.entry.kind == "relation") then
		existing.removing[write.entry.key] = nil
	end
end

local function shadow_fields(shadow: Data, entries: { SchemaEntry }): Data
	local fields: Data = {}
	for _, entry in entries do
		local value = shadow[entry.key]
		if entry.kind == "tag" then
			if value == true then
				fields[entry.key] = true
			elseif entry.has_initial then
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

local function covers_path(prefix: { string }, path: { string }): boolean
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
		if other and other.root == ancestry.root and covers_path(ancestry.path, other.path) then
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
	if is_lazy(write.entry) and not flushing then
		remember(world_state, write)
		entity_state.lazy[write.entry.key] = true
		for _, session in owner.sessions do
			session:touch()
		end
		return
	end
	if not flushing and write.change == "changed" and entity_state.shadow[write.entry.key] == write.value then
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
	local index = context.world_state.children
	local by_key = index.by_parent[entity]
	if not by_key then
		return
	end
	for _, list in by_key do
		for _, child in list do
			local held = children.child_of(index, child) :: ChildRecord
			flush_lazy(context, child, held.kind.entries)
		end
	end
end

local function assign_id(context: Context, write: RelationWrite): string
	local world = context.world
	local existing = children.resolve_id(world, write.entity, write.child)
	if existing then
		return existing
	end
	if write.child.mode == "attached" then
		children.reject_unnamed(world, write.entity, write.child)
	end
	return children.mint_id(world, write.entity)
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
	local sessions = sessions_of(root_owner(context, ancestry.root, ancestry.kind.scopes))
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

local function shallow_root(context: Context, root: Entity): boolean
	for collection in context.world_state.links[root] do
		if context.world:has(root, jecs.pair(ids.data_shallow, collection)) then
			return true
		end
	end
	return false
end

local function supply_claimed(context: Context, entity: Entity, kind: ChildKind)
	local ancestry = children.ancestry(context.world_state, entity)
	if not ancestry then
		return
	end
	local sessions = sessions_of(root_owner(context, ancestry.root, ancestry.kind.scopes))
	if #sessions == 0 or shallow_root(context, ancestry.root) then
		return
	end
	local split = split_path(ancestry)
	local stored = ops.resolve(sessions[1]:get_truth(), split.key, split.path, #split.path)
	reconcile.supply_child(context, entity, kind, if type(stored) == "table" then stored else {})
end

local function stored_id_of(context: Context, entity: Entity, kind: ChildKind): any
	if kind.mode == "owned" then
		return context.world:get(entity, ids.child_id)
	end
	return context.world:get(entity, kind.id)
end

local function mark_dropped(context: Context, entity: Entity)
	local world_state = context.world_state
	state.entity_state(world_state, entity).dropped = true
	table.insert(world_state.dropped_entities, entity)
end

local function attach(context: Context, write: RelationWrite, was_dropped: boolean)
	if not was_dropped then
		reconcile.record_baselines(context, write.entity, write.child)
	end
	reconcile.refresh_shadows(context, write.entity, write.child)
	supply_claimed(context, write.entity, write.child)
end

local function on_detached(context: Context, write: RelationWrite)
	local world_state = context.world_state
	local index = world_state.children
	local pair = jecs.pair(write.child.via, write.parent)
	local previous = children.child_of(index, write.entity)
	if previous and (previous.kind ~= write.child or previous.parent ~= write.parent) then
		return
	end
	local ancestry = if previous then children.ancestry(world_state, write.entity) else nil
	local applying = state.is_applying(world_state, write.entity, pair)
	if write.child.mode == "attached" and previous and not write.deleted and not applying then
		flush_lazy(context, write.entity, write.child.entries)
	end
	children.forget(index, write.entity)
	if write.deleted then
		world_state.deleting[write.entity] = true
		world_state.entities[write.entity] = nil
		children.forget_parent(index, write.entity)
	end
	if applying then
		return
	end
	if write.child.mode == "attached" then
		local held = (previous ~= nil and world_state.deleting[write.parent])
			or (ancestry ~= nil and #sessions_of(root_owner(context, ancestry.root, ancestry.kind.scopes)) > 0)
		if not write.deleted and held then
			table.insert(world_state.cleanups, { kind = "reset", entity = write.entity, child = write.child })
		end
		if not write.deleted then
			mark_dropped(context, write.entity)
			local capture = world_state.capture
			if capture and previous then
				table.insert(capture.undo, {
					kind = "pair",
					entity = write.entity,
					id = write.trigger,
					present = true,
					child = write.child,
					parent = write.parent,
					stored_id = stored_id_of(context, write.entity, write.child),
				})
			end
		end
		return
	end
	if world_state.deleting[write.parent] then
		if previous and not write.deleted then
			table.insert(world_state.cleanups, { kind = "delete", entity = write.entity })
		end
		return
	end
	if not write.deleted then
		mark_dropped(context, write.entity)
	end
	local stored_id = stored_id_of(context, write.entity, write.child)
	emit_child(context, ancestry, child_drop, function(capture)
		table.insert(capture.undo, {
			kind = "pair",
			entity = write.entity,
			id = write.trigger,
			present = true,
			child = write.child,
			parent = write.parent,
			stored_id = stored_id,
		})
	end)
end

local function validate_kind(context: Context, write: RelationWrite)
	local world, world_state = context.world, context.world_state
	for _, other in context.schema.kinds_by_relation[write.child.via] do
		if other ~= write.child and world:has(write.entity, other.tag) then
			undo_trigger(context, write)
			error(
				messages.errors.child_kinds_ambiguous(
					util.describe(world, write.entity),
					children.describe_kind(world, write.child),
					children.describe_kind(world, other)
				),
				0
			)
		end
	end
	local held = children.child_of(world_state.children, write.entity)
	if held then
		undo_trigger(context, write)
		error(
			messages.errors.child_double_parent(
				util.describe(world, write.entity),
				children.describe_kind(world, write.child),
				children.describe_kind(world, held.kind)
			),
			0
		)
	end
end

local function on_attached(context: Context, write: RelationWrite)
	local world_state = context.world_state
	local index = world_state.children
	local pair = jecs.pair(write.child.via, write.parent)
	local applying = state.is_applying(world_state, write.entity, pair)

	validate_kind(context, write)
	if not parent_holds(context, write.child, write.parent) then
		warn_unheld(context, write)
		return
	end
	local named, id = pcall(assign_id, context, write)
	if not named then
		undo_trigger(context, write)
		error(id, 0)
	end
	children.record(index, write.entity, write.child, write.parent, id)
	local existing = world_state.entities[write.entity]
	local was_dropped = existing ~= nil and existing.dropped
	if existing then
		existing.dropped = false
	end
	if applying then
		return
	end
	local ancestry = children.ancestry(world_state, write.entity)
	if write.child.mode == "attached" then
		attach(context, write, was_dropped)
		local capture = world_state.capture
		if capture then
			table.insert(capture.undo, {
				kind = "pair",
				entity = write.entity,
				id = write.trigger,
				present = false,
				child = write.child,
				parent = write.parent,
				stored_id = stored_id_of(context, write.entity, write.child),
			})
		end
		return
	end
	if
		world_state.capture
		and (ancestry == nil or #sessions_of(root_owner(context, ancestry.root, ancestry.kind.scopes)) == 0)
	then
		reject_unloaded(context, write)
	end
	reconcile.refresh_shadows(context, write.entity, write.child)
	local stored_id = stored_id_of(context, write.entity, write.child)
	emit_child(context, ancestry, function(found)
		return child_put(context, found)
	end, function(capture)
		table.insert(capture.undo, {
			kind = "pair",
			entity = write.entity,
			id = write.trigger,
			present = false,
			child = write.child,
			parent = write.parent,
			stored_id = stored_id,
		})
	end)
end

local function on_marked(context: Context, write: MarkWrite)
	local world_state = context.world_state
	local capture = world_state.capture
	if capture == nil or state.is_applying(world_state, write.entity, write.child.tag) then
		return
	end
	table.insert(capture.undo, {
		kind = "mark",
		entity = write.entity,
		id = write.child.tag,
		present = write.change == "removed",
	})
end

local function journal(context: Context, write: Write)
	if write.kind == "component" then
		journal_component(context, write, false)
	elseif write.kind == "mark" then
		on_marked(context, write)
	elseif write.change == "removed" then
		on_detached(context, write)
	else
		on_attached(context, write)
	end
end

local function collect_existing(context: Context): { ExistingChild }
	local world = context.world
	local found: { ExistingChild } = {}
	for _, kind in context.schema.kinds do
		for entity in world:each(kind.tag) do
			local parent = world:target(entity, kind.via, 0)
			if parent then
				table.insert(found, { kind = kind, entity = entity, parent = parent })
			end
		end
	end
	return found
end

local function index_existing(context: Context)
	local world, world_state = context.world, context.world_state
	for _, existing in collect_existing(context) do
		local kind, entity = existing.kind, existing.entity
		if not parent_holds(context, kind, existing.parent) then
			continue
		end
		local resolved, id = pcall(children.resolve_id, world, entity, kind)
		if not resolved then
			logging.warn(messages.warnings.child_indexing_failed(util.describe(world, entity), id))
			continue
		end
		if id == nil and kind.mode == "owned" then
			id = children.mint_id(world, entity)
		end
		if id == nil then
			logging.warn(
				messages.warnings.child_unnamed_existing(
					util.describe(world, entity),
					children.describe_kind(world, kind)
				)
			)
			continue
		end
		children.record(world_state.children, entity, kind, existing.parent, id)
		if kind.mode == "attached" then
			reconcile.record_baseline(context, entity, kind)
		else
			reconcile.refresh_shadows(context, entity, kind)
		end
	end
end

local function install(context: Context): { () -> () }
	local world_state = context.world_state
	index_existing(context)
	return recorder.install(context.world, context.schema, context.schema.named, function(write)
		if
			write.kind == "component"
			and (write.deleted or state.is_applying(world_state, write.entity, write.entry.id))
		then
			return
		end
		journal(context, write)
	end)
end

return table.freeze({
	install = install,
	flush_lazy = flush_lazy,
	supply_claimed = supply_claimed,
})
