extends Resource
class_name EnemyConfig

@export_range(1, 300.0, 1.0) var spawn_tick_seconds := 5.0
@export_range(1, 128, 1) var max_active_enemies := 16
@export_range(1, 8, 1) var gloomling_group_size := 3
@export_range(0.0, 1.0, 0.01) var lamp_eater_spawn_chance := 0.2
@export_range(5.0, 64.0, 1.0) var min_spawn_distance := 10.0
@export_range(5.0, 128.0, 1.0) var max_spawn_distance := 28.0
@export_range(1.0, 30.0, 1.0) var spawn_cooldown_seconds := 18.0
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