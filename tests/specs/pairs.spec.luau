return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local jecs = require(ReplicatedStorage.Packages.jecs)
	local miumiu = require(ReplicatedStorage.Packages.miumiu)
	local schema = require(ReplicatedStorage.Packages.miumiu.schema)
	local util = require(ReplicatedStorage.Packages.miumiu.util)
	local utils = require(ReplicatedStorage.Tests.utils)

	type Entity<T = nil> = miumiu.Entity<T>
	type Fixture = utils.Fixture

	afterEach(utils.cleanup)

	local never = utils.timings.never

	type Relations = {
		has_buff: Entity,
		stack: Entity<number>,
		fire: Entity,
		ice: Entity,
		owns: Entity,
		item: Entity,
		holds: Entity,
		plot: Entity,
		plot_kind: Entity<string>,
	}

	local function declare(t: Fixture): Relations
		local world = t.world
		local relations = utils.declare_relations(world, {})
		local has_buff, fire, ice = relations.has_buff, relations.fire, relations.ice
		local stack = world:component()
		world:set(stack, jecs.Name, "stack")
		world:set(stack, miumiu.saveable, "stacks")
		world:add(stack, miumiu.pairs)
		local kinds = utils.declare_kinds(world, t.player_data)
		local owns, item, holds, plot, plot_kind =
			kinds.owns, kinds.item, kinds.holds, kinds.container, kinds.container_kind
		utils.scope(world, { has_buff }, { item, plot, t.player_data })
		utils.scope(world, { stack }, { t.player_data })
		utils.scope(world, { t.items }, { item })
		return {
			has_buff = has_buff,
			stack = stack,
			fire = fire,
			ice = ice,
			owns = owns,
			item = item,
			holds = holds,
			plot = plot,
			plot_kind = plot_kind,
		}
	end

	local function setup()
		local t = utils.create_fixture({ pull_interval = never })
		return t, declare(t)
	end

	local function buffs_of(t: Fixture, r: Relations, entity: Entity): { [string]: boolean }
		local names = {}
		for _, target in util.targets_of(t.world, entity, r.has_buff) do
			names[t.world:get(target, jecs.Name) or "?"] = true
		end
		return names
	end

	describe("saveable pairs", function()
		it("store tag pairs as a dictionary keyed by target name and component pairs with their values", function()
			local t, r = setup()
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			t.world:add(player, jecs.pair(r.has_buff, r.fire))
			t.world:add(player, jecs.pair(r.has_buff, r.ice))
			t.world:set(player, jecs.pair(r.stack, r.fire), 3)
			session:sync()
			local data = t.backend:dump("p1").data
			expect(data.buffs.fire).to.equal(true)
			expect(data.buffs.ice).to.equal(true)
			expect(data.stacks.fire).to.equal(3)
			t.world:remove(player, jecs.pair(r.has_buff, r.fire))
			t.world:set(player, jecs.pair(r.stack, r.fire), 5)
			session:sync()
			data = t.backend:dump("p1").data
			expect(data.buffs.fire).to.equal(nil)
			expect(data.buffs.ice).to.equal(true)
			expect(data.stacks.fire).to.equal(5)
			t.world:remove(player, jecs.pair(r.has_buff, r.ice))
			session:sync()
			expect(t.backend:dump("p1").data.buffs).to.equal(nil)
			expect(session:is_dirty()).to.equal(false)
		end)

		it("apply stored pairs on load and follow changes from elsewhere", function()
			local t, r = setup()
			t.backend:seed("p1", { data = { buffs = { fire = true }, stacks = { ice = 2 } } })
			local player = utils.link_entity(t, "p1")
			expect(t.world:has(player, jecs.pair(r.has_buff, r.fire))).to.equal(true)
			expect(t.world:get(player, jecs.pair(r.stack, r.ice))).to.equal(2)
			local session = utils.session_of(t, "p1")
			local remote = utils.other_server(t, "p1")
			utils.journal(remote, { utils.set("buffs", { ice = true }, os.time()), utils.remove("stacks", os.time()) })
			remote:sync()
			session:sync()
			miumiu.step(t.world)
			expect(t.world:has(player, jecs.pair(r.has_buff, r.ice))).to.equal(true)
			expect(t.world:has(player, jecs.pair(r.has_buff, r.fire))).to.equal(false)
			expect(t.world:has(player, jecs.pair(r.stack, r.ice))).to.equal(false)
			expect(session:is_dirty()).to.equal(false)
			utils.journal(remote, { utils.set("buffs", { ice = true }, os.time()), utils.remove("buffs", os.time()) })
			remote:sync()
			session:sync()
			miumiu.step(t.world)
			expect(t.world:has(player, jecs.pair(r.has_buff, r.ice))).to.equal(false)
			remote:unload()
		end)

		it("warn once for an unnamed target, an unknown stored name and a stored value that is not a table", function()
			local t, r = setup()
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			local nameless = t.world:entity()
			t.world:add(player, jecs.pair(r.has_buff, nameless))
			t.world:add(player, jecs.pair(r.has_buff, r.fire))
			session:sync()
			expect(utils.warning_count(t.backend, "has no jecs.Name")).to.equal(1)
			local data = t.backend:dump("p1").data
			expect(data.buffs.fire).to.equal(true)
			expect((next(data.buffs, "fire"))).to.equal(nil)
			t.backend:seed("p2", { data = { buffs = { ghost = true, fire = true }, stacks = "nope" } })
			local other = utils.link_entity(t, "p2")
			expect(t.world:has(other, jecs.pair(r.has_buff, r.fire))).to.equal(true)
			expect(utils.warning_count(t.backend, "no entity in the world carries")).to.equal(1)
			expect(utils.warned(t.backend, "keyed by target name")).to.equal(true)
		end)

		it("resolve targets named, renamed or deleted after the first step", function()
			local t, r = setup()
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			local poison = t.world:entity()
			t.world:set(poison, jecs.Name, "poison")
			local remote = utils.other_server(t, "p1")
			utils.journal(remote, { utils.set("buffs", { poison = true }, os.time()) })
			remote:sync()
			session:sync()
			miumiu.step(t.world)
			expect(t.world:has(player, jecs.pair(r.has_buff, poison))).to.equal(true)
			t.world:set(poison, jecs.Name, "venom")
			utils.journal(remote, { utils.set("buffs", { venom = true, fire = true }, os.time()) })
			remote:sync()
			session:sync()
			miumiu.step(t.world)
			expect(t.world:has(player, jecs.pair(r.has_buff, r.fire))).to.equal(true)
			expect(t.world:has(player, jecs.pair(r.has_buff, poison))).to.equal(true)
			t.world:delete(poison)
			session:sync()
			expect(t.backend:dump("p1").data.buffs.venom).to.equal(nil)
			utils.journal(remote, { utils.set("buffs", { venom = true }, os.time() + 10) })
			remote:sync()
			session:sync()
			miumiu.step(t.world)
			expect(utils.warned(t.backend, "no entity in the world carries")).to.equal(true)
			expect(t.world:has(player, jecs.pair(r.has_buff, r.fire))).to.equal(false)
			remote:unload()
		end)

		it("roll pairs back with a batch, keep ones changed meanwhile, and refuse them in delta", function()
			local t = utils.create_fixture({ pull_interval = never, retry_attempts = 1 })
			local r = declare(t)
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			t.world:add(player, jecs.pair(r.has_buff, r.fire))
			session:sync()
			expect(function()
				miumiu.batch(t.world, function()
					t.world:add(player, jecs.pair(r.has_buff, r.ice))
					t.world:set(player, jecs.pair(r.stack, r.fire), 2)
					t.world:remove(player, jecs.pair(r.has_buff, r.fire))
					error("boom")
				end)
			end).to.throw("boom")
			expect(buffs_of(t, r, player).fire).to.equal(true)
			expect(buffs_of(t, r, player).ice).to.equal(nil)
			expect(t.world:has(player, jecs.pair(r.stack, r.fire))).to.equal(false)
			expect(function()
				miumiu.delta(t.world, function()
					t.world:add(player, jecs.pair(r.has_buff, r.ice))
				end)
			end).to.throw("not a delta")
			expect(buffs_of(t, r, player).ice).to.equal(nil)
			expect(session:is_dirty()).to.equal(false)

			local writes = t.backend.calls.UpdateAsync
			t.backend:delay_next("UpdateAsync", utils.timings.in_flight, "before")
			t.backend:fail_next("UpdateAsync", "before", "store down")
			local batch = miumiu.batch(t.world, function()
				t.world:add(player, jecs.pair(r.has_buff, r.ice))
			end)
			task.spawn(batch.await, batch)
			expect(utils.wait_until(function()
				return t.backend.calls.UpdateAsync > writes
			end)).to.equal(true)
			local poison = t.world:entity()
			t.world:set(poison, jecs.Name, "poison")
			t.world:add(player, jecs.pair(r.has_buff, poison))
			expect(utils.wait_settled(batch)).to.equal(true)
			expect(batch:get_outcome().kind).to.equal("refused")
			expect(buffs_of(t, r, player).ice).to.equal(true)
			expect(buffs_of(t, r, player).poison).to.equal(true)
		end)

		it("pack pairs on children and supply them back", function()
			local t, r = setup()
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			local sword = t.world:entity()
			t.world:add(sword, r.item)
			t.world:add(sword, jecs.pair(r.owns, player))
			t.world:add(sword, jecs.pair(r.has_buff, r.fire))
			session:sync()
			local id = utils.id_of(t, sword)
			expect(t.backend:dump("p1").data.inventory[id].buffs.fire).to.equal(true)
			t.world:remove(player, t.link)
			miumiu.step(t.world)
			expect(t.world:contains(sword)).to.equal(false)
			local again = utils.link_entity(t, "p1")
			local found = nil
			for entity in t.world:each(jecs.pair(r.owns, again)) do
				found = entity
			end
			assert(found)
			expect(t.world:has(found, jecs.pair(r.has_buff, r.fire))).to.equal(true)
		end)

		it("reset an attached child's pairs to its claim-time set when it is released", function()
			local t, r = setup()
			local plot = t.world:entity()
			t.world:add(plot, r.plot)
			t.world:set(plot, r.plot_kind, "home")
			t.world:add(plot, jecs.pair(r.has_buff, r.fire))
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			t.world:add(plot, jecs.pair(r.holds, player))
			t.world:add(plot, jecs.pair(r.has_buff, r.ice))
			session:sync()
			local stored = t.backend:dump("p1").data.containers.home.buffs
			expect(stored.fire).to.equal(true)
			expect(stored.ice).to.equal(true)
			t.world:remove(plot, jecs.pair(r.holds, player))
			miumiu.step(t.world)
			expect(t.world:has(plot, jecs.pair(r.has_buff, r.fire))).to.equal(true)
			expect(t.world:has(plot, jecs.pair(r.has_buff, r.ice))).to.equal(false)
		end)

		it("take a pair back when the child it sits on cannot be packed", function()
			local t, r = setup()
			local fail = false
			t.world:set(t.items, miumiu.serdes, {
				serialize = function(value)
					if fail then
						error("no")
					end
					return value
				end,
				deserialize = function(value)
					return value
				end,
			})
			local player = utils.link_entity(t, "p1")
			local sword = t.world:entity()
			t.world:add(sword, r.item)
			t.world:set(sword, t.items, { "gem" })
			t.world:add(sword, jecs.pair(r.owns, player))
			fail = true
			expect(function()
				t.world:add(sword, jecs.pair(r.has_buff, r.fire))
			end).to.throw("no")
			expect(t.world:has(sword, jecs.pair(r.has_buff, r.fire))).to.equal(false)
		end)

		it("reject a guard, serdes, snapshot or lazy on a pairs saveable", function()
			local extras = {
				{ id = miumiu.guard, value = function() end, message = "a guard" },
				{ id = miumiu.serdes, value = utils.create_set_serdes(), message = "serdes" },
				{ id = miumiu.snapshot, value = function() end, message = "a snapshot" },
				{ id = miumiu.lazy, value = nil, message = "lazy" },
			}
			for _, extra in extras do
				local bare = jecs.world()
				local relation = utils.declare_saveable(bare, "component", "buffs", {})
				bare:add(relation, miumiu.pairs)
				if extra.value == nil then
					bare:add(relation, extra.id)
				else
					bare:set(relation, extra.id, extra.value)
				end
				expect(function()
					schema.create_schema(bare)
				end).to.throw(`cannot carry {extra.message}`)
			end
		end)

		it("migrate pairs through the scratch world and read the raw record", function()
			local t, r = setup()
			local seen = nil
			t.world:set(t.player_data, miumiu.migrations, {
				function(world, entity, context)
					seen = context.stored
					expect(world:has(entity, jecs.pair(r.has_buff, r.fire))).to.equal(true)
					expect(world:get(entity, jecs.pair(r.stack, r.fire))).to.equal(1)
					world:add(entity, jecs.pair(r.has_buff, r.ice))
					world:remove(entity, jecs.pair(r.stack, r.fire))
					world:set(entity, jecs.pair(r.stack, r.ice), 4)
					local child = nil
					for candidate in world:each(jecs.pair(r.owns, entity)) do
						child = candidate
					end
					assert(child)
					expect(world:has(child, jecs.pair(r.has_buff, r.fire))).to.equal(true)
					world:remove(child, jecs.pair(r.has_buff, r.fire))
				end,
			})
			t.backend:seed("p1", {
				data = {
					buffs = { fire = true },
					stacks = { fire = 1 },
					inventory = { a = { buffs = { fire = true } } },
				},
			})
			local player = utils.link_entity(t, "p1")
			assert(seen)
			expect(seen.buffs.fire).to.equal(true)
			expect(function()
				seen.buffs = nil
			end).to.throw()
			expect(function()
				seen.inventory.a.buffs = nil
			end).to.throw()
			local data = t.backend:dump("p1").data
			expect(data.buffs.fire).to.equal(true)
			expect(data.buffs.ice).to.equal(true)
			expect(data.stacks.fire).to.equal(nil)
			expect(data.stacks.ice).to.equal(4)
			expect(data.inventory.a.buffs).to.equal(nil)
			expect(t.world:has(player, jecs.pair(r.has_buff, r.ice))).to.equal(true)
			expect(t.world:get(player, jecs.pair(r.stack, r.ice))).to.equal(4)
			t.backend:seed("p2", { data = { stacks = "nope" } })
			local other = utils.link_entity(t, "p2")
			expect(t.world:has(other, r.stack)).to.equal(false)
		end)
	end)

	describe("regressions", function()
		it("keeps pairs to two targets that share a name and warns once per name", function()
			local t, r = setup()
			local a = t.world:entity()
			t.world:set(a, jecs.Name, "twin")
			local b = t.world:entity()
			t.world:set(b, jecs.Name, "twin")
			local player = utils.link_entity(t, "p1")
			expect(utils.warning_count(t.backend, "both carry the jecs.Name")).to.equal(0)
			t.world:add(player, jecs.pair(r.has_buff, a))
			t.world:add(player, jecs.pair(r.has_buff, b))
			local session = utils.session_of(t, "p1")
			session:sync()
			expect(utils.warning_count(t.backend, "both carry the jecs.Name")).to.equal(1)
			miumiu.step(t.world)
			expect(t.world:has(player, jecs.pair(r.has_buff, a))).to.equal(true)
			expect(t.world:has(player, jecs.pair(r.has_buff, b))).to.equal(true)
			expect(t.backend:dump("p1").data.buffs.twin).to.equal(true)
			local c = t.world:entity()
			t.world:set(c, jecs.Name, "fire")
			expect(utils.warning_count(t.backend, "both carry the jecs.Name")).to.equal(2)
			t.world:add(player, jecs.pair(r.has_buff, r.fire))
			session:sync()
			expect(t.backend:dump("p1").data.buffs.fire).to.equal(true)
			expect(t.world:has(player, jecs.pair(r.has_buff, r.fire))).to.equal(true)
		end)

		it("keeps a component pair added without a value out of the record and on the entity", function()
			local t, r = setup()
			local player = utils.link_entity(t, "p1")
			t.world:add(player, jecs.pair(r.stack, r.fire))
			local session = utils.session_of(t, "p1")
			session:sync()
			miumiu.step(t.world)
			expect(t.world:has(player, jecs.pair(r.stack, r.fire))).to.equal(true)
			expect(t.backend:dump("p1").data.stacks).to.equal(nil)
		end)

		it("stops answering to the old name once a target is renamed", function()
			local t, r = setup()
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			local poison = t.world:entity()
			t.world:set(poison, jecs.Name, "poison")
			miumiu.step(t.world)
			t.world:set(poison, jecs.Name, "venom")
			local remote = utils.other_server(t, "p1")
			utils.journal(remote, { utils.set("buffs", { poison = true }, os.time() + 10) })
			remote:sync()
			session:sync()
			miumiu.step(t.world)
			remote:unload()
			expect(t.world:has(player, jecs.pair(r.has_buff, poison))).to.equal(false)
			expect(utils.warning_count(t.backend, "no entity in the world carries")).to.equal(1)
		end)

		it("keeps migration names out of the game world's name index", function()
			local t = utils.create_fixture({ pull_interval = never })
			t.world:set(t.player_data, miumiu.migrations, {
				function(world, entity, context)
					world:remove(entity, context.legacy("luck"))
				end,
			})
			t.backend:seed("p1", { data = { luck = 1 } })
			local player = utils.link_entity(t, "p1")
			expect(t.world:has(player, t.loaded)).to.equal(true)
			expect(schema.get(t.world).named["miumiu.legacy.luck"]).to.equal(nil)
		end)

		it("stores only the targets a pairs config lists and rejects a bad list", function()
			local t = utils.create_fixture({ pull_interval = never })
			local r = declare(t)
			t.world:set(r.has_buff, miumiu.pairs, { targets = { r.fire } })
			t.world:set(r.stack, miumiu.pairs, {})
			t.backend:seed("p1", { data = { buffs = { ice = true, fire = true }, stacks = { ice = 2 } } })
			local player = utils.link_entity(t, "p1")
			expect(t.world:get(player, jecs.pair(r.stack, r.ice))).to.equal(2)
			expect(t.world:has(player, jecs.pair(r.has_buff, r.fire))).to.equal(true)
			expect(t.world:has(player, jecs.pair(r.has_buff, r.ice))).to.equal(false)
			expect(utils.warned(t.backend, "no entity in the world carries")).to.equal(false)
			t.world:add(player, jecs.pair(r.has_buff, r.ice))
			local session = utils.session_of(t, "p1")
			session:sync()
			expect(t.backend:dump("p1").data.buffs.ice).to.equal(nil)
			local remote = utils.other_server(t, "p1")
			utils.journal(remote, { utils.set("buffs", { fire = true }, os.time() + 10) })
			remote:sync()
			session:sync()
			miumiu.step(t.world)
			remote:unload()
			expect(t.world:has(player, jecs.pair(r.has_buff, r.ice))).to.equal(true)
			for _, config in { { targets = 5 }, { targets = { "fire" } } } do
				local bare = jecs.world()
				local relation = utils.declare_saveable(bare, "tag", "buffs", {})
				bare:set(relation, miumiu.pairs, config)
				expect(function()
					schema.create_schema(bare)
				end).to.throw("takes a list of entities")
			end
		end)

		it("removing a pair from an attached child reaches the record", function()
			local t, r = setup()
			local plot = t.world:entity()
			t.world:add(plot, r.plot)
			t.world:set(plot, r.plot_kind, "home")
			t.world:add(plot, jecs.pair(r.has_buff, r.fire))
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			t.world:add(plot, jecs.pair(r.holds, player))
			t.world:remove(plot, jecs.pair(r.has_buff, r.fire))
			session:sync()
			expect(t.backend:dump("p1").data.containers.home.buffs).to.equal(nil)
		end)

		it("deleting a pair target paired on a child drops it without a warning", function()
			local t, r = setup()
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			local sword = t.world:entity()
			t.world:add(sword, r.item)
			t.world:add(sword, jecs.pair(r.owns, player))
			t.world:add(sword, jecs.pair(r.has_buff, r.fire))
			session:sync()
			t.world:delete(r.fire)
			session:sync()
			expect(utils.warned(t.backend, "both carry")).to.equal(false)
			expect(utils.warned(t.backend, "has no jecs.Name")).to.equal(false)
			local id = utils.id_of(t, sword)
			expect(t.backend:dump("p1").data.inventory[id].buffs).to.equal(nil)
		end)

		it("world:clear removes the pair set from the record, inside a batch too", function()
			local t, r = setup()
			local player = utils.link_entity(t, "p1", { money = 3 })
			local session = utils.session_of(t, "p1")
			t.world:add(player, jecs.pair(r.has_buff, r.fire))
			t.world:add(player, jecs.pair(r.has_buff, r.ice))
			session:sync()
			expect(t.backend:dump("p1").data.buffs.fire).to.equal(true)
			t.world:clear(player)
			session:sync()
			local data = t.backend:dump("p1").data
			expect(data.money).to.equal(nil)
			expect(data.buffs).to.equal(nil)
			t.world:set(player, t.money, 4)
			t.world:add(player, jecs.pair(r.has_buff, r.fire))
			t.world:add(player, jecs.pair(r.has_buff, r.ice))
			session:sync()
			expect(t.backend:dump("p1").data.buffs.ice).to.equal(true)
			miumiu
				.batch(t.world, function()
					t.world:clear(player)
				end)
				:await()
			data = t.backend:dump("p1").data
			expect(data.money).to.equal(nil)
			expect(data.buffs).to.equal(nil)
		end)

		it("keeps the shadow intact when a removal is rejected inside delta", function()
			local t, r = setup()
			local player = utils.link_entity(t, "p1", { money = 1 })
			t.world:add(player, jecs.pair(r.has_buff, r.fire))
			t.world:add(player, jecs.pair(r.has_buff, r.ice))
			local session = utils.session_of(t, "p1")
			session:sync()
			expect(function()
				miumiu.delta(t.world, function()
					t.world:remove(player, t.money)
				end)
			end).to.throw("not a delta")
			expect(t.world:get(player, t.money)).to.equal(1)
			expect(function()
				miumiu.delta(t.world, function()
					t.world:remove(player, jecs.pair(r.has_buff, r.fire))
				end)
			end).to.throw("not a delta")
			expect(t.world:has(player, jecs.pair(r.has_buff, r.fire))).to.equal(true)
			expect(function()
				miumiu.batch(t.world, function()
					t.world:set(player, t.money, 5)
					t.world:remove(player, jecs.pair(r.has_buff, r.ice))
					error("nope")
				end)
			end).to.throw("nope")
			expect(t.world:get(player, t.money)).to.equal(1)
			expect(t.world:has(player, jecs.pair(r.has_buff, r.fire))).to.equal(true)
			expect(t.world:has(player, jecs.pair(r.has_buff, r.ice))).to.equal(true)
			expect(session:is_dirty()).to.equal(false)
		end)

		it("packs pairs of a target whose name a deleted entity had usurped without throwing", function()
			local t = utils.create_fixture({ pull_interval = never })
			local relations = utils.declare_relations(t.world, { t.player_data })
			local player = utils.link_entity(t, "p1")
			t.world:add(player, jecs.pair(relations.has_buff, relations.fire))
			local session = utils.session_of(t, "p1")
			session:sync()
			t.world:set(relations.ice, jecs.Name, "fire")
			t.world:delete(relations.ice)
			local remote = utils.other_server(t, "p1")
			utils.journal(remote, { utils.set("tutorial", true, os.time() + 5) })
			remote:sync()
			session:sync()
			expect(function()
				miumiu.step(t.world)
			end).never.to.throw()
			expect(function()
				t.world:remove(player, jecs.pair(relations.has_buff, relations.fire))
			end).never.to.throw()
			expect(t.backend:dump("p1").data.buffs.fire).to.equal(true)
			remote:unload()
		end)

		it("naming a second entity after a pair target leaves the stored pair alone on supply", function()
			local t = utils.create_fixture({ pull_interval = never })
			local r = utils.declare_relations(t.world, { t.player_data })
			local player = utils.link_entity(t, "p1")
			t.world:add(player, jecs.pair(r.has_buff, r.fire))
			local session = utils.session_of(t, "p1")
			session:sync()
			expect(t.backend:dump("p1").data.buffs.fire).to.equal(true)
			local impostor = t.world:entity()
			t.world:set(impostor, jecs.Name, "fire")
			local remote = utils.other_server(t, "p1")
			utils.journal(remote, { utils.set("money", 3, os.time() + 5) })
			remote:sync()
			session:sync()
			miumiu.step(t.world)
			remote:unload()
			expect(t.world:has(player, jecs.pair(r.has_buff, r.fire))).to.equal(true)
			expect(t.world:has(player, jecs.pair(r.has_buff, impostor))).to.equal(false)
		end)

		it("packs a pair to a namesake that outlived the name's first owner", function()
			local t = utils.create_fixture({ pull_interval = never })
			local r = utils.declare_relations(t.world, { t.player_data })
			local player = utils.link_entity(t, "p1")
			local namesake = t.world:entity()
			t.world:set(namesake, jecs.Name, "fire")
			t.world:delete(r.fire)
			t.world:add(player, jecs.pair(r.has_buff, namesake))
			local session = utils.session_of(t, "p1")
			expect(function()
				session:sync()
			end).never.to.throw()
			expect(t.backend:dump("p1").data.buffs.fire).to.equal(true)
		end)
	end)
end
