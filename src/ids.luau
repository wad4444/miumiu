local types = require("./types")
local pepecs = require("./dependencies/pepecs")

type Entity<T = nil> = types.Entity<T>
type ChildConfig = types.ChildConfig
type CollectionConfig = types.CollectionConfig
type ForeignSource = types.ForeignSource
type Guard = types.Guard
type Migration = types.Migration
type OrderedConfig = types.OrderedConfig
type PairsConfig = types.PairsConfig
type Serdes = types.Serdes
type Snapshot = types.Snapshot

local function named<T>(id: Entity<T>, name: string): Entity<T>
	pepecs.meta(id, pepecs.Name, name)
	return id
end

local ids = {
	collection = named(pepecs.component() :: Entity<string>, "miumiu.collection"),
	config = named(pepecs.component() :: Entity<CollectionConfig>, "miumiu.config"),
	migrations = named(pepecs.component() :: Entity<{ Migration }>, "miumiu.migrations"),
	from_foreign = named(pepecs.component() :: Entity<ForeignSource>, "miumiu.from_foreign"),
	saveable = named(pepecs.component() :: Entity<string>, "miumiu.saveable"),
	field_of = named(pepecs.tag(), "miumiu.field_of"),
	guard = named(pepecs.component() :: Entity<Guard>, "miumiu.guard"),
	serdes = named(pepecs.component() :: Entity<Serdes>, "miumiu.serdes"),
	snapshot = named(pepecs.component() :: Entity<Snapshot>, "miumiu.snapshot"),
	lazy = named(pepecs.tag(), "miumiu.lazy"),
	pairs = named(pepecs.component() :: Entity<PairsConfig>, "miumiu.pairs"),
	child = named(pepecs.component() :: Entity<ChildConfig>, "miumiu.child"),
	child_id = named(pepecs.component() :: Entity<string>, "miumiu.child_id"),
	ordered = named(pepecs.component() :: Entity<OrderedConfig>, "miumiu.ordered"),

	data_link = named(pepecs.component() :: Entity<string>, "miumiu.data_link"),
	data_shallow = named(pepecs.tag(), "miumiu.data_shallow"),
	data_loading = named(pepecs.tag(), "miumiu.data_loading"),
	data_loaded = named(pepecs.tag(), "miumiu.data_loaded"),
	data_error = named(pepecs.component() :: Entity<string>, "miumiu.data_error"),
}

return table.freeze(ids)
