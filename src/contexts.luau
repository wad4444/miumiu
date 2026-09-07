local types = require("./types")
local schema = require("./schema")
local state = require("./state")

type World = types.World
type Context = types.Context

local function create_context(world: World): Context
	return {
		world = world,
		world_state = state.get(world),
		schema = schema.get(world),
	}
end

return table.freeze({
	create_context = create_context,
})
