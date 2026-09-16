local types = require("./types")
local messages = require("./messages")
local util = require("./util")

type Change = types.Change
type ComponentEntry = types.ComponentEntry
type GuardResult = types.GuardResult
type Op = types.Op
type SchemaEntry = types.SchemaEntry
type SyncKind = types.SyncKind

local function stored_form(entry: SchemaEntry, value: any): any
	if entry.kind == "component" and entry.serdes and value ~= nil then
		local stored = util.sync("serialize", entry.key, entry.serdes.serialize, value)
		if stored == nil then
			error(messages.errors.serialize_nil(entry.key), 0)
		end
		return stored
	end
	return value
end

local function runtime_form(entry: ComponentEntry, value: any): any
	if entry.serdes == nil then
		return value
	end
	return util.sync("deserialize", entry.key, entry.serdes.deserialize, value)
end

local function check_guard(entry: ComponentEntry, value: any): GuardResult
	local guard = entry.guard
	if guard == nil then
		return { kind = "ok" }
	end
	local ran, accepted, message = pcall(util.sync, "guard" :: SyncKind, entry.key, guard, value)
	if ran and accepted then
		return { kind = "ok" }
	end
	return { kind = "rejected", reason = if ran then message else tostring(accepted) }
end

local function op_for(entry: SchemaEntry, change: Change, value: any): Op
	local at = os.time()
	if entry.kind == "tag" then
		return { kind = "set", key = entry.key, value = change ~= "removed", at = at }
	end
	if change == "removed" then
		return { kind = "remove", key = entry.key, at = at }
	end
	return { kind = "set", key = entry.key, value = stored_form(entry, value), at = at }
end

return table.freeze({
	stored_form = stored_form,
	runtime_form = runtime_form,
	check_guard = check_guard,
	op_for = op_for,
})
