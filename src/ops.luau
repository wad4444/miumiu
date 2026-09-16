local types = require("./types")

type Data = types.Data
type Op = types.Op
type Stamps = types.Stamps
type State = types.State

local function deep_equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not deep_equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function deep_freeze(value: any): any
	if type(value) == "table" then
		for _, nested in value do
			deep_freeze(nested)
		end
		table.freeze(value)
	end
	return value
end

local function deep_copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, entry in value do
		copy[key] = deep_copy(entry)
	end
	return copy
end

local function find(list: { any }, value: any): number?
	for index, element in list do
		if deep_equal(element, value) then
			return index
		end
	end
	return nil
end

local function resolve(truth: Data, key: string, path: { string }, depth: number): any
	local current: any = truth[key]
	for index = 1, depth do
		if type(current) ~= "table" then
			return nil
		end
		current = current[path[index]]
	end
	return current
end

local function path_key(key: string, path: { string }): string
	return `{key}/{table.concat(path, "/")}`
end

local function path_floor(stamps: Stamps, key: string, path: { string }): number
	local floor = stamps[key] or 0
	local prefix = key
	for _, segment in path do
		prefix = `{prefix}/{segment}`
		floor = math.max(floor, stamps[prefix] or 0)
	end
	return floor
end

local function replay(state: State, ops: { Op }): State
	local truth, stamps = state.truth, state.stamps
	local next_truth = truth
	local next_stamps = stamps
	local owned: { [any]: boolean } = {}

	local function own_truth(): Data
		if next_truth == truth then
			next_truth = table.clone(truth)
		end
		return next_truth
	end

	local function own_stamps(): Stamps
		if next_stamps == stamps then
			next_stamps = table.clone(stamps)
		end
		return next_stamps
	end

	local function own_child(parent: { [any]: any }, field: any): { [any]: any }
		local nested = parent[field]
		if type(nested) ~= "table" then
			nested = {}
			parent[field] = nested
			owned[nested] = true
		elseif not owned[nested] then
			nested = table.clone(nested)
			parent[field] = nested
			owned[nested] = true
		end
		return nested
	end

	local function own_nested(key: string): { [any]: any }
		return own_child(own_truth(), key)
	end

	local function own_at(key: string, path: { string }, depth: number): { [any]: any }
		local current = own_nested(key)
		for index = 1, depth do
			current = own_child(current, path[index])
		end
		return current
	end

	local function stamp(full_key: string, at: number)
		local prefix = `{full_key}/`
		for stamp_key in next_stamps do
			if string.sub(stamp_key, 1, #prefix) == prefix then
				own_stamps()[stamp_key] = nil
			end
		end
		own_stamps()[full_key] = at
	end

	for _, op in ops do
		local key = op.key
		if op.kind == "set" then
			if op.at > (next_stamps[key] or 0) then
				own_truth()[key] = op.value
				stamp(key, op.at)
			end
		elseif op.kind == "remove" then
			if op.at > (next_stamps[key] or 0) then
				own_truth()[key] = nil
				stamp(key, op.at)
			end
		elseif op.kind == "init" then
			if next_truth[key] == nil and next_stamps[key] == nil then
				own_truth()[key] = op.value
			end
		elseif op.kind == "add" then
			local current = next_truth[key]
			own_truth()[key] = (if type(current) == "number" then current else 0) + op.delta
		elseif op.kind == "insert" then
			table.insert(own_nested(key), op.value)
		elseif op.kind == "erase" then
			local list = next_truth[key]
			local index = if type(list) == "table" then find(list, op.value) else nil
			if index then
				table.remove(own_nested(key), index)
			end
		elseif op.kind == "put" then
			if op.at > path_floor(next_stamps, key, op.path) then
				local last = #op.path
				own_at(key, op.path, last - 1)[op.path[last]] = op.value
				stamp(path_key(key, op.path), op.at)
			end
		elseif op.kind == "drop" then
			if op.at > path_floor(next_stamps, key, op.path) then
				local last = #op.path
				local holder = resolve(next_truth, key, op.path, last - 1)
				if type(holder) == "table" and holder[op.path[last]] ~= nil then
					own_at(key, op.path, last - 1)[op.path[last]] = nil
				end
				stamp(path_key(key, op.path), op.at)
			end
		end
	end

	if next_truth == truth and next_stamps == stamps then
		return state
	end
	return { truth = next_truth, stamps = next_stamps }
end

return table.freeze({
	deep_equal = deep_equal,
	deep_copy = deep_copy,
	deep_freeze = deep_freeze,
	path_floor = path_floor,
	resolve = resolve,
	replay = replay,
})
