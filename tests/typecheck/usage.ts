import { component, type Entity, Exclusive, meta, Name, pair, tag, type World } from "@rbxts/jecs";
import miumiu, {
	type ChildConfig,
	type Closure,
	type CollectionConfig,
	type Guard,
	type Migration,
	type Session,
	type Snapshot,
} from "@rbxts/miumiu";

const config: CollectionConfig = {
	pull_interval: 15,
	idle_interval: 60,
	default_scope: true,
	user_ids: (key) => [tonumber(key) ?? 0],
	data_store_service: game.GetService("DataStoreService"),
};

export const player_data = tag();
meta(player_data, miumiu.collection, "player-data");
meta(player_data, miumiu.config, config);
meta(player_data, miumiu.from_foreign, {
	type: "lapis",
	name: "PlayerData",
	source: {} as miumiu.LapisLibrary,
	options: { defaultData: {} },
});
interface OldSave {
	luck_boosts: number[];
	containers?: Record<string, { zones: Record<string, number> }>;
}
const convert_containers: Migration<OldSave> = (world, entity, context) => {
	for (const [id, stored] of pairs(context.stored.containers ?? {})) {
		const container = world.entity();
		world.add(container, plot);
		world.set(container, plot_kind, id);
		world.add(container, pair(owner_link, entity));
		for (const [index, rarity] of pairs(stored.zones)) {
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
]);

export const money = component<number>();
meta(money, miumiu.saveable, "money");
meta(money, money, 0);
const is_number: Guard = (value) => typeIs(value, "number");
meta(money, miumiu.guard, is_number);

export const redeemed_codes = component<Set<string>>();
meta(redeemed_codes, miumiu.saveable, "redeemed_codes");
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
export const battery = component<number>();
meta(battery, miumiu.saveable, "battery");
meta(battery, miumiu.lazy);
meta(battery, pair(miumiu.field_of, tool));
export const plot_kind = component<string>();
export const plot = tag();
meta(plot, miumiu.child, { via: owner_link, key: "containers", mode: "attached", id: plot_kind });
meta(tutorial_finished, pair(miumiu.field_of, plot));
export const has_buff = tag();
meta(has_buff, miumiu.saveable, "buffs");
meta(has_buff, miumiu.pairs);
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

export function grant(world: World, entity: Entity, product: number) {
	const [ok, err] = pcall(() =>
		miumiu.batch(world, () => {
			world.set(entity, pair(buff, fire), { multiplier: 2, expires_at: os.time() + product });
		}),
	);
	return ok ? Enum.ProductPurchaseDecision.PurchaseGranted : (print(err), Enum.ProductPurchaseDecision.NotProcessedYet);
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
	miumiu.batch(world, () => {
		miumiu.delta(world, () => {
			world.set(sender, money, world.get(sender, money)! - amount);
			world.set(receiver, money, world.get(receiver, money)! + amount);
		});
		world.add(sender, tutorial_finished);
	});
}

export function is_ready(world: World, entity: Entity) {
	return world.has(entity, pair(miumiu.data_loaded, player_data)) && !world.has(entity, pair(miumiu.data_loading, player_data));
}

export function failure(world: World, entity: Entity): string | undefined {
	return world.get(entity, pair(miumiu.data_error, player_data));
}

export function watch(value: unknown) {
	if (!miumiu.is_session(value)) return;
	const session: Session = value;
	const truth: miumiu.Data = session.get_truth();
	const stamps: miumiu.Stamps = session.get_stamps();
	const resolved: miumiu.ResolvedCollectionConfig = session.get_config();
	const record: miumiu.StoredRecord = { data: truth, stamps, version: 1 };
	const pending: miumiu.Pending = record.pending ?? {};
	const op: miumiu.Op | undefined = pending[session.get_key()]?.ops[0];
	print(resolved.name, op?.kind);
	const disconnect = session.hook(miumiu.hooks.pulled, (truth) => print(session.get_key(), truth.money));
	session.hook(miumiu.hooks.closed, (closure: Closure) => {
		print(closure.kind === "clean" ? "saved" : closure.message);
	});
	session.hook(miumiu.hooks.writing, () => print(session.is_dirty()));
	disconnect();
	return session.is_open() && session.is_dirty();
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
	hooks: true,
	is_session: true,
	set_warn: true,
} satisfies Record<keyof typeof miumiu, true>;
