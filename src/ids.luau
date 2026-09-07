local types = require("./types")
local jecs = require("./dependencies/jecs")

type Entity<T = nil> = types.Entity<T>
type ChildConfig = types.ChildConfig
type CollectionConfig = types.CollectionConfig
type ForeignSource = types.ForeignSource
type Guard = types.Guard
type Migration = types.Migration
type PairsConfig = types.PairsConfig
type Serdes = types.Serdes
type Snapshot = types.Snapshot

local function named<T>(id: Entity<T>, name: string): Entity<T>
	jecs.meta(id, jecs.Name, name)
	return id
end

local ids = {
	collection = named(jecs.component() :: Entity<string>, "miumiu.collection"),
	config = named(jecs.component() :: Entity<CollectionConfig>, "miumiu.config"),
	migrations = named(jecs.component() :: Entity<{ Migration }>, "miumiu.migrations"),
	from_foreign = named(jecs.component() :: Entity<ForeignSource>, "miumiu.from_foreign"),
	saveable = named(jecs.component() :: Entity<string>, "miumiu.saveable"),
	field_of = named(jecs.tag(), "miumiu.field_of"),
	guard = named(jecs.component() :: Entity<Guard>, "miumiu.guard"),
	serdes = named(jecs.component() :: Entity<Serdes>, "miumiu.serdes"),
	snapshot = named(jecs.component() :: Entity<Snapshot>, "miumiu.snapshot"),
	lazy = named(jecs.tag(), "miumiu.lazy"),
	pairs = named(jecs.component() :: Entity<PairsConfig>, "miumiu.pairs"),
	child = named(jecs.component() :: Entity<ChildConfig>, "miumiu.child"),
	child_id = named(jecs.component() :: Entity<string>, "miumiu.child_id"),

	data_link = named(jecs.component() :: Entity<string>, "miumiu.data_link"),
	data_shallow = named(jecs.tag(), "miumiu.data_shallow"),
	data_loading = named(jecs.tag(), "miumiu.data_loading"),
	data_loaded = named(jecs.tag(), "miumiu.data_loaded"),
	data_error = named(jecs.component() :: Entity<string>, "miumiu.data_error"),
}

return table.freeze(ids)
