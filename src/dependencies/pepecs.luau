--!nonstrict
local package_module = script.Parent.Parent
local TS = _G[package_module]

local pepecs
if TS then
	pepecs = TS.import(script, TS.getModule(script, "@rbxts", "pepecs").src)
else
	pepecs = require(package_module.Parent.pepecs)
end

return pepecs :: typeof(require(script.Parent.Parent.Parent.pepecs))
