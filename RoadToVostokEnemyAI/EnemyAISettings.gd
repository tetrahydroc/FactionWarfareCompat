extends Resource
class_name EnemyAISettings

@export var intensity_preset = 0
@export var spawn_rate_adjustment = 1

@export var spawn_limit_bonus = 0
@export var spawn_pool_bonus = 0
@export var initial_population_bonus = 0
@export var spawn_distance = 100
@export var initial_guard = false
@export var initial_hider = false
@export var initial_hider_chance = 25
@export var disable_hiding = false

@export var enemy_type_override_enabled = false
@export var bandit_spawn_mode = 0
@export var guard_spawn_mode = 0
@export var military_spawn_mode = 0

@export var bandit_infighting_enabled = false
@export var guard_infighting_enabled = false
@export var military_infighting_enabled = false
@export var warfare_enabled = false
@export var player_faction_alignment = 0
@export var corpse_cleanup_limit = 20
@export var player_invulnerable = false
@export var show_debug_overlay = true
@export var replenish_spawn_pool = true

@export var ai_health_multiplier = 1.0
@export var boss_health_multiplier = 1.0
@export var ai_sight_multiplier = 1.0
@export var ai_hearing_multiplier = 1.0
@export var ai_accuracy_multiplier = 1.0
@export var ai_fire_rate_multiplier = 1.0
@export var ai_gunshot_alert_duration = 5.0

# 0=Passive, 1=Default, 2=Aggressive, 3=Relentless
@export var ai_tactics_preset = 1

var mcm_enabled = false
