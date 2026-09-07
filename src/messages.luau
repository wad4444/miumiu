local function prefixed(message: string): string
	return `miumiu: {message}`
end

local function suffix(message: string?): string
	return if message then `: {message}` else ""
end

local reasons = table.freeze({
	tag = "tags cannot be expressed as a delta",
	removed = "value removed",
	type_changed = "type changed",
	in_place = "array elements changed in place; build the new array from the old one (table.clone, then insert or remove) so untouched elements keep their identity",
	string_keys = "dictionary keys must be strings",
	mixed = "array and dictionary mixed",
	not_a_table = function(kind: string)
		return `{kind} values cannot be expressed as a delta`
	end,
	child_not_table = "the value must be a table",
	child_key = "key must be a non-empty string without /",
	child_mode = `mode must be "owned" or "attached"`,
	child_via = "via must be a relation id marked jecs.Exclusive",
	child_id = "an attached kind needs an id component",
	child_tag = "the kind must be declared on a tag",
	lazy = "lazy saveables are read at write time and cannot be expressed as a delta",
	pair = "pairs are stored whole and cannot be expressed as a delta",
	pair_table = "a stored set of pairs must be a table keyed by target name",
})

local errors = table.freeze({
	session_closed = function(key: string)
		return prefixed(`session "{key}" is closed`)
	end,
	saveable_unnamed = function(id: unknown)
		return prefixed(`saveable {id} has no key: meta(id, miumiu.saveable, "key") needs a non-empty string`)
	end,
	saveable_key_invalid = function(id: unknown, key: string)
		return prefixed(`saveable {id} stores under "{key}": a key cannot contain /`)
	end,
	field_of_invalid = function(id: unknown, target: unknown)
		return prefixed(
			`saveable {id} is a field of {target}, which is neither a collection nor a child kind: pair(miumiu.field_of, x) takes a collection entity or a kind tag`
		)
	end,
	duplicate_key = function(first: unknown, second: unknown, key: string)
		return prefixed(`saveables {first} and {second} both store under "{key}"`)
	end,
	schema_frozen = function(id: unknown)
		return prefixed(
			`saveable {id} changed after the schema was built: declare every saveable before the first step`
		)
	end,
	not_a_collection = function(entity: unknown)
		return prefixed(`{entity} is not a collection: meta(entity, miumiu.collection, "store name") is missing`)
	end,
	collection_unnamed = function(collection: unknown)
		return prefixed(
			`collection {collection} has no name: meta(entity, miumiu.collection, "store name") needs a non-empty string`
		)
	end,
	unknown_foreign = function(collection: unknown, kind: string)
		return prefixed(`collection {collection} imports from unknown foreign type "{kind}"`)
	end,
	foreign_unnamed = function(collection: unknown)
		return prefixed(`collection {collection} imports from a foreign store with no name`)
	end,
	foreign_no_source = function(collection: unknown, kind: string)
		return prefixed(`collection {collection} imports from {kind} but from_foreign.source is not the {kind} library`)
	end,
	foreign_no_options = function(collection: unknown, kind: string)
		return prefixed(
			`collection {collection} imports from {kind} but from_foreign.options (the {kind} collection options) is missing`
		)
	end,
	foreign_name_clash = function(collection: unknown, name: string)
		return prefixed(
			`collection {collection} imports from "{name}", which is its own store; the foreign store must be a different DataStore`
		)
	end,
	newer_record = function(key: string, applied: number, declared: number)
		return prefixed(
			`record "{key}" has {applied} migrations applied but this server declares {declared}: written by a newer server, this server's session on the key ends and its entities get data_error`
		)
	end,
	legacy_missing = function(key: string, stored_key: string)
		return prefixed(`record "{key}" has no stored value for legacy key "{stored_key}"`)
	end,
	legacy_is_saveable = function(key: string, stored_key: string)
		return prefixed(`"{stored_key}" is a current saveable of "{key}": use its component instead of context.legacy`)
	end,
	migration_failed = function(key: string, index: number, err: unknown)
		return prefixed(`migration {index} of "{key}" failed: {err}`)
	end,
	not_loaded = function(entity: unknown)
		return prefixed(
			`entity {entity} is not loaded: every entity written inside batch or delta needs a loaded link or a loaded ancestor`
		)
	end,
	link_kinds_overlap = function(entity: unknown, collection: unknown, other: unknown)
		return prefixed(
			`entity {entity} cannot link to {collection} while linked to {other}: both hold a child kind and would each delete the other's children; scope the kind to one collection with pair(miumiu.field_of, collection)`
		)
	end,
	scope_required = function(id: unknown, collections: { string })
		return prefixed(
			`{id} has no field_of pair and this world declares several collections ({table.concat(collections, ", ")}): pair(miumiu.field_of, collection) picks where it lives`
		)
	end,
	batch_expired = function(id: string)
		return prefixed(`batch {id} took longer than half of commit_timeout to reach its commit and was rolled back`)
	end,
	batch_mixed_stores = function(id: string)
		return prefixed(
			`batch {id} spans collections with different data_store_service, commit_store or commit_timeout; a multi-key batch needs one commit store`
		)
	end,
	guard_rejected = function(key: string, entity: unknown, value: unknown, message: string?)
		return prefixed(`value written to "{key}" on {entity} failed its guard (got {typeof(value)}){suffix(message)}`)
	end,
	yielded = function(what: string, subject: string)
		return prefixed(`{what} for "{subject}" yielded; guards, serdes and migrations must not yield`)
	end,
	not_a_delta = function(key: string, reason: string)
		return prefixed(`write to "{key}" inside delta is not a delta: {reason}`)
	end,
	bad_config = function(collection: unknown, field: string, minimum: number, exclusive: boolean)
		local bound = if exclusive then `greater than {minimum}` else `at least {minimum}`
		return prefixed(`collection {collection} config.{field} must be a number {bound}`)
	end,
	bad_commit_store = function(collection: unknown)
		return prefixed(`collection {collection} config.commit_store must be a non-empty string`)
	end,
	close_timed_out = function(key: string)
		return prefixed(`final write of "{key}" did not return before the close budget ran out`)
	end,
	child_config_invalid = function(tag: unknown, why: string)
		return prefixed(
			`child kind {tag} is misconfigured: {why}; meta(tag, miumiu.child, config) takes via, key, mode and, for attached kinds, id`
		)
	end,
	child_key_clash = function(tag: unknown, key: string, other: unknown)
		return prefixed(`child kind {tag} stores under "{key}", which {other} already uses`)
	end,
	child_unnamed = function(entity: unknown, tag: unknown)
		return prefixed(
			`attached child {entity} of kind {tag} has no id: set its id component before linking it to a parent`
		)
	end,
	child_id_invalid = function(entity: unknown, tag: unknown, got: string)
		return prefixed(
			`attached child {entity} of kind {tag} has a {got} id: the id component must hold a string or a number`
		)
	end,
	child_id_slash = function(entity: unknown, tag: unknown, id: string)
		return prefixed(`attached child {entity} of kind {tag} has the id "{id}": an id cannot contain /`)
	end,
	child_double_parent = function(entity: unknown, tag: unknown, other: unknown)
		return prefixed(
			`entity {entity} is already a child of kind {other} and cannot also be one of kind {tag}: an entity is a child under one relation at a time`
		)
	end,
	child_kinds_ambiguous = function(entity: unknown, first: unknown, second: unknown)
		return prefixed(`entity {entity} carries the kind tags {first} and {second} on one relation: keep one`)
	end,
	snapshot_on_tag = function(id: unknown)
		return prefixed(`saveable {id} is a tag and cannot carry a snapshot`)
	end,
	lazy_on_tag = function(id: unknown)
		return prefixed(`saveable {id} is a tag and cannot be lazy`)
	end,
	pairs_meta = function(id: unknown, what: string)
		return prefixed(`saveable {id} stores pairs and cannot carry {what}`)
	end,
	pairs_targets_invalid = function(id: unknown)
		return prefixed(`saveable {id}: meta(id, miumiu.pairs, \{ targets = list }) takes a list of entities`)
	end,
	bad_user_ids = function(collection: unknown)
		return prefixed(`collection {collection}: user_ids must be a function of the key returning a list of user ids`)
	end,
	scope_default_twice = function(first: unknown, second: unknown)
		return prefixed(
			`collections {first} and {second} both set default_scope; only one collection can take the unscoped saveables`
		)
	end,
	link_key_invalid = function(entity: unknown, collection: unknown)
		return prefixed(
			`entity {entity} links to collection {collection} without a key: world:set(entity, pair(miumiu.data_link, collection), "key") needs a non-empty string`
		)
	end,
})

local warnings = table.freeze({
	batch_refused = function(id: string, keys: { string }, message: string)
		return prefixed(`batch {id} on "{table.concat(keys, '", "')}" refused and rolled back: {message}`)
	end,
	rollback_failed = function(id: string, err: unknown)
		return prefixed(`rollback of batch {id} threw and may be incomplete: {err}`)
	end,
	hook_failed = function(owner: unknown, hook: unknown, err: unknown)
		return prefixed(`{hook} callback on {owner} failed: {err}`)
	end,
	pull_failed = function(key: string, err: unknown)
		return prefixed(`pull of "{key}" failed, retrying on the next interval: {err}`)
	end,
	unload_failed = function(key: string, err: unknown)
		return prefixed(`final write of "{key}" failed, the session keeps retrying: {err}`)
	end,
	settle_failed = function(id: string, err: unknown)
		return prefixed(`batch {id} was committed but a settling pull failed; the next pull folds it: {err}`)
	end,
	unguarded = function(keys: { string })
		return prefixed(
			`saveables without a guard: {table.concat(keys, ", ")}; meta(id, miumiu.guard, check) validates what is written and loaded`
		)
	end,
	deserialize_failed = function(key: string, entity: unknown, err: unknown)
		return prefixed(`stored value of "{key}" for {entity} could not be deserialized and was skipped: {err}`)
	end,
	stored_rejected = function(key: string, entity: unknown, message: string?)
		return prefixed(`stored value of "{key}" for {entity} failed its guard and was skipped{suffix(message)}`)
	end,
	unlink_refused = function(key: string, reason: string)
		return prefixed(`final write of "{key}" after unlink was refused and its unwritten changes are lost: {reason}`)
	end,
	commit_lookup_failed = function(id: string, err: unknown)
		return prefixed(`could not look up commit "{id}": {err}`)
	end,
	pull_recovered = function(key: string)
		return prefixed(`pull of "{key}" succeeded again`)
	end,
	migration_deserialize_failed = function(key: string, record_key: string, err: unknown)
		return prefixed(
			`stored value of "{key}" in record "{record_key}" could not be deserialized and was skipped by the migration: {err}`
		)
	end,
	fast_pull = function(collection: unknown, interval: number, cooldown: number)
		return prefixed(
			`collection {collection} pulls every {interval}s, under the {cooldown}s DataStore write cooldown per key: back-to-back writes wait for the cooldown`
		)
	end,
	snapshot_failed = function(key: string, entity: unknown, err: unknown)
		return prefixed(`snapshot of "{key}" for {entity} failed and was not written: {err}`)
	end,
	close_dropped = function(key: string, reason: string)
		return prefixed(`final write of "{key}" on close was refused and its unwritten changes are lost: {reason}`)
	end,
	child_invalid = function(key: string, id: string, entity: unknown)
		return prefixed(`stored child "{key}.{id}" of {entity} is not a table and was skipped`)
	end,
	unsaved_write = function(key: string, entity: unknown, holder: unknown)
		return prefixed(
			`"{key}" written on {entity} is not a field of {holder} and was not saved; pair(miumiu.field_of, target) declares where it lives`
		)
	end,
	child_unnamed_existing = function(entity: unknown, tag: unknown)
		return prefixed(
			`attached child {entity} of kind {tag} existed before the first step without an id and is not indexed: set its id component before the pair`
		)
	end,
	child_indexing_failed = function(entity: unknown, err: unknown)
		return prefixed(`child {entity} existed before the first step and could not be indexed: {err}`)
	end,
	name_shared = function(name: string, first: unknown, second: unknown)
		return prefixed(
			`entities {first} and {second} both carry the jecs.Name "{name}"; pairs to the one that lost the name are not stored`
		)
	end,
	pair_target_unnamed = function(key: string, entity: unknown, target: string)
		return prefixed(
			`pair under "{key}" on {entity} points at entity {target}, which has no jecs.Name, and was left out of the record`
		)
	end,
	pair_target_unknown = function(key: string, name: string, entity: unknown)
		return prefixed(
			`stored pair under "{key}" names "{name}", which no entity in the world carries as its jecs.Name; {entity} did not get it`
		)
	end,
	child_group_array = function(key: string)
		return prefixed(
			`stored children under "{key}" are keyed by numbers, not ids, and were left alone; a migration through context.legacy("{key}") turns them into children`
		)
	end,
	child_unheld = function(entity: unknown, tag: unknown, parent: unknown)
		return prefixed(
			`{entity} of kind {tag} under {parent} is not a child: the parent does not hold that kind; pair(miumiu.field_of, target) declares where it nests`
		)
	end,
})

local closures = table.freeze({
	abandoned = function(key: string, reason: string)
		return prefixed(
			`final write of "{key}" on close failed and its unwritten changes are lost with this server: {reason}`
		)
	end,
})

return table.freeze({
	reasons = reasons,
	closures = closures,
	errors = errors,
	warnings = warnings,
})
