import { component, type Entity, Exclusive, meta, Name, pair, tag, type World, world as create_world } from "@rbxts/jecs";
import lapis from "@rbxts/lapis";
import miumiu, {
	type ChildConfig,
	type Closure,
	type CollectionConfig,
	type Guard,
	type Migration,
	type OrderedConfig,
	type OrderedEntry,
	type Session,
	type Snapshot,
} from "@rbxts/miumiu";

const config: CollectionConfig = {
	pull_interval: 15,
	idle_interval: 60,
	user_ids: (key) => {
		const id = tonumber(key);
		return id === undefined ? [] : [id];
	},
	data_store_service: game.GetService("DataStoreService"),
};

export const player_data = tag();
meta(player_data, miumiu.collection, "player-data");
meta(player_data, miumiu.config, config);
const legacy_options = { defaultData: { luck_boosts: [] as number[] } };
meta(player_data, miumiu.from_foreign, {
	type: "lapis",
	name: "PlayerData",
	source: lapis,
	options: legacy_options,
});
interface OldSave {
	luck_boosts: number[];
	containers?: ReadonlyMap<string, { zones: ReadonlyMap<string, number> }>;
}
const receipts_to_dictionary: Migration<OldSave> = (world, entity) => {
	const processed = new Map<string, number>();
	for (const id of (world.get(entity, processed_receipts) as unknown as string[] | undefined) ?? []) {
		processed.set(id, os.time());
	}
	world.set(entity, processed_receipts, processed);
};
const convert_containers: Migration<OldSave> = (world, entity, context) => {
	for (const [id, stored] of context.stored.containers ?? new Map()) {
		const container = world.entity();
		world.add(container, plot);
		world.set(container, plot_kind, id);
		world.add(container, pair(owner_link, entity));
		for (const [index, rarity] of stored.zones) {
			const zone = world.entity();
			world.add(zone, zone_tag);
			world.set(zone, zone_index, tonumber(index) ?? 0);
			world.set(zone, zone_rarity, rarity);
			world.add(zone, pair(container_link, container));
		}
	}
};
meta(player_data, miumiu.migrations, [
	(world, entity, context) => {
		const luck_boosts = context.legacy<number[]>("luck_boosts");
		world.set(entity, money, world.get(entity, luck_boosts)?.size() ?? 0);
		world.remove(entity, luck_boosts);
	},
	convert_containers,
	receipts_to_dictionary,
]);

export const money = component<number>();
meta(money, miumiu.saveable, "money");
meta(money, money, 0);
const is_number: Guard = (value: unknown): value is number => typeIs(value, "number");
meta(money, miumiu.guard, is_number);

export const processed_receipts = component<Map<string, number>>();
meta(processed_receipts, miumiu.saveable, "processed_receipts");
meta(processed_receipts, pair(miumiu.field_of, player_data));
export const redeemed_codes = component<Set<string>>();
meta(redeemed_codes, miumiu.saveable, "redeemed_codes");
meta(redeemed_codes, pair(miumiu.field_of, player_data));
const codes_serdes: miumiu.Serdes<Set<string>, string[]> = {
	serialize: (codes) => [...codes],
	deserialize: (stored) => new Set(stored),
};
meta(redeemed_codes, miumiu.serdes, codes_serdes);

export const tutorial_finished = tag();
meta(tutorial_finished, miumiu.saveable, "tutorial");

export const last_seen = component<number>();
meta(last_seen, miumiu.saveable, "last_seen");
const last_seen_snapshot: Snapshot<number> = () => os.time();
meta(last_seen, miumiu.snapshot, last_seen_snapshot);

export const owner_link = tag();
meta(owner_link, Exclusive);
export const tool = tag();
const tool_config: ChildConfig = { via: owner_link, key: "inventory", mode: "owned" };
meta(money, pair(miumiu.field_of, player_data));
meta(money, pair(miumiu.field_of, tool));
meta(last_seen, pair(miumiu.field_of, tool));
meta(tool, miumiu.child, tool_config);
meta(tool, pair(miumiu.field_of, player_data));
export const battery = component<number>();
meta(battery, miumiu.saveable, "battery");
meta(battery, miumiu.lazy);
meta(battery, pair(miumiu.field_of, tool));
export const plot_kind = component<string>();
export const plot = tag();
meta(plot, miumiu.child, { via: owner_link, key: "containers", mode: "attached", id: plot_kind });
meta(plot, pair(miumiu.field_of, player_data));
meta(tutorial_finished, pair(miumiu.field_of, plot));
export const has_buff = tag();
meta(has_buff, miumiu.saveable, "buffs");
meta(has_buff, miumiu.pairs);
meta(has_buff, pair(miumiu.field_of, player_data));
export const fire = tag();
meta(fire, Name, "fire");
export const ice = tag();
meta(ice, Name, "ice");
interface Buff {
	multiplier: number;
	expires_at: number;
}
export const buff = component<Buff>();
meta(buff, miumiu.saveable, "timed_buffs");
meta(buff, miumiu.pairs, { targets: [fire] });
meta(buff, pair(miumiu.field_of, player_data));
export const container_link = tag();
meta(container_link, Exclusive);
export const zone_index = component<number>();
export const zone_rarity = component<number>();
meta(zone_rarity, miumiu.saveable, "crystal_rarity");
export const zone_tag = tag();
meta(zone_tag, miumiu.child, { via: container_link, key: "zones", mode: "attached", id: zone_index });
meta(zone_tag, pair(miumiu.field_of, plot));
meta(zone_rarity, pair(miumiu.field_of, zone_tag));

export function gift(world: World, user_id: number) {
	const entity = world.entity();
	world.add(entity, pair(miumiu.data_shallow, player_data));
	world.set(entity, pair(miumiu.data_link, player_data), `${user_id}`);
	return entity;
}

export function ready(world: World, on_ready: (entity: Entity) => void) {
	return world.added(miumiu.data_loaded, (entity, id) => {
		if (id === pair(miumiu.data_loaded, player_data)) on_ready(entity);
	});
}

function grant_product(world: World, entity: Entity, product: number): boolean {
	if (product === 0) return false;
	world.set(entity, pair(buff, fire), { multiplier: 2, expires_at: os.time() + product });
	return true;
}

export function grant(world: World, entity: Entity, product: number) {
	const [ok, batch] = pcall(() =>
		miumiu.batch(world, () => {
			if (!grant_product(world, entity, product)) throw "not grantable";
		}),
	);
	if (!ok) return Enum.ProductPurchaseDecision.NotProcessedYet;
	const outcome: miumiu.SettledOutcome = batch.await();
	if (outcome.kind === "refused") {
		print(outcome.message);
		return Enum.ProductPurchaseDecision.NotProcessedYet;
	}
	return Enum.ProductPurchaseDecision.PurchaseGranted;
}

export function give(world: World, player: Entity) {
	const sword = world.entity();
	world.add(sword, tool);
	world.add(sword, pair(has_buff, fire));
	world.add(sword, pair(owner_link, player));
	return world.get(sword, miumiu.child_id);
}

export function link(world: World, entity: Entity, user_id: number) {
	world.set(entity, pair(miumiu.data_link, player_data), `${user_id}`);
}

export function tick(world: World) {
	miumiu.step(world);
}

export function shutdown(world: World) {
	miumiu.close(world, 20);
}

export function save_now(world: World, user_id: number) {
	miumiu.get_session(world, player_data, `${user_id}`)?.sync();
}

export function wipe(world: World, user_id: number) {
	miumiu.wipe(world, player_data, `${user_id}`);
}

export function transfer(world: World, sender: Entity, receiver: Entity, amount: number) {
	const group: miumiu.Batch = miumiu.batch(world, () => {
		miumiu.delta(world, () => {
			world.set(sender, money, world.get(sender, money)! - amount);
			world.set(receiver, money, world.get(receiver, money)! + amount);
		});
		world.add(sender, tutorial_finished);
	});
	const paid: miumiu.Batch<boolean> = miumiu.batch(world, () => (world.get(sender, money) ?? 0) >= amount);
	const unhook = miumiu.hook(world, miumiu.hooks.refused, (refused: miumiu.Batch<unknown>, message: string) =>
		print(refused.get_outcome().kind, message),
	);
	unhook();
	if (!paid.get_result()) {
		paid.silence();
		return false;
	}
	group.hook(miumiu.hooks.landed, () => print("transferred", group.get_keys().size()));
	group.hook(miumiu.hooks.refused, (message: string) => print("refused", message));
	// @ts-expect-error a batch never fires session hooks
	group.hook(miumiu.hooks.pulled, () => {});
	const outcome: miumiu.Outcome = group.get_outcome();
	return miumiu.is_batch(group) && outcome.kind !== "refused" && !group.is_settled();
}

export function is_ready(world: World, entity: Entity) {
	return world.has(entity, pair(miumiu.data_loaded, player_data)) && !world.has(entity, pair(miumiu.data_loading, player_data));
}

export function failure(world: World, entity: Entity): string | undefined {
	return world.get(entity, pair(miumiu.data_error, player_data));
}

export function on_failure(world: World, kick: (entity: Entity, message: string) => void) {
	return world.added(miumiu.data_error, (entity, id, message) => {
		if (id === pair(miumiu.data_error, player_data)) kick(entity, message);
	});
}

export const late_world = create_world();
export const late_saveable = late_world.component<number>();
late_world.set(late_saveable, miumiu.saveable, "late");
late_world.add(late_saveable, pair(miumiu.field_of, player_data));
function helper(world: World, entity: Entity): number | undefined {
	return world.get(entity, late_saveable);
}
late_world.set(late_saveable, miumiu.snapshot, ((_, entity) => helper(late_world, entity)) as Snapshot<number>);
late_world.set(player_data, miumiu.config, config);

export function grant_async(world: World, entity: Entity) {
	return Promise.try(() => miumiu.batch(world, () => world.add(entity, tutorial_finished)).await()).then(
		(outcome) => outcome.kind === "landed",
	);
}

export function watch(value: unknown) {
	if (!miumiu.is_session(value)) return;
	const session: Session = value;
	const truth: miumiu.Data = session.get_truth();
	const stamps: miumiu.Stamps = session.get_stamps();
	const resolved: miumiu.ResolvedCollectionConfig = session.get_config();
	const status: miumiu.SessionStatus = session.get_status();
	if (status.kind === "closed" && status.closure.kind === "abandoned") print(status.closure.message);
	const record: miumiu.StoredRecord = { data: truth, stamps, version: 1 };
	const pending: miumiu.Pending = record.pending ?? {};
	const op: miumiu.Op | undefined = pending[session.get_key()]?.ops[0];
	print(resolved.name, op?.kind);
	const disconnect = session.hook(miumiu.hooks.pulled, (truth) => print(session.get_key(), truth.money));
	session.hook(miumiu.hooks.closed, (closure: Closure) => {
		print(closure.kind === "clean" ? "saved" : closure.message);
	});
	session.hook(miumiu.hooks.writing, () => print(session.is_dirty()));
	// @ts-expect-error a session never fires batch hooks
	session.hook(miumiu.hooks.landed, () => {});
	disconnect();
	return session.is_open() && session.is_dirty();
}

export const coins_this_week = component<number>();
meta(coins_this_week, miumiu.saveable, "coins_this_week");
meta(coins_this_week, pair(miumiu.field_of, player_data));
meta(coins_this_week, coins_this_week, 0);
meta(coins_this_week, miumiu.guard, is_number);

export const weekly_coins = tag();
meta(weekly_coins, Name, "weekly_coins");
meta(weekly_coins, pair(miumiu.field_of, player_data));
const weekly_config: OrderedConfig<number> = {
	component: coins_this_week,
	period: { length: 7 * 86400, epoch: 345600 },
	map: (stored) => (stored > 0 ? math.floor(stored) : undefined),
	period_threshold: 10,
	poll_interval: 60,
	on_period_change: (world, entity, value, place, period) => {
		world.set(entity, money, (world.get(entity, money) ?? 0) + value * (11 - place));
		print(period);
	},
};
meta(weekly_coins, miumiu.ordered, weekly_config);

export const all_time_coins = tag();
meta(all_time_coins, Name, "all_time_coins");
meta(all_time_coins, pair(miumiu.field_of, player_data));
meta(all_time_coins, miumiu.ordered, { component: money });

export const monthly_coins = tag();
meta(monthly_coins, Name, "monthly_coins");
meta(monthly_coins, pair(miumiu.field_of, player_data));
meta(monthly_coins, miumiu.ordered, { component: money, period: 30 * 86400, reset: false });

export function read_leaderboard(world: World): OrderedEntry[] {
	const weekly = miumiu.get_ordered(world, weekly_coins);
	const period = weekly.get_period();
	const last_week = period !== undefined ? weekly.get_top(10, { period: period.index - 1 }) : [];
	const fastest = weekly.get_top(3, { ascending: true });
	const previous = period !== undefined ? weekly.get_score("1", period.index - 1) : undefined;
	print(weekly.get_name(), last_week.size(), fastest.size(), weekly.get_score("1"), previous, miumiu.is_ordered(weekly));
	return weekly.get_top(100);
}

miumiu.set_warn((message) => print(message));

export const every_export = {
	collection: true,
	config: true,
	migrations: true,
	from_foreign: true,
	saveable: true,
	field_of: true,
	guard: true,
	serdes: true,
	snapshot: true,
	lazy: true,
	pairs: true,
	child: true,
	child_id: true,
	ordered: true,
	get_ordered: true,
	is_ordered: true,
	data_link: true,
	data_shallow: true,
	data_loading: true,
	data_loaded: true,
	data_error: true,
	step: true,
	close: true,
	get_session: true,
	wipe: true,
	batch: true,
	delta: true,
	hook: true,
	hooks: true,
	is_session: true,
	is_batch: true,
	set_warn: true,
} satisfies Record<keyof typeof miumiu, true>;
