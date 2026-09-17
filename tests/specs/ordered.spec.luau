return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local jecs = require(ReplicatedStorage.Packages.jecs)
	local miumiu = require(ReplicatedStorage.Packages.miumiu)
	local rankings = require(ReplicatedStorage.Packages.miumiu.rankings)
	local schema = require(ReplicatedStorage.Packages.miumiu.schema)
	local utils = require(ReplicatedStorage.Tests.utils)

	type Entity<T = nil> = miumiu.Entity<T>
	type Fixture = utils.Fixture
	type Overrides = utils.Overrides
	type Period = miumiu.Period

	afterEach(utils.cleanup)

	local never = utils.timings.never
	local bookkeeping = "miumiu.ordered"

	type Clock = { index: number, start: number, period: (now: number) -> Period }

	local function create_clock(index: number): Clock
		local clock = { index = index, start = 0 } :: Clock
		clock.period = function(_now: number)
			return { index = clock.index, start = clock.start, finish = clock.start + 100 }
		end
		return clock
	end

	local function setup(overrides: Overrides?): Fixture
		local t = utils.create_fixture(overrides or { pull_interval = never })
		t.world:set(t.money, t.money, 0)
		return t
	end

	local function record_of(t: Fixture, key: string, name: string): any
		local record = t.backend:dump(key)
		local records = if record then record.data[bookkeeping] else nil
		return if records then records[name] else nil
	end

	local function scores_of(t: Fixture, name: string): { [string]: number }
		local scores = {}
		for _, entry in t.backend:sorted(name) do
			scores[entry.key] = entry.score
		end
		return scores
	end

	describe("ordered stores", function()
		it("pushes the score of a root field after the write that changed it", function()
			local t = setup()
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			expect(t.backend.calls.OrderedSetAsync).to.equal(nil)
			t.world:set(player, t.money, 5)
			session:sync()
			expect(scores_of(t, "coins").p1).to.equal(5)
			expect(t.backend.calls.OrderedSetAsync).to.equal(1)
			expect(record_of(t, "p1", "coins").pushed).to.equal(5)
			session:sync()
			expect(t.backend.calls.OrderedSetAsync).to.equal(1)
			t.world:set(player, t.money, 7)
			session:sync()
			expect(t.backend.calls.OrderedSetAsync).to.equal(2)
			expect(scores_of(t, "coins").p1).to.equal(7)
		end)

		it("leaves a key whose score is still its initial's off the ranking until it scores", function()
			local t = setup()
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			expect(t.backend:dump("p1")).to.equal(nil)
			expect(t.backend.calls.OrderedSetAsync).to.equal(nil)
			t.world:set(player, t.money, 3)
			session:sync()
			expect(scores_of(t, "coins").p1).to.equal(3)
			t.world:set(player, t.money, 0)
			session:sync()
			expect(scores_of(t, "coins").p1).to.equal(0)
			expect(record_of(t, "p1", "coins").pushed).to.equal(0)
		end)

		it("pushes at load when the record's pushed score is behind, in a write of its own", function()
			local t = setup()
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			t.backend:seed("p1", { data = { money = 7 } })
			local player = utils.link_entity(t, "p1")
			expect(t.world:get(player, t.money)).to.equal(7)
			expect(scores_of(t, "coins").p1).to.equal(7)
			expect(record_of(t, "p1", "coins").pushed).to.equal(7)
			expect(t.backend:dump("p1").version).to.equal(2)
			expect(t.backend.calls.UpdateAsync).to.equal(1)
			t.backend:seed("p2", { data = { money = 0 } })
			utils.link_entity(t, "p2")
			expect(t.backend.calls.UpdateAsync).to.equal(1)
			expect(t.backend:dump("p2").version).to.equal(1)
			expect(scores_of(t, "coins").p2).to.equal(nil)
		end)

		it("removes the entry when the map leaves the key unranked", function()
			local t = setup()
			utils.declare_ordered(t.world, t.player_data, "coins", {
				component = t.money,
				map = function(stored)
					return if stored > 0 then stored else nil
				end,
			})
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			t.world:set(player, t.money, 5)
			session:sync()
			expect(scores_of(t, "coins").p1).to.equal(5)
			t.world:set(player, t.money, 0)
			session:sync()
			expect(scores_of(t, "coins").p1).to.equal(nil)
			expect(t.backend.calls.OrderedRemoveAsync).to.equal(1)
			expect(record_of(t, "p1", "coins").pushed).to.equal(nil)
			t.world:set(player, t.money, -1)
			session:sync()
			expect(t.backend.calls.OrderedRemoveAsync).to.equal(1)
			t.world:set(player, t.money, 4)
			session:sync()
			expect(scores_of(t, "coins").p1).to.equal(4)
		end)

		it("retries a failed push on the next pull and warn once until it recovers", function()
			local t = setup({ pull_interval = never, retry_attempts = 1 })
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			t.backend:fail_next("OrderedSetAsync", "before")
			t.world:set(player, t.money, 5)
			session:sync()
			expect(scores_of(t, "coins").p1).to.equal(nil)
			expect(record_of(t, "p1", "coins").pushed).to.equal(5)
			expect(utils.warning_count(t.backend, "could not be pushed")).to.equal(1)
			t.backend:fail_next("OrderedSetAsync", "before")
			session:sync()
			expect(utils.warning_count(t.backend, "could not be pushed")).to.equal(1)
			expect(scores_of(t, "coins").p1).to.equal(nil)
			session:sync()
			expect(scores_of(t, "coins").p1).to.equal(5)
			expect(utils.warning_count(t.backend, "push again")).to.equal(1)
			session:sync()
			expect(utils.warning_count(t.backend, "push again")).to.equal(1)
		end)

		it("maps the stored form and leaves bad results unranked with one warning each", function()
			local t = setup()
			utils.declare_ordered(t.world, t.player_data, "stats", {
				component = t.items,
				map = function(stored)
					local n = stored.n
					if n == "boom" then
						error("boom")
					end
					if n == "nan" then
						return 0 / 0
					end
					if n == "inf" then
						return math.huge
					end
					return n
				end,
			})
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			t.world:set(player, t.items, { n = 2.7 })
			session:sync()
			expect(scores_of(t, "stats").p1).to.equal(2)
			t.world:set(player, t.items, { n = -1 })
			session:sync()
			expect(scores_of(t, "stats").p1).to.equal(nil)
			expect(utils.warning_count(t.backend, "non-negative integer")).to.equal(1)
			for _, bad in { "x", "nan", "inf" } do
				t.world:set(player, t.items, { n = bad })
				session:sync()
				expect(scores_of(t, "stats").p1).to.equal(nil)
			end
			expect(utils.warning_count(t.backend, "non-negative integer")).to.equal(1)
			t.world:set(player, t.items, { n = "boom" })
			session:sync()
			expect(utils.warning_count(t.backend, "failed and the key is not ranked")).to.equal(1)
			t.world:set(player, t.items, { n = 3 })
			session:sync()
			expect(scores_of(t, "stats").p1).to.equal(3)
		end)

		it("shares a field between all-time stores with different maps", function()
			local t = setup()
			utils.declare_ordered(t.world, t.player_data, "wins", {
				component = t.items,
				map = function(stored)
					return stored.w
				end,
			})
			utils.declare_ordered(t.world, t.player_data, "rate", {
				component = t.items,
				map = function(stored)
					return 100 * stored.w / (stored.w + stored.l)
				end,
			})
			utils.declare_ordered(t.world, t.player_data, "raw", { component = t.items })
			local player = utils.link_entity(t, "p1")
			t.world:set(player, t.items, { w = 3, l = 1 })
			utils.session_of(t, "p1"):sync()
			expect(scores_of(t, "wins").p1).to.equal(3)
			expect(scores_of(t, "rate").p1).to.equal(75)
			expect(scores_of(t, "raw").p1).to.equal(nil)
			expect(record_of(t, "p1", "raw")).to.equal(nil)
		end)
	end)

	describe("periods", function()
		it(
			"reset the field when a record crosses into a new period and push the final score to the old period's store",
			function()
				local t = setup()
				local clock = create_clock(1)
				utils.declare_ordered(t.world, t.player_data, "weekly", { component = t.money, period = clock.period })
				local player = utils.link_entity(t, "p1")
				local session = utils.session_of(t, "p1")
				t.world:set(player, t.money, 5)
				session:sync()
				expect(scores_of(t, "weekly_1").p1).to.equal(5)
				expect(record_of(t, "p1", "weekly").period).to.equal(1)
				t.world:set(player, t.money, 8)
				clock.index = 2
				session:sync()
				expect(scores_of(t, "weekly_1").p1).to.equal(8)
				expect(scores_of(t, "weekly_2").p1).to.equal(nil)
				local data = t.backend:dump("p1").data
				expect(data.money).to.equal(0)
				expect(data[bookkeeping].weekly.period).to.equal(2)
				expect(data[bookkeeping].weekly.pushed).to.equal(nil)
				expect(data[bookkeeping].weekly.owed).to.equal(nil)
				miumiu.step(t.world)
				expect(t.world:get(player, t.money)).to.equal(0)
				t.world:set(player, t.money, 4)
				session:sync()
				expect(scores_of(t, "weekly_2").p1).to.equal(4)
				expect(t.backend.calls.OrderedSetAsync).to.equal(3)
				clock.index = 3
				session:sync()
				expect(t.backend.calls.OrderedSetAsync).to.equal(3)
				expect(t.backend:dump("p1").data.money).to.equal(0)
				expect(record_of(t, "p1", "weekly").period).to.equal(3)
				miumiu.step(t.world)
				expect(t.world:get(player, t.money)).to.equal(0)
			end
		)

		it("keeps the field across a crossing and ranks it again in the new period when reset is false", function()
			local t = setup()
			local clock = create_clock(1)
			utils.declare_ordered(t.world, t.player_data, "monthly", {
				component = t.money,
				period = clock.period,
				reset = false,
			})
			local player = utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			expect(scores_of(t, "monthly_1").p1).to.equal(5)
			clock.index = 2
			session:sync()
			expect(t.backend:dump("p1").data.money).to.equal(5)
			miumiu.step(t.world)
			expect(t.world:get(player, t.money)).to.equal(5)
			expect(scores_of(t, "monthly_1").p1).to.equal(5)
			expect(scores_of(t, "monthly_2").p1).to.equal(5)
			t.world:set(player, t.money, 9)
			session:sync()
			expect(scores_of(t, "monthly_1").p1).to.equal(5)
			expect(scores_of(t, "monthly_2").p1).to.equal(9)
		end)

		it("removes a field without an initial at the crossing", function()
			local t = setup()
			local clock = create_clock(1)
			utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.items,
				period = clock.period,
				map = function(stored)
					return stored.n
				end,
			})
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			t.world:set(player, t.items, { n = 5 })
			session:sync()
			expect(scores_of(t, "weekly_1").p1).to.equal(5)
			clock.index = 2
			session:sync()
			expect(t.backend:dump("p1").data.items).to.equal(nil)
			miumiu.step(t.world)
			expect(t.world:has(player, t.items)).to.equal(false)
		end)

		it("counts a record written before the store existed for the period it is first written in", function()
			local t = setup()
			local clock = create_clock(1)
			utils.declare_ordered(t.world, t.player_data, "weekly", { component = t.money, period = clock.period })
			t.backend:seed("p1", { data = { money = 7 } })
			t.backend:seed("p2", { data = { money = 0 } })
			utils.link_entity(t, "p1")
			utils.link_entity(t, "p2")
			expect(scores_of(t, "weekly_1").p1).to.equal(7)
			expect(record_of(t, "p1", "weekly").period).to.equal(1)
			expect(record_of(t, "p2", "weekly")).to.equal(nil)
			clock.index = 2
			utils.session_of(t, "p1"):sync()
			utils.session_of(t, "p2"):sync()
			expect(t.backend:dump("p1").data.money).to.equal(0)
			expect(t.backend:dump("p2").version).to.equal(1)
			expect(record_of(t, "p2", "weekly")).to.equal(nil)
		end)

		it("reports the current period from every config form and validates a period function's result", function()
			local t = setup()
			local score = utils.declare_saveable(t.world, "component", "score", { t.player_data })
			local seconds =
				utils.declare_ordered(t.world, t.player_data, "daily", { component = t.money, period = 100 })
			local aligned = utils.declare_ordered(
				t.world,
				t.player_data,
				"aligned",
				{ component = t.items, period = { length = 100, epoch = 50 } }
			)
			local bad = utils.declare_ordered(t.world, t.player_data, "bad", {
				component = score,
				period = function()
					return 5
				end,
			})
			local before = os.time()
			local period = miumiu.get_ordered(t.world, seconds):get_period() :: Period
			expect(period.start % 100).to.equal(0)
			expect(period.finish - period.start).to.equal(100)
			expect(period.index * 100).to.equal(period.start)
			expect(period.start <= os.time() and before < period.finish).to.equal(true)
			local shifted = miumiu.get_ordered(t.world, aligned):get_period() :: Period
			expect(shifted.start % 100).to.equal(50)
			expect(function()
				miumiu.get_ordered(t.world, bad):get_period()
			end).to.throw("must return")
		end)
	end)

	describe("on_period_change", function()
		type Change = { entity: Entity, value: any, place: number?, period: number }

		local function declare_weekly(t: Fixture, clock: Clock, changes: { Change }, config: { [string]: any }?): Entity
			local given = config or {}
			return utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.money,
				period = clock.period,
				poll_interval = given.poll_interval or 0,
				period_threshold = given.period_threshold,
				on_period_change = given.on_period_change or function(world, entity, value, place, period)
					table.insert(changes, { entity = entity, value = value, place = place, period = period })
					world:set(entity, t.items, { reward = place })
				end,
			})
		end

		it(
			"runs once per key and finished period with the value and place, claiming the change in its batch",
			function()
				local t = setup()
				local clock = create_clock(1)
				local changes: { Change } = {}
				declare_weekly(t, clock, changes)
				local p1 = utils.link_entity(t, "p1", { money = 5 })
				local p2 = utils.link_entity(t, "p2", { money = 9 })
				expect(#t.backend:sorted("weekly_1")).to.equal(2)
				clock.index = 2
				utils.session_of(t, "p1"):sync()
				utils.session_of(t, "p2"):sync()
				expect(#changes).to.equal(0)
				miumiu.step(t.world)
				expect(#changes).to.equal(2)
				local by_entity: { [Entity]: Change } = {}
				for _, change in changes do
					by_entity[change.entity] = change
				end
				expect(by_entity[p1].value).to.equal(5)
				expect(by_entity[p1].place).to.equal(2)
				expect(by_entity[p1].period).to.equal(1)
				expect(by_entity[p2].value).to.equal(9)
				expect(by_entity[p2].place).to.equal(1)
				expect(t.backend.calls.GetSortedAsync).to.equal(1)
				expect(t.world:get(p1, t.items).reward).to.equal(2)
				miumiu.step(t.world)
				expect(#changes).to.equal(2)
				utils.session_of(t, "p1"):sync()
				local data = t.backend:dump("p1").data
				expect(data.items.reward).to.equal(2)
				expect(data[bookkeeping].weekly.owed).to.equal(nil)
				utils.session_of(t, "p1"):sync()
				miumiu.step(t.world)
				expect(#changes).to.equal(2)
			end
		)

		it("runs for a store that keeps its field", function()
			local t = setup()
			local clock = create_clock(1)
			local changes: { { value: any, place: number? } } = {}
			utils.declare_ordered(t.world, t.player_data, "monthly", {
				component = t.money,
				period = clock.period,
				reset = false,
				poll_interval = 0,
				on_period_change = function(_, _, value, place)
					table.insert(changes, { value = value, place = place })
				end,
			})
			utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			clock.index = 2
			session:sync()
			miumiu.step(t.world)
			expect(#changes).to.equal(1)
			expect(changes[1].value).to.equal(5)
			expect(changes[1].place).to.equal(1)
		end)

		it("gives no place beyond period_threshold and still claims the change", function()
			local t = setup()
			local clock = create_clock(1)
			local changes: { Change } = {}
			declare_weekly(t, clock, changes, { period_threshold = 1 })
			local p1 = utils.link_entity(t, "p1", { money = 5 })
			utils.link_entity(t, "p2", { money = 9 })
			clock.index = 2
			utils.session_of(t, "p1"):sync()
			miumiu.step(t.world)
			expect(#changes).to.equal(1)
			expect(changes[1].entity).to.equal(p1)
			expect(changes[1].place).to.equal(nil)
			utils.session_of(t, "p1"):sync()
			expect(record_of(t, "p1", "weekly").owed).to.equal(nil)
		end)

		it("waits poll_interval after the period's end, or for the period after that", function()
			local t = setup()
			local clock = create_clock(1)
			local changes: { Change } = {}
			declare_weekly(t, clock, changes, { poll_interval = 60 })
			utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			clock.index = 2
			clock.start = os.time() + 1000
			session:sync()
			miumiu.step(t.world)
			expect(#changes).to.equal(0)
			expect(record_of(t, "p1", "weekly").owed.period).to.equal(1)
			clock.index = 3
			session:sync()
			expect(record_of(t, "p1", "weekly").owed.period).to.equal(1)
			miumiu.step(t.world)
			expect(#changes).to.equal(1)
			expect(changes[1].period).to.equal(1)
			expect(changes[1].value).to.equal(5)
			expect(changes[1].place).to.equal(1)
			clock.start = 0
			session:sync()
			miumiu.step(t.world)
			expect(#changes).to.equal(1)
		end)

		it("keeps the change owed when the callback throws and runs it again on the next load", function()
			local t = setup()
			local clock = create_clock(1)
			local attempts = 0
			declare_weekly(t, clock, {}, {
				on_period_change = function()
					attempts += 1
					if attempts == 1 then
						error("boom")
					end
				end,
			})
			local player = utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			clock.index = 2
			session:sync()
			miumiu.step(t.world)
			expect(attempts).to.equal(1)
			expect(utils.warning_count(t.backend, "threw and was rolled back")).to.equal(1)
			session:sync()
			expect(record_of(t, "p1", "weekly").owed.period).to.equal(1)
			miumiu.step(t.world)
			expect(attempts).to.equal(1)
			t.world:remove(player, t.link)
			miumiu.step(t.world)
			expect(utils.wait_closed(session)).to.equal(true)
			utils.link_entity(t, "p1")
			expect(attempts).to.equal(2)
			utils.session_of(t, "p1"):sync()
			expect(record_of(t, "p1", "weekly").owed).to.equal(nil)
		end)

		it("keeps the change owed when the batch carrying it is refused", function()
			local t = setup()
			local clock = create_clock(1)
			local changes: { Change } = {}
			declare_weekly(t, clock, changes)
			utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			clock.index = 2
			session:sync()
			miumiu.step(t.world)
			expect(#changes).to.equal(1)
			utils.take_over(t.backend, "p1")
			expect(function()
				session:sync()
			end).to.throw("newer server")
			expect(record_of(t, "p1", "weekly").owed.period).to.equal(1)
		end)

		it("does not run on a shallow link but does on a plain link of the same key", function()
			local t = setup()
			local clock = create_clock(1)
			local changes: { Change } = {}
			declare_weekly(t, clock, changes)
			local player = utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			t.world:remove(player, t.link)
			miumiu.step(t.world)
			expect(utils.wait_closed(session)).to.equal(true)
			clock.index = 2
			local gift = t.world:entity()
			t.world:add(gift, jecs.pair(miumiu.data_shallow, t.player_data))
			t.world:set(gift, t.link, "p1")
			utils.settle(t, gift)
			miumiu.step(t.world)
			expect(#changes).to.equal(0)
			local plain = t.world:entity()
			t.world:set(plain, t.link, "p1")
			utils.settle(t, plain)
			expect(#changes).to.equal(1)
			expect(changes[1].entity).to.equal(plain)
		end)

		it("warns and retries when the finished ranking cannot be read", function()
			local t = setup({ pull_interval = never, retry_attempts = 1 })
			local clock = create_clock(1)
			local changes: { Change } = {}
			declare_weekly(t, clock, changes)
			utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			clock.index = 2
			t.backend:fail_next("GetSortedAsync", "before")
			session:sync()
			expect(utils.warning_count(t.backend, "could not be read")).to.equal(1)
			miumiu.step(t.world)
			expect(#changes).to.equal(0)
			session:sync()
			miumiu.step(t.world)
			expect(#changes).to.equal(1)
		end)
	end)

	describe("Ordered", function()
		it("reads the top in rank order, pages past a hundred and serves a finished period from the cache", function()
			local t = setup()
			local clock = create_clock(2)
			local entity =
				utils.declare_ordered(t.world, t.player_data, "weekly", { component = t.money, period = clock.period })
			local current = t.backend:ordered("weekly_2")
			for index = 1, 150 do
				current:SetAsync(`k{index}`, index)
			end
			local ordered = miumiu.get_ordered(t.world, entity)
			local top = ordered:get_top(120)
			expect(#top).to.equal(120)
			expect(top[1].key).to.equal("k150")
			expect(top[1].score).to.equal(150)
			expect(top[120].score).to.equal(31)
			expect(t.backend.calls.GetSortedAsync).to.equal(1)
			expect(t.backend.calls.AdvanceToNextPageAsync).to.equal(1)
			local lowest = ordered:get_top(2, { ascending = true })
			expect(lowest[1].score).to.equal(1)
			expect(lowest[2].score).to.equal(2)
			ordered:get_top(5)
			expect(t.backend.calls.GetSortedAsync).to.equal(3)
			local finished = t.backend:ordered("weekly_1")
			for index = 1, 8 do
				finished:SetAsync(`o{index}`, index)
			end
			expect(#ordered:get_top(5, { period = 1 })).to.equal(5)
			expect(t.backend.calls.GetSortedAsync).to.equal(4)
			expect(t.backend.calls.AdvanceToNextPageAsync).to.equal(1)
			local three = ordered:get_top(3, { period = 1 })
			expect(#three).to.equal(3)
			expect(three[1].key).to.equal("o8")
			expect(t.backend.calls.GetSortedAsync).to.equal(4)
			expect(#ordered:get_top(8, { period = 1 })).to.equal(8)
			expect(t.backend.calls.GetSortedAsync).to.equal(5)
			expect(#ordered:get_top(10, { period = 1 })).to.equal(8)
			expect(t.backend.calls.GetSortedAsync).to.equal(5)
			expect(#ordered:get_top(2, { period = 1, ascending = true })).to.equal(2)
			expect(t.backend.calls.GetSortedAsync).to.equal(6)
		end)

		it(
			"reads one key's score and the current period, and rejects a bad count or a period on an all-time store",
			function()
				local t = setup()
				local clock = create_clock(3)
				local coins_entity = utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
				local weekly_entity = utils.declare_ordered(t.world, t.player_data, "weekly", {
					component = t.items,
					period = clock.period,
					map = function(stored)
						return stored.n
					end,
				})
				utils.link_entity(t, "p1", { money = 5, items = { n = 5 } })
				local coins = miumiu.get_ordered(t.world, coins_entity)
				local weekly = miumiu.get_ordered(t.world, weekly_entity)
				expect(coins:get_score("p1")).to.equal(5)
				expect(coins:get_score("nobody")).to.equal(nil)
				expect(coins:get_period()).to.equal(nil)
				expect((weekly:get_period() :: Period).index).to.equal(3)
				expect(weekly:get_score("p1")).to.equal(5)
				expect(weekly:get_score("p1", 2)).to.equal(nil)
				expect(function()
					coins:get_top(0)
				end).to.throw("at least 1")
				expect(function()
					coins:get_top(1.5)
				end).to.throw("at least 1")
				expect(function()
					coins:get_top(1, { period = 1 })
				end).to.throw("no periods")
				expect(function()
					coins:get_score("p1", 1)
				end).to.throw("no periods")
				expect(coins:get_name()).to.equal("coins")
				expect(tostring(coins)).to.equal("Ordered(coins)")
				expect(miumiu.is_ordered(coins)).to.equal(true)
				expect(miumiu.is_ordered({})).to.equal(false)
				expect(miumiu.get_ordered(t.world, coins_entity)).to.equal(coins)
				expect(function()
					miumiu.get_ordered(t.world, t.money)
				end).to.throw("not an ordered store")
			end
		)
	end)

	describe("wipe", function()
		it("removes the key from every store of the collection and warns when it cannot", function()
			local t = setup({ pull_interval = never, retry_attempts = 1 })
			local clock = create_clock(1)
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.items,
				period = clock.period,
				map = function(stored)
					return stored.n
				end,
			})
			utils.link_entity(t, "p1", { money = 5, items = { n = 2 } })
			miumiu.wipe(t.world, t.player_data, "p1")
			expect(scores_of(t, "coins").p1).to.equal(nil)
			expect(scores_of(t, "weekly_1").p1).to.equal(nil)
			expect(t.backend.calls.OrderedRemoveAsync).to.equal(2)
			local leaver = utils.link_entity(t, "p2", { money = 3 })
			local session = utils.session_of(t, "p2")
			t.world:remove(leaver, t.link)
			miumiu.step(t.world)
			expect(utils.wait_closed(session)).to.equal(true)
			miumiu.wipe(t.world, t.player_data, "p2")
			expect(scores_of(t, "coins").p2).to.equal(nil)
			expect(scores_of(t, "weekly_1").p2).to.equal(nil)
			utils.link_entity(t, "p3", { money = 2 })
			t.backend:fail_next("OrderedRemoveAsync", "before")
			miumiu.wipe(t.world, t.player_data, "p3")
			expect(utils.warning_count(t.backend, "could not remove")).to.equal(1)
			expect(scores_of(t, "coins").p3).to.equal(2)
			expect(scores_of(t, "weekly_1").p3).to.equal(nil)
		end)
	end)

	local function declare_world(): (any, Entity, Entity<number>)
		local backend = utils.create_backend()
		local world = jecs.world()
		local collection = utils.create_collection(world, backend)
		local money = utils.declare_saveable(world, "component", "money", { collection })
		return world, collection, money
	end

	describe("schema", function()
		local function expect_build(world: any, message: string)
			expect(function()
				schema.create_schema(world)
			end).to.throw(message)
		end

		it("rejects every misconfiguration", function()
			local world, collection, money = declare_world()
			local store = utils.declare_ordered(world, collection, "coins", 5 :: any)
			expect_build(world, "must be a table")
			world:set(store, miumiu.ordered, { component = money })
			world:remove(store, jecs.Name)
			expect_build(world, "needs a jecs.Name")
			world:set(store, jecs.Name, string.rep("n", 41))
			expect_build(world, "needs a jecs.Name")
			world:set(store, jecs.Name, "coins")
			world:remove(store, jecs.pair(miumiu.field_of, collection))
			expect_build(world, "exactly one pair")
			world:add(store, jecs.pair(miumiu.field_of, money))
			expect_build(world, "exactly one pair")
			world:remove(store, jecs.pair(miumiu.field_of, money))
			world:add(store, jecs.pair(miumiu.field_of, collection))
			local other = utils.create_collection(world, utils.create_backend())
			world:add(store, jecs.pair(miumiu.field_of, other))
			expect_build(world, "exactly one pair")
			world:remove(store, jecs.pair(miumiu.field_of, other))
			local tag = utils.declare_saveable(world, "tag", "flag", { collection })
			world:set(store, miumiu.ordered, { component = tag })
			expect_build(world, "component must be a component saveable")
			world:set(store, miumiu.ordered, { component = world:entity() })
			expect_build(world, "component must be a component saveable")
			local elsewhere = utils.declare_saveable(world, "component", "elsewhere", { other })
			world:set(store, miumiu.ordered, { component = elsewhere })
			expect_build(world, "not a root field")
			world:set(store, miumiu.ordered, { component = money, map = 5 })
			expect_build(world, "map must be a function")
			for _, period in { "x", {}, -1, { length = 10, epoch = "x" }, math.huge } do
				world:set(store, miumiu.ordered, { component = money, period = period :: any })
				expect_build(world, "period must be")
			end
			for _, threshold in { 0, 1.5, "x" } do
				world:set(store, miumiu.ordered, { component = money, period_threshold = threshold :: any })
				expect_build(world, "period_threshold must be")
			end
			world:set(store, miumiu.ordered, { component = money, poll_interval = -1 })
			expect_build(world, "poll_interval must be")
			world:set(store, miumiu.ordered, { component = money, period = 10, on_period_change = 5 :: any })
			expect_build(world, "on_period_change must be a function")
			world:set(store, miumiu.ordered, { component = money, on_period_change = function() end })
			expect_build(world, "needs a period")
			world:set(store, miumiu.ordered, { component = money })
			local twin = utils.declare_ordered(world, collection, "coins", { component = money })
			expect_build(world, "already uses as its store name")
			world:set(twin, jecs.Name, world:get(collection, miumiu.collection))
			expect_build(world, "already uses as its store name")
			world:set(twin, jecs.Name, "twin")
			world:set(twin, miumiu.ordered, { component = money, period = 10 })
			world:set(store, miumiu.ordered, { component = money, period = 20 })
			expect_build(world, "feeds no other ordered store")
			world:set(store, miumiu.ordered, { component = money })
			expect_build(world, "feeds no other ordered store")
			world:set(twin, miumiu.ordered, { component = money })
			expect(#schema.create_schema(world).roots[collection].ordered).to.equal(2)
			world:set(twin, jecs.Name, string.rep("n", 40))
			world:set(twin, miumiu.ordered, { component = money, period = 1 })
			expect_build(world, "character DataStore limit")
		end)

		it("lets a store that keeps its field share it with another ordered store", function()
			local world, collection, money = declare_world()
			utils.declare_ordered(world, collection, "monthly", { component = money, period = 10, reset = false })
			utils.declare_ordered(world, collection, "alltime", { component = money })
			utils.declare_ordered(world, collection, "yearly", { component = money, period = 100, reset = false })
			expect(#schema.create_schema(world).roots[collection].ordered).to.equal(3)
			local weekly = utils.declare_ordered(world, collection, "weekly", { component = money, period = 5 })
			expect_build(world, "feeds no other ordered store")
			world:set(weekly, miumiu.ordered, { component = money, period = 5, reset = "x" :: any })
			expect_build(world, "reset must be a boolean")
			world:set(weekly, miumiu.ordered, { component = money, reset = true })
			expect_build(world, "reset needs a period")
		end)

		it("reserves keys starting with miumiu. for saveables and child kinds", function()
			local world, collection = declare_world()
			local reserved = utils.declare_saveable(world, "component", "miumiu.x", { collection })
			expect_build(world, "reserved")
			world:delete(reserved)
			local kinds = utils.declare_kinds(world, collection)
			world:set(kinds.item, miumiu.child, { via = kinds.owns, key = "miumiu.inventory", mode = "owned" })
			expect_build(world, "reserved")
		end)

		it("orders a root's stores by name and freezes the meta with the schema", function()
			local world, collection, money = declare_world()
			utils.declare_ordered(world, collection, "zeta", { component = money })
			utils.declare_ordered(world, collection, "alpha", { component = money })
			local ordered = schema.create_schema(world).roots[collection].ordered
			expect(ordered[1].name).to.equal("alpha")
			expect(ordered[2].name).to.equal("zeta")
			local t = setup()
			local store = utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			miumiu.step(t.world)
			expect(function()
				t.world:set(store, miumiu.ordered, { component = t.items })
			end).to.throw("changed after the schema was built")
		end)

		it("fails the link of a collection with an ordered store when the service lacks GetOrderedDataStore", function()
			local t = setup()
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			t.world:set(t.player_data, miumiu.config, { data_store_service = t.backend.plain_service })
			local entity = t.world:entity()
			t.world:set(entity, t.link, "p1")
			utils.settle(t, entity)
			expect((string.find(t.world:get(entity, t.data_error), "GetOrderedDataStore", 1, true))).to.be.ok()
		end)

		it("keeps the bookkeeping key out of context.legacy", function()
			local t = setup()
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			t.world:set(t.player_data, miumiu.migrations, {
				function(_, _, context)
					context.legacy(bookkeeping)
				end,
			})
			t.backend:seed("p1", { data = { [bookkeeping] = { coins = { pushed = 1 } } } })
			local entity = t.world:entity()
			t.world:set(entity, t.link, "p1")
			utils.settle(t, entity)
			expect((string.find(t.world:get(entity, t.data_error), "bookkeeping", 1, true))).to.be.ok()
		end)
	end)

	describe("rankings.roll", function()
		it("leaves a state alone until a score or a period changes", function()
			local world, collection, money = declare_world()
			local clock = create_clock(1)
			local entity =
				utils.declare_ordered(world, collection, "weekly", { component = money, period = clock.period })
			local store = schema.create_schema(world).ordered[entity]
			local state = { truth = {}, stamps = {} }
			local rolled = rankings.roll(state, { store }, 10)
			expect(rolled.state).to.equal(state)
			expect(#rolled.ops).to.equal(0)
			expect(#rolled.pushes).to.equal(0)
			rolled = rankings.roll({ truth = { money = 3 }, stamps = { money = 10 } }, { store }, 10)
			expect(#rolled.ops).to.equal(1)
			expect(rolled.ops[1].kind).to.equal("put")
			expect(rolled.ops[1].at).to.equal(10)
			expect(rolled.pushes[1].name).to.equal("weekly_1")
			expect(rolled.pushes[1].score).to.equal(3)
			expect(rolled.state.truth[bookkeeping].weekly.period).to.equal(1)
			clock.index = 2
			local crossed = rankings.roll(rolled.state, { store }, 10)
			expect(#crossed.ops).to.equal(2)
			expect(crossed.ops[1].kind).to.equal("remove")
			expect(crossed.ops[1].at).to.equal(11)
			expect(#crossed.pushes).to.equal(0)
			expect(crossed.state.truth.money).to.equal(nil)
			expect(crossed.state.truth[bookkeeping].weekly.period).to.equal(2)
			expect(crossed.state.truth[bookkeeping].weekly.pushed).to.equal(nil)
		end)
	end)

	describe("regressions", function()
		it("keeps the earliest owed change when a record crosses two periods before it resolves", function()
			local t = setup()
			local clock = create_clock(1)
			local changes = {}
			utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.money,
				period = clock.period,
				poll_interval = 0,
				on_period_change = function(_, _, value, place, period)
					table.insert(changes, { value = value, place = place, period = period })
				end,
			})
			utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			clock.index = 2
			clock.start = os.time() + 1000
			session:sync()
			clock.index = 3
			session:sync()
			expect(record_of(t, "p1", "weekly").owed.period).to.equal(1)
			expect(record_of(t, "p1", "weekly").period).to.equal(3)
			miumiu.step(t.world)
			expect(#changes).to.equal(1)
			expect(changes[1].period).to.equal(1)
			expect(changes[1].value).to.equal(5)
		end)

		it("keeps a write journaled while the crossing write was in flight", function()
			local t = setup({ pull_interval = never, retry_attempts = 1 })
			local clock = create_clock(1)
			utils.declare_ordered(t.world, t.player_data, "weekly", { component = t.money, period = clock.period })
			local player = utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			clock.index = 2
			local done = false
			t.backend:delay_next("UpdateAsync", utils.timings.window, "after")
			task.spawn(function()
				session:sync()
				done = true
			end)
			expect(utils.wait_until(function()
				local record = t.backend:dump("p1")
				return record ~= nil and record.data.money == 0
			end)).to.equal(true)
			t.world:set(player, t.money, 100)
			expect(utils.wait_until(function()
				return done
			end)).to.equal(true)
			session:sync()
			miumiu.step(t.world)
			expect(t.backend:dump("p1").data.money).to.equal(100)
			expect(t.world:get(player, t.money)).to.equal(100)
		end)

		it("keeps writing the record when the period function throws, warning once", function()
			local t = setup()
			local broken = false
			utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.money,
				period = function(): any
					if broken then
						error("boom")
					end
					return { index = 1, start = 0, finish = 100 }
				end,
			})
			local player = utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			broken = true
			t.world:set(player, t.money, 9)
			session:sync()
			expect(t.backend:dump("p1").data.money).to.equal(9)
			expect(utils.warning_count(t.backend, "is skipped until it works again")).to.equal(1)
			t.world:set(player, t.money, 11)
			session:sync()
			expect(t.backend:dump("p1").data.money).to.equal(11)
			expect(utils.warning_count(t.backend, "is skipped until it works again")).to.equal(1)
		end)

		it("pushes the score of a write whose response failed and was retried", function()
			local t = setup()
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			t.world:set(player, t.money, 5)
			t.backend:fail_next("UpdateAsync", "after")
			session:sync()
			expect(record_of(t, "p1", "coins").pushed).to.equal(5)
			expect(scores_of(t, "coins").p1).to.equal(5)
		end)

		it("pushes into the period the record claims, not the one its own clock names", function()
			local t = setup()
			local behind = create_clock(1)
			utils.declare_ordered(t.world, t.player_data, "weekly", { component = t.money, period = behind.period })
			local player = utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			expect(scores_of(t, "weekly_1").p1).to.equal(5)

			local ahead_world = jecs.world()
			local ahead_collection = utils.create_collection(ahead_world, t.backend, { pull_interval = never })
			local ahead_money = utils.declare_saveable(ahead_world, "component", "money", { ahead_collection })
			ahead_world:set(ahead_money, ahead_money, 0)
			utils.declare_ordered(ahead_world, ahead_collection, "weekly", {
				component = ahead_money,
				period = create_clock(2).period,
			})
			local mirror = ahead_world:entity()
			ahead_world:set(mirror, jecs.pair(miumiu.data_link, ahead_collection), "p1")
			expect(utils.wait_until(function()
				miumiu.step(ahead_world)
				return ahead_world:has(mirror, jecs.pair(miumiu.data_loaded, ahead_collection))
			end)).to.equal(true)
			miumiu.close(ahead_world, 0)
			expect(record_of(t, "p1", "weekly").period).to.equal(2)

			session:sync()
			miumiu.step(t.world)
			t.world:set(player, t.money, 9)
			session:sync()
			expect(scores_of(t, "weekly_1").p1).to.equal(5)
			expect(scores_of(t, "weekly_2").p1).to.equal(9)
		end)

		it("loads a key whose stored bookkeeping has the wrong shape", function()
			local t = setup()
			local clock = create_clock(1)
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.items,
				period = clock.period,
				map = function(stored)
					return stored.n
				end,
			})
			t.backend:seed("p1", { data = { money = 4, [bookkeeping] = { coins = 7 } } })
			t.backend:seed("p2", { data = { money = 4, [bookkeeping] = { weekly = { period = "x" } } } })
			local first = utils.link_entity(t, "p1")
			expect(t.world:get(first, t.data_error)).to.equal(nil)
			expect(t.world:get(first, t.money)).to.equal(4)
			expect(scores_of(t, "coins").p1).to.equal(4)
			local second = utils.link_entity(t, "p2")
			expect(t.world:get(second, t.data_error)).to.equal(nil)
		end)

		it("pushes a score it still owes before the session closes on unlink", function()
			local t = setup({ pull_interval = never, retry_attempts = 1 })
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			t.backend:fail_next("OrderedSetAsync", "before")
			t.world:set(player, t.money, 5)
			session:sync()
			expect(scores_of(t, "coins").p1).to.equal(nil)
			expect(record_of(t, "p1", "coins").pushed).to.equal(5)
			t.world:remove(player, t.link)
			miumiu.step(t.world)
			expect(utils.wait_closed(session)).to.equal(true)
			expect(scores_of(t, "coins").p1).to.equal(5)
		end)

		it("closes cleanly when only the ordered push keeps failing", function()
			local t = setup({ pull_interval = never, retry_attempts = 5, retry_base = utils.timings.slow })
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			local player = utils.link_entity(t, "p1")
			local session = utils.session_of(t, "p1")
			t.world:set(player, t.money, 5)
			for _ = 1, 8 do
				t.backend:fail_next("OrderedSetAsync", "before")
			end
			miumiu.close(t.world, 1)
			expect(utils.wait_closed(session)).to.equal(true)
			local status: any = session:get_status()
			expect(status.closure.kind).to.equal("clean")
			expect(t.backend:dump("p1").data.money).to.equal(5)
		end)

		it("resolves a later finished period after an earlier change threw", function()
			local t = setup()
			local clock = create_clock(1)
			local runs = 0
			utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.money,
				period = clock.period,
				poll_interval = 0,
				on_period_change = function()
					runs += 1
					if runs == 1 then
						error("boom")
					end
				end,
			})
			local player = utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			clock.index = 2
			session:sync()
			miumiu.step(t.world)
			expect(runs).to.equal(1)
			utils.journal(
				session,
				{ { kind = "drop", key = bookkeeping, path = { "weekly", "owed" }, at = os.time() } }
			)
			session:sync()
			expect(record_of(t, "p1", "weekly").owed).to.equal(nil)
			t.world:set(player, t.money, 9)
			session:sync()
			clock.index = 3
			session:sync()
			expect(record_of(t, "p1", "weekly").owed.period).to.equal(2)
			miumiu.step(t.world)
			expect(runs).to.equal(2)
		end)

		it("skips a change the record no longer owes", function()
			local t = setup()
			local clock = create_clock(1)
			local runs = 0
			utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.money,
				period = clock.period,
				poll_interval = 0,
				on_period_change = function()
					runs += 1
				end,
			})
			utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			clock.index = 2
			session:sync()
			utils.journal(
				session,
				{ { kind = "drop", key = bookkeeping, path = { "weekly", "owed" }, at = os.time() } }
			)
			session:sync()
			miumiu.step(t.world)
			expect(runs).to.equal(0)
			expect(record_of(t, "p1", "weekly").owed).to.equal(nil)
		end)

		it("unranks the period the record names when wiping", function()
			local t = setup()
			local clock = create_clock(2)
			utils.declare_ordered(t.world, t.player_data, "weekly", { component = t.money, period = clock.period })
			utils.link_entity(t, "p1", { money = 5 })
			expect(scores_of(t, "weekly_2").p1).to.equal(5)
			clock.index = 3
			miumiu.wipe(t.world, t.player_data, "p1")
			expect(scores_of(t, "weekly_2").p1).to.equal(nil)
		end)

		it("wipes the record when a store's period cannot be resolved", function()
			local t = setup()
			local broken = false
			utils.declare_ordered(t.world, t.player_data, "coins", { component = t.money })
			utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.items,
				period = function(): any
					if broken then
						error("boom")
					end
					return { index = 1, start = 0, finish = 100 }
				end,
				map = function(stored)
					return stored.n
				end,
			})
			local player = utils.link_entity(t, "p1", { money = 5, items = { n = 2 } })
			expect(scores_of(t, "weekly_1").p1).to.equal(2)
			broken = true
			miumiu.wipe(t.world, t.player_data, "p1")
			expect(scores_of(t, "coins").p1).to.equal(nil)
			expect(scores_of(t, "weekly_1").p1).to.equal(2)
			expect(t.world:get(player, t.money)).to.equal(0)
		end)

		it("hands get_top entries that do not alias its finished-period cache", function()
			local t = setup()
			local clock = create_clock(1)
			local store =
				utils.declare_ordered(t.world, t.player_data, "weekly", { component = t.money, period = clock.period })
			utils.link_entity(t, "p1", { money = 5 })
			clock.index = 2
			utils.session_of(t, "p1"):sync()
			local handle = miumiu.get_ordered(t.world, store)
			local first = handle:get_top(5, { period = 1 })
			expect(first[1].score).to.equal(5)
			first[1].score = 999
			expect(handle:get_top(5, { period = 1 })[1].score).to.equal(5)
		end)

		it("does not warn about an unhooked refusal when its own change batch is refused", function()
			local t = setup()
			local clock = create_clock(1)
			local runs = 0
			utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.money,
				period = clock.period,
				poll_interval = 0,
				on_period_change = function()
					runs += 1
				end,
			})
			utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			clock.index = 2
			session:sync()
			miumiu.step(t.world)
			expect(runs).to.equal(1)
			utils.take_over(t.backend, "p1")
			expect(function()
				session:sync()
			end).to.throw("newer server")
			task.wait(utils.timings.grace)
			expect(utils.warning_count(t.backend, "refused and rolled back")).to.equal(0)
		end)

		it("leaves a finished period's ranking unread while the session is closing", function()
			local t = setup()
			local clock = create_clock(1)
			local runs = 0
			utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.money,
				period = clock.period,
				poll_interval = 0,
				on_period_change = function()
					runs += 1
				end,
			})
			local player = utils.link_entity(t, "p1", { money = 5 })
			local session = utils.session_of(t, "p1")
			clock.index = 2
			t.world:set(player, t.money, 7)
			t.world:remove(player, t.link)
			miumiu.step(t.world)
			expect(utils.wait_closed(session)).to.equal(true)
			expect(t.backend.calls.GetSortedAsync).to.equal(nil)
			expect(record_of(t, "p1", "weekly").owed.period).to.equal(1)
			expect(runs).to.equal(0)
			utils.link_entity(t, "p1")
			miumiu.step(t.world)
			expect(runs).to.equal(1)
			expect(t.backend.calls.GetSortedAsync).to.equal(1)
		end)

		it("leaves a change owed while the period function is failing", function()
			local t = setup()
			local runs = 0
			utils.declare_ordered(t.world, t.player_data, "weekly", {
				component = t.money,
				period = function(): any
					error("boom")
				end,
				poll_interval = 0,
				on_period_change = function()
					runs += 1
				end,
			})
			t.backend:seed("p1", {
				data = { money = 5, [bookkeeping] = { weekly = { period = 2, owed = { period = 1, value = 5 } } } },
			})
			local player = utils.link_entity(t, "p1")
			miumiu.step(t.world)
			expect(t.world:get(player, t.data_error)).to.equal(nil)
			expect(t.world:get(player, t.money)).to.equal(5)
			expect(runs).to.equal(0)
			expect(t.backend.calls.GetSortedAsync).to.equal(nil)
			expect(record_of(t, "p1", "weekly").owed.period).to.equal(1)
		end)
	end)
end
