return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local jecs = require(ReplicatedStorage.Packages.jecs)
	local miumiu = require(ReplicatedStorage.Packages.miumiu)

	local components = {
		"collection",
		"config",
		"migrations",
		"from_foreign",
		"saveable",
		"guard",
		"serdes",
		"snapshot",
		"child",
		"child_id",
		"data_link",
		"data_error",
	}
	local tags = { "field_of", "lazy", "data_loading", "data_loaded", "data_shallow" }

	local player_data = jecs.tag()
	jecs.meta(player_data, miumiu.config, { pull_interval = 15 })

	local function id_of(name: string): any
		return miumiu[name]
	end

	describe("ids", function()
		it("are distinct", function()
			local seen = {}
			for _, name in components do
				expect(seen[id_of(name)]).to.equal(nil)
				seen[id_of(name)] = name
			end
			for _, name in tags do
				expect(seen[id_of(name)]).to.equal(nil)
				seen[id_of(name)] = name
			end
		end)

		it("preregister into a new world", function()
			local world = jecs.world()
			for _, name in components do
				expect(world:has(id_of(name), jecs.Component)).to.equal(true)
			end
			for _, name in tags do
				expect(jecs.is_tag(world, id_of(name))).to.equal(true)
			end
		end)

		it("carry a namespaced name", function()
			local world = jecs.world()
			for _, name in components do
				expect(world:get(id_of(name), jecs.Name)).to.equal(`miumiu.{name}`)
			end
			for _, name in tags do
				expect(world:get(id_of(name), jecs.Name)).to.equal(`miumiu.{name}`)
			end
		end)

		it("carry meta declared before the world existed", function()
			local world = jecs.world()
			expect(world:get(player_data, miumiu.config).pull_interval).to.equal(15)
		end)

		it("name their hook symbols", function()
			expect(tostring(miumiu.hooks.pulled)).to.equal("Symbol(pulled)")
			expect(tostring(miumiu.hooks.closed)).to.equal("Symbol(closed)")
			expect(tostring(miumiu.hooks.writing)).to.equal("Symbol(writing)")
		end)

		it("expose default as self for roblox-ts", function()
			expect(miumiu.default).to.equal(miumiu)
		end)
	end)
end
