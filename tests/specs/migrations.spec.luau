return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local miumiu = require(ReplicatedStorage.Packages.miumiu)
	local utils = require(ReplicatedStorage.Tests.utils)

	afterEach(utils.cleanup)

	local never = utils.timings.never
	local setup = utils.create_fixture
	local settle = utils.settle

	describe("migrations", function()
		it("runs missing migrations once on a template entity in a scratch world", function()
			local runs = 0
			local t = setup({ pull_interval = never })
			local seen_key = nil
			local seen_world = nil
			t.world:set(t.player_data, miumiu.migrations, {
				function(world, entity, context)
					runs += 1
					seen_key = context.key
					seen_world = world
					local luck_boosts = context.legacy("luck_boosts")
					local legacy = world:get(entity, luck_boosts) or {}
					world:set(entity, t.money, #legacy)
					world:remove(entity, luck_boosts)
					local untouched = context.legacy("untouched")
					expect(world:get(entity, untouched)).to.equal("still here")
				end,
				function(world, entity)
					runs += 1
					world:add(entity, t.tutorial)
				end,
			})
			t.backend:seed("p1", { data = { luck_boosts = { 1, 2, 3 }, untouched = "still here", ignored = 1 } })

			local old = t.world:entity()
			t.world:set(old, t.link, "p1")
			settle(t, old)
			expect(t.world:get(old, t.money)).to.equal(3)
			expect(t.world:has(old, t.tutorial)).to.equal(true)
			expect(runs).to.equal(2)
			local record = t.backend:dump("p1")
			expect(record.data.money).to.equal(3)
			expect(record.data.tutorial).to.equal(true)
			expect(record.data.luck_boosts).to.equal(nil)
			expect(record.data.untouched).to.equal("still here")
			expect(record.data.ignored).to.equal(1)
			expect(record.migrations).to.equal(2)
			expect(seen_key).to.equal("p1")
			expect(seen_world).never.to.equal(t.world)
		end)

		it("context.legacy rejects current saveables and absent keys", function()
			local t = setup({ pull_interval = never })
			t.world:set(t.player_data, miumiu.migrations, {
				function(_, _, context)
					expect(function()
						context.legacy("money")
					end).to.throw("current saveable")
					expect(function()
						context.legacy("never_stored")
					end).to.throw("no stored value")
				end,
			})
			t.backend:seed("p1", { data = { money = 1 } })
			local player = t.world:entity()
			t.world:set(player, t.link, "p1")
			settle(t, player)
			expect(t.world:has(player, t.loaded)).to.equal(true)
		end)

		it("skips migrated records and stamps fresh ones without running anything", function()
			local runs = 0
			local t = setup({ pull_interval = never })
			t.world:set(t.player_data, miumiu.migrations, {
				function()
					runs += 1
				end,
				function()
					runs += 1
				end,
			})
			t.backend:seed("p2", { data = { money = 9 }, migrations = 2 })

			local current = t.world:entity()
			t.world:set(current, t.link, "p2")
			settle(t, current)
			expect(t.world:get(current, t.money)).to.equal(9)
			expect(runs).to.equal(0)

			local fresh = t.world:entity()
			t.world:set(fresh, t.link, "p3")
			settle(t, fresh)
			expect(runs).to.equal(0)
			utils.journal(utils.session_of(t, "p3"), { utils.add("money", 1) })
			utils.session_of(t, "p3"):sync()
			expect(t.backend:dump("p3").migrations).to.equal(2)
		end)

		it("fails only the key whose migration throws when several load together", function()
			local t = setup({ pull_interval = never })
			t.world:set(t.player_data, miumiu.migrations, {
				function(world, entity)
					if world:get(entity, t.money) == 13 then
						error("unlucky")
					end
				end,
			})
			t.backend:seed("p1", { data = { money = 1 } })
			t.backend:seed("p2", { data = { money = 13 } })
			local lucky = t.world:entity()
			t.world:set(lucky, t.link, "p1")
			local unlucky = t.world:entity()
			t.world:set(unlucky, t.link, "p2")
			settle(t, lucky)
			settle(t, unlucky)
			expect(t.world:has(lucky, t.loaded)).to.equal(true)
			expect(t.backend:dump("p1").migrations).to.equal(1)
			expect((string.find(t.world:get(unlucky, t.data_error), "unlucky"))).to.be.ok()
			expect(t.backend:dump("p2").migrations).to.equal(nil)
		end)

		it("fails the load when the foreign read throws", function()
			local t = setup({ pull_interval = never })
			t.world:set(t.player_data, miumiu.from_foreign, {
				type = "lapis",
				name = "Old",
				source = {
					createCollection = function()
						return {
							read = function()
								return {
									expect = function()
										error("lapis down")
									end,
								}
							end,
						}
					end,
				},
				options = {},
			})
			local player = t.world:entity()
			t.world:set(player, t.link, "p1")
			settle(t, player)
			expect((string.find(t.world:get(player, t.data_error), "lapis down"))).to.be.ok()
			expect(t.backend:dump("p1")).to.equal(nil)
		end)

		it("fails the load for a newer record or a throwing migration", function()
			local t = setup({ pull_interval = never })
			t.world:set(t.player_data, miumiu.migrations, {
				function()
					error("cannot")
				end,
			})
			t.backend:seed("p1", { data = { money = 1 }, migrations = 5 })
			t.backend:seed("p2", { data = { money = 1 } })

			local newer = t.world:entity()
			t.world:set(newer, t.link, "p1")
			settle(t, newer)
			expect((string.find(t.world:get(newer, t.data_error), "newer server"))).to.be.ok()

			local broken = t.world:entity()
			t.world:set(broken, t.link, "p2")
			settle(t, broken)
			expect((string.find(t.world:get(broken, t.data_error), "cannot"))).to.be.ok()
			expect(t.backend:dump("p2").migrations).to.equal(nil)
			expect(t.backend:dump("p2").data.money).to.equal(1)
		end)

		it("imports from lapis once, through the lapis library", function()
			local docs = { p1 = { coins = 5, tutorial = true } }
			local lapis = { created = {} }
			function lapis.createCollection(name, options)
				local created = { name = name, options = options, reads = 0 }
				lapis.created[name] = created
				function created:read(key)
					self.reads += 1
					return {
						expect = function()
							return docs[key]
						end,
					}
				end
				return created
			end

			local t = setup({ pull_interval = never })
			local options = { defaultData = {} }
			t.world:set(t.player_data, miumiu.from_foreign, {
				type = "lapis",
				name = "LapisPlayers",
				source = lapis,
				options = options,
			})
			t.world:set(t.player_data, miumiu.migrations, {
				function(world, entity, context)
					local coins = context.legacy("coins")
					world:set(entity, t.money, world:get(entity, coins))
					world:remove(entity, coins)
				end,
			})
			t.backend:seed("p2", { data = { money = 9 }, migrations = 1 })

			local imported = t.world:entity()
			t.world:set(imported, t.link, "p1")
			settle(t, imported)
			expect(t.world:get(imported, t.money)).to.equal(5)
			expect(t.world:has(imported, t.tutorial)).to.equal(true)
			local record = t.backend:dump("p1")
			expect(record.data.money).to.equal(5)
			expect(record.data.coins).to.equal(nil)
			expect(record.migrations).to.equal(1)
			expect(lapis.created.LapisPlayers.options).to.equal(options)
			expect(lapis.created.LapisPlayers.reads).to.equal(1)
			expect(docs.p1.coins).to.equal(5)

			local existing = t.world:entity()
			t.world:set(existing, t.link, "p2")
			settle(t, existing)
			expect(t.world:get(existing, t.money)).to.equal(9)
			expect(lapis.created.LapisPlayers.reads).to.equal(1)

			local fresh = t.world:entity()
			t.world:set(fresh, t.link, "p3")
			settle(t, fresh)
			expect(t.world:has(fresh, t.money)).to.equal(false)
			expect(lapis.created.LapisPlayers.reads).to.equal(2)
			expect(t.backend:dump("p3")).to.equal(nil)
		end)

		it("a no-op migration keeps initial tags and absent keys absent", function()
			local t = setup({ pull_interval = never })
			t.world:add(t.tutorial, t.tutorial)
			t.world:set(t.player_data, miumiu.migrations, { function() end })
			t.backend:seed("p1", { data = { money = 1 } })
			local player = t.world:entity()
			t.world:set(player, t.link, "p1")
			settle(t, player)
			local record = t.backend:dump("p1")
			expect(record.migrations).to.equal(1)
			expect(record.data.tutorial).to.equal(nil)
			expect(record.data.items).to.equal(nil)
			expect(t.world:has(player, t.tutorial)).to.equal(true)
		end)

		it("migrations run in their own world and see initials", function()
			local t = setup({ pull_interval = never })
			t.world:set(t.money, t.money, 100)
			local seen_world = nil
			t.world:set(t.player_data, miumiu.migrations, {
				function(world, entity)
					seen_world = world
					world:set(entity, t.money, world:get(entity, t.money) + 1)
				end,
			})
			t.backend:seed("p1", { data = {} })
			local player = t.world:entity()
			t.world:set(player, t.link, "p1")
			settle(t, player)
			expect(seen_world).never.to.equal(t.world)
			expect(t.backend:dump("p1").data.money).to.equal(101)
			expect(t.world:get(player, t.money)).to.equal(101)
		end)

		it("fails the load when a migration yields", function()
			local t = setup({ pull_interval = never })
			t.world:set(t.player_data, miumiu.migrations, {
				function()
					task.wait()
				end,
			})
			t.backend:seed("p1", { data = { money = 1 } })
			local player = t.world:entity()
			t.world:set(player, t.link, "p1")
			settle(t, player)
			expect((string.find(t.world:get(player, t.data_error), "yielded"))).to.be.ok()
			expect(t.backend:dump("p1").migrations).to.equal(nil)
		end)

		it("warns and skips a stored value a migration cannot deserialize", function()
			local t = setup({ pull_interval = never })
			local codes = utils.declare_saveable(t.world, "component", "codes")
			t.world:set(codes, miumiu.guard, function(value)
				return type(value) == "table"
			end)
			t.world:set(codes, miumiu.serdes, utils.create_set_serdes())
			local seen = "unset"
			t.world:set(t.player_data, miumiu.migrations, {
				function(world, entity)
					seen = world:get(entity, codes)
				end,
			})
			t.backend:seed("p1", { data = { codes = "garbage" } })
			local player = t.world:entity()
			t.world:set(player, t.link, "p1")
			settle(t, player)
			expect(seen).to.equal(nil)
			expect(t.backend:dump("p1").migrations).to.equal(1)
			local found = false
			for _, warning in t.backend.warnings do
				if
					string.find(warning, "could not be deserialized", 1, true)
					and string.find(warning, "not a list", 1, true)
				then
					found = true
				end
			end
			expect(found).to.equal(true)
		end)
	end)

	describe("regressions", function()
		it("hands out one legacy component per key", function()
			local t = setup({ pull_interval = never })
			t.world:set(t.player_data, miumiu.migrations, {
				function(_, _, context)
					expect(context.legacy("old")).to.equal(context.legacy("old"))
				end,
			})
			t.backend:seed("p1", { data = { old = 1 } })
			local player = t.world:entity()
			t.world:set(player, t.link, "p1")
			settle(t, player)
			expect(t.backend:dump("p1").data.old).to.equal(1)
		end)

		it("runs every migration on a version-less record", function()
			local t = setup({ pull_interval = never })
			t.world:set(t.player_data, miumiu.migrations, {
				function(world, entity, context)
					world:set(entity, t.money, world:get(entity, context.legacy("coins")))
				end,
			})
			t.backend.store:SetAsync("p1", { data = { coins = 9 } })
			local player = t.world:entity()
			t.world:set(player, t.link, "p1")
			settle(t, player)
			expect(t.world:get(player, t.money)).to.equal(9)
			local record = t.backend:dump("p1")
			expect(record.migrations).to.equal(1)
			expect(record.version).to.equal(1)
		end)
	end)
end
