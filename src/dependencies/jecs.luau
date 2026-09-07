--!nonstrict
local package_module = script.Parent.Parent
local TS = _G[package_module]

local jecs
if TS then
	jecs = TS.import(script, TS.getModule(script, "@rbxts", "jecs").src.jecs)
else
	jecs = require(package_module.Parent.jecs)
end

return jecs :: typeof(require(script.Parent.Parent.Parent.jecs))
