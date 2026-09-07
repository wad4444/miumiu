local types = require("./types")
local logging = require("./logging")
local messages = require("./messages")

type SessionInternal = types.SessionInternal

local function jittered(interval: number): number
	return interval * (1 + 0.5 * math.random())
end

local function start(session: SessionInternal)
	task.spawn(function()
		local failing = false
		local idle = 0
		local seen = session:get_pulls()
		while session:is_open() do
			local config = session:get_config()
			idle += task.wait(jittered(config.pull_interval))
			if not session:is_open() then
				break
			end
			local pulls = session:get_pulls()
			if pulls ~= seen then
				seen = pulls
				idle = 0
			end
			if not session:is_dirty() and idle < config.idle_interval then
				continue
			end
			idle = 0
			local ok, err = pcall(session.sync, session)
			seen = session:get_pulls()
			if ok and failing then
				failing = false
				logging.warn(messages.warnings.pull_recovered(session:get_key()))
			elseif not ok and not failing and session:is_open() then
				failing = true
				logging.warn(messages.warnings.pull_failed(session:get_key(), err))
			end
		end
	end)
end

return table.freeze({
	start = start,
})
