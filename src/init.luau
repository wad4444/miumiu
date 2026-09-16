local types = require("@self/types")
local batch = require("@self/batch")
local handle = require("@self/handle")
local hooks = require("@self/hooks")
local ids = require("@self/ids")
local logging = require("@self/logging")
local session = require("@self/session")
local step = require("@self/step")

export type World = types.World
export type Entity<T = nil> = types.Entity<T>
export type Data = types.Data
export type Op = types.Op
export type Stamps = types.Stamps
export type Pending = types.Pending
export type PendingEntry = types.PendingEntry
export type StoredRecord = types.StoredRecord
export type Guard = types.Guard
export type Serdes = types.Serdes
export type Snapshot = types.Snapshot
export type ChildConfig = types.ChildConfig
export type ChildMode = types.ChildMode
export type PairsConfig = types.PairsConfig
export type Migration = types.Migration
export type MigrationContext = types.MigrationContext
export type LapisCollection = types.LapisCollection
export type LapisLibrary = types.LapisLibrary
export type LapisSource = types.LapisSource
export type ForeignSource = types.ForeignSource
export type CollectionConfig = types.CollectionConfig
export type ResolvedCollectionConfig = types.ResolvedCollectionConfig
export type Session = types.Session
export type Closure = types.Closure
export type SessionStatus = types.SessionStatus
export type Batch = types.Batch
export type Outcome = types.Outcome
export type SettledOutcome = types.SettledOutcome
export type LandedHook = types.LandedHook
export type RefusedHook = types.RefusedHook
export type PulledHook = types.PulledHook
export type ClosedHook = types.ClosedHook
export type WritingHook = types.WritingHook

local miumiu = {
	collection = ids.collection,
	config = ids.config,
	migrations = ids.migrations,
	from_foreign = ids.from_foreign,
	saveable = ids.saveable,
	field_of = ids.field_of,
	guard = ids.guard,
	serdes = ids.serdes,
	snapshot = ids.snapshot,
	lazy = ids.lazy,
	pairs = ids.pairs,
	child = ids.child,
	child_id = ids.child_id,

	data_link = ids.data_link,
	data_shallow = ids.data_shallow,
	data_loading = ids.data_loading,
	data_loaded = ids.data_loaded,
	data_error = ids.data_error,

	step = step.step,
	close = step.close,
	get_session = step.get_session,
	wipe = step.wipe,
	batch = batch.batch,
	delta = batch.delta,

	hooks = hooks,
	hook = step.hook :: types.WorldHook,
	is_session = session.is_session,
	is_batch = handle.is_batch,
	set_warn = logging.set_warn,
}

miumiu.default = miumiu

return table.freeze(miumiu)
