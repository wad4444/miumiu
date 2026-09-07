local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TestEZ = require(ReplicatedStorage.DevPackages.testez) :: any

local failures = 0
local modules = ReplicatedStorage.Tests:GetChildren()
table.sort(modules, function(a, b)
	return a.Name < b.Name
end)

for _, module in modules do
	if not string.find(module.Name, "%.spec$") then
		continue
	end
	print(`[miumiu] running {module.Name}`)
	local results = TestEZ.TestBootstrap:run({ module }, TestEZ.Reporters.TextReporter)
	failures += results.failureCount + #results.errors
end

finish(failures)
