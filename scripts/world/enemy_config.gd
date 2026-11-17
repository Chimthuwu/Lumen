extends Resource
class_name EnemyConfig

# Biome spawn tables. Index order matches the world biome ids:
# 0 = Ashen Flats, 1 = Hushwoods, 2 = Frostfall, 3 = The Mire.
# Weights are per kind: [gloomling, lamp_eater, hollow, frost_stalker, bog_crawler].

const KIND_GLOOMLING := 0
const KIND_LAMP_EATER := 1
const KIND_HOLLOW := 2
const KIND_FROST_STALKER := 3
const KIND_BOG_CRAWLER := 4
const KIND_COUNT := 5

@export_range(1, 300.0, 1.0) var spawn_tick_seconds := 5.0
@export_range(1, 128, 1) var max_active_enemies := 16
@export_range(1, 8, 1) var gloomling_group_size := 3
@export_range(0, 8, 1) var max_active_hollows := 2
@export_range(5.0, 64.0, 1.0) var min_spawn_distance := 10.0
@export_range(5.0, 128.0, 1.0) var max_spawn_distance := 28.0
@export_range(1.0, 30.0, 1.0) var spawn_cooldown_seconds := 18.0

@export var ashen_weights: Array[float] = [0.68, 0.32, 0.0, 0.0, 0.0]
@export var hush_weights: Array[float] = [0.75, 0.0, 0.25, 0.0, 0.0]
@export var frost_weights: Array[float] = [0.25, 0.0, 0.0, 0.75, 0.0]
@export var mire_weights: Array[float] = [0.0, 0.28, 0.0, 0.0, 0.72]

@export var gloomling_speed := 2.7
@export var gloomling_health := 16.0
@export var gloomling_damage := 4.0
@export var gloomling_attack_range := 1.15
@export_range(0, 15, 1) var gloomling_dissolve_light := 11
@export var lamp_eater_speed := 1.8
@export var lamp_eater_health := 34.0
@export var lamp_eater_damage := 7.0
@export var lamp_eater_attack_range := 1.5
@export var lamp_eater_extinguish_distance := 1.25
@export var lamp_eater_extinguish_seconds := 12.0
@export_range(1.0, 64.0, 1.0) var lamp_eater_target_radius := 24.0
@export var lamp_eater_target_blocks: Array[StringName] = [&"torch"]
@export var hollow_speed := 1.6
@export var hollow_health := 120.0
@export var hollow_damage := 50.0
@export var hollow_attack_range := 1.8
@export var hollow_attack_interval := 2.0
@export var frost_stalker_speed := 3.6
@export var frost_stalker_health := 14.0
@export var frost_stalker_damage := 5.0
@export var frost_stalker_attack_range := 1.15
@export_range(0, 15, 1) var frost_stalker_dissolve_light := 12
@export var bog_crawler_speed := 1.5
@export var bog_crawler_health := 40.0
@export var bog_crawler_damage := 6.0
@export var bog_crawler_attack_range := 1.4
@export var bog_crawler_extinguish_distance := 1.25
@export var bog_crawler_extinguish_seconds := 14.0
@export_range(1.0, 64.0, 1.0) var bog_crawler_target_radius := 20.0


func weights_for(biome: int) -> Array[float]:
	match biome:
		1:
			return hush_weights
		2:
			return frost_weights
		3:
			return mire_weights
		_:
			return ashen_weights


# Cumulative pick over a uniform roll. Unknown biomes fall back to the
# Ashen table so a future biome id added by the engine degrades to the
# baseline population instead of spawning nothing.
func roll_kind(biome: int, value: float) -> int:
	var weights := weights_for(biome)
	var total := 0.0
	for index in range(KIND_COUNT):
		total += float(weights[index]) if index < weights.size() else 0.0
	if total <= 0.0:
		return KIND_GLOOMLING
	var threshold := clampf(value, 0.0, 0.999999) * total
	var accumulated := 0.0
	for index in range(KIND_COUNT):
		accumulated += float(weights[index]) if index < weights.size() else 0.0
		if threshold < accumulated:
			return index
	return KIND_GLOOMLING
