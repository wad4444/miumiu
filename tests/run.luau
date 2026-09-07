local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local coverage = require("./coverage")

local place_path = process.args[1] or "test.rbxl"

local function join(...)
	local result = {}
	for index = 1, select("#", ...) do
		for key, value in select(index, ...) do
			result[key] = value
		end
	end
	return result
end

local function create_signal()
	local connections: { { fn: (...any) -> (), once: boolean, connected: boolean } } = {}

	local function connect(fn, once)
		local connection = { fn = fn, once = once, connected = true }
		table.insert(connections, connection)
		return {
			Connected = true,
			Disconnect = function(self)
				connection.connected = false
				self.Connected = false
			end,
			Destroy = function(self)
				connection.connected = false
				self.Connected = false
			end,
		}
	end

	return {
		Connect = function(_, fn)
			return connect(fn, false)
		end,
		Once = function(_, fn)
			return connect(fn, true)
		end,
		Wait = function()
			error("Signal:Wait() is not supported by the test runner")
		end,
		DisconnectAll = function()
			table.clear(connections)
		end,
		Destroy = function()
			table.clear(connections)
		end,
		Fire = function(_, ...)
			for _, connection in table.clone(connections) do
				if not connection.connected then
					continue
				end
				if connection.once then
					connection.connected = false
				end
				connection.fn(...)
			end
		end,
	}
end

local game = roblox.deserializePlace(fs.readFile(place_path))
local game_proxy
game_proxy = setmetatable({}, {
	__index = function(_, key)
		local value = game[key]
		if type(value) == "function" then
			return function(self, ...)
				if self == game_proxy then
					self = game
				end
				return value(self, ...)
			end
		end
		return value
	end,
})

local heartbeat = create_signal()

roblox.implementMethod("Instance", "WaitForChild", function(self, ...)
	return self:FindFirstChild(...)
end)

roblox.implementMethod("DataModel", "BindToClose", function() end)
roblox.implementMethod("BindableEvent", "Fire", function() end)

roblox.implementMethod("TestService", "Message", function(_, message)
	stdio.write(`{message}\n`)
end)
roblox.implementMethod("TestService", "Warn", function(_, message)
	stdio.ewrite(`{message}\n`)
end)
roblox.implementMethod("TestService", "Error", function(_, message)
	stdio.ewrite(`{message}\n`)
end)
roblox.implementMethod("TestService", "Check", function() end)
roblox.implementMethod("TestService", "Done", function() end)
roblox.implementMethod("TestService", "Fail", function(_, message)
	stdio.ewrite(`{message}\n`)
end)

roblox.implementMethod("RunService", "IsServer", function()
	return true
end)
roblox.implementMethod("RunService", "IsClient", function()
	return false
end)
roblox.implementMethod("RunService", "IsRunning", function()
	return true
end)
roblox.implementMethod("RunService", "IsStudio", function()
	return false
end)
roblox.implementProperty("RunService", "Heartbeat", function()
	return heartbeat
end, function() end)

roblox.implementMethod("HttpService", "JSONEncode", function(_, value)
	return serde.encode("json", value)
end)
roblox.implementMethod("HttpService", "JSONDecode", function(_, text)
	return serde.decode("json", text)
end)
roblox.implementMethod("HttpService", "GenerateGUID", function(_, wrap)
	local parts = table.create(4)
	for index = 1, 4 do
		parts[index] = string.format("%08X", math.random(0, 0x7fffffff))
	end
	local hex = table.concat(parts)
	local guid = string.format(
		"%s-%s-%s-%s-%s",
		string.sub(hex, 1, 8),
		string.sub(hex, 9, 12),
		string.sub(hex, 13, 16),
		string.sub(hex, 17, 20),
		string.sub(hex, 21, 32)
	)
	return if wrap == false then guid else "{" .. guid .. "}"
end)

roblox.implementMethod("Players", "GetPlayers", function()
	return {}
end)

local function tick()
	return os.clock()
end

local function enum_type(name: string, item_names: { string })
	local items = {}
	local enum = {
		GetEnumItems = function()
			return table.clone(items)
		end,
	}
	for value, item_name in item_names do
		local item = setmetatable({ Name = item_name, Value = value, EnumType = enum }, {
			__tostring = function()
				return `Enum.{name}.{item_name}`
			end,
		})
		items[value] = item
		enum[item_name] = item
	end
	return enum
end

local Enum = setmetatable({
	DataStoreRequestType = enum_type("DataStoreRequestType", {
		"GetAsync",
		"SetIncrementAsync",
		"UpdateAsync",
		"GetSortedAsync",
		"SetIncrementSortedAsync",
		"OnUpdate",
	}),
}, { __index = roblox.Enum })

local Random = {
	new = function()
		return {
			NextNumber = function(_, min: number?, max: number?)
				local low = min or 0
				local high = max or 1
				return low + math.random() * (high - low)
			end,
			NextInteger = function(_, min: number, max: number)
				return math.random(min, max)
			end,
		}
	end,
}

local failure_count: number? = nil
local require_cache: { [string]: { any } } = {}
local roblox_require

local coverage_enabled = process.env.MIUMIU_COVERAGE ~= nil and process.env.MIUMIU_COVERAGE ~= ""

local function source_of(script): string
	local path = script:GetFullName()
	local file = string.match(path, "^ReplicatedStorage%.Packages%.miumiu%.?(.*)$")
	if not coverage_enabled or file == nil or string.find(file, "^dependencies") then
		return script.Source
	end
	return coverage.instrument(script.Source, if file == "" then "init" else file)
end

local function run_roblox_script(script)
	local callable = luau.load(luau.compile(source_of(script)), {
		debugName = script:GetFullName(),
		environment = join(roblox, {
			game = game_proxy,
			workspace = game:GetService("Workspace"),
			script = script,
			require = function(target)
				return roblox_require(target, script)
			end,
			tick = tick,
			task = task,
			Enum = Enum,
			Random = Random,
			__cov = coverage.hit,
			finish = function(count: number)
				failure_count = count
			end,
		}),
	})

	return callable()
end

local function directory_of(node)
	return node.Parent
end

local function resolve_specifier(from, specifier: string)
	local rest = specifier
	local base

	local alias, alias_rest = string.match(rest, "^@([^/]+)/(.*)$")
	if alias then
		if alias ~= "self" then
			error(`unsupported require alias "@{alias}" in {from:GetFullName()}`)
		end
		rest = alias_rest
		base = from
	else
		base = directory_of(from)

		if rest == ".." then
			return base.Parent
		end

		if string.sub(rest, 1, 2) == "./" then
			rest = string.sub(rest, 3)
		else
			while string.sub(rest, 1, 3) == "../" do
				rest = string.sub(rest, 4)
				base = base.Parent
			end
		end
	end

	for segment in string.gmatch(rest, "[^/]+") do
		local child = base:FindFirstChild(segment)
		if not child then
			error(`could not resolve require("{specifier}") from {from:GetFullName()}`)
		end
		base = child
	end

	return base
end

function roblox_require(target, from)
	local module_script = target
	if type(target) == "string" then
		module_script = resolve_specifier(from, target)
	end

	local path = module_script:GetFullName()
	local cached = require_cache[path]
	if cached then
		return table.unpack(cached)
	end

	local result = table.pack(run_roblox_script(module_script))
	require_cache[path] = result
	return table.unpack(result)
end

local running = true
task.spawn(function()
	while running do
		heartbeat:Fire(1 / 60)
		task.wait(1 / 60)
	end
end)

local watchdog_seconds = tonumber(process.env.MIUMIU_TEST_TIMEOUT) or 120
task.delay(watchdog_seconds, function()
	if running then
		stdio.ewrite(`test runner watchdog: no result after {watchdog_seconds}s\n`)
		process.exit(2)
	end
end)

run_roblox_script(game.ServerScriptService.main)
running = false

if failure_count == nil then
	stdio.ewrite("test runner did not report any results\n")
	process.exit(1)
end

local complete = true
if coverage_enabled then
	complete = coverage.report()
	if not complete and process.env.MIUMIU_COVERAGE == "strict" then
		stdio.ewrite("coverage is not complete\n")
	end
end

process.exit(if failure_count > 0 or (not complete and process.env.MIUMIU_COVERAGE == "strict") then 1 else 0)
