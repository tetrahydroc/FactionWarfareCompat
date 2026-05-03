extends Node

# Hook bodies for vanilla AISpawner.gd. Implements the faction-pool spawn
# system + spawn cadence override + suspicious-spawn auditing.
#
# Per-spawner state (factionPool, currentFactionName, spawnedThisMap, etc.)
# lives on the AISpawner node's metadata since multiple spawners can exist
# (one per zone-scene). Helper methods take the spawner as an explicit arg.
#
# `_ready` and `CreatePools` are full replaces because they substitute
# vanilla's single-faction setup with mixed-faction pools that vanilla has
# no compositional surface for. Other methods are pre/post pairs.

const EnemyAISettings := preload("res://RoadToVostokEnemyAI/EnemyAISettings.tres")

const SPAWN_AUDIT_RAY_ABOVE := 3.0
const SPAWN_AUDIT_RAY_BELOW := 20.0
const SPAWN_AUDIT_BELOW_FLOOR_THRESHOLD := 2.5
const SPAWN_AUDIT_ABOVE_FLOOR_THRESHOLD := 6.0

var _lib = null
var main: Node = null  # back-ref to Main.gd for record_spawn/update_status/etc.


# --- Meta access helpers ----------------------------------------------------
# Godot 4.6's Object.get_meta(key, default) emits a log error every time the
# key is missing, even with a default. has_meta gate makes unset keys silent.

static func _meta_get(node: Object, key: String, default_value: Variant) -> Variant:
	if node.has_meta(key):
		return node.get_meta(key)
	return default_value

static func _meta_get_float(node: Object, key: String, default_value: float) -> float:
	if node.has_meta(key):
		return float(node.get_meta(key))
	return default_value


func register_hooks(lib, main_ref: Node) -> void:
	_lib = lib
	main = main_ref
	_lib.hook("aispawner-_physics_process-pre",   _on_phys_pre)
	_lib.hook("aispawner-_physics_process-post",  _on_phys_post)
	_lib.hook("aispawner-_ready",                 _replace_ready)
	_lib.hook("aispawner-createpools",            _replace_create_pools)
	_lib.hook("aispawner-spawnwanderer-pre",      _on_spawn_pre_0arg)
	_lib.hook("aispawner-spawnwanderer-post",     _on_spawn_wanderer_post)
	_lib.hook("aispawner-spawnguard-pre",         _on_spawn_pre_0arg)
	_lib.hook("aispawner-spawnguard-post",        _on_spawn_guard_post)
	_lib.hook("aispawner-spawnhider-pre",         _on_spawn_pre_0arg)
	_lib.hook("aispawner-spawnhider-post",        _on_spawn_hider_post)
	_lib.hook("aispawner-spawnminion-pre",        _on_spawn_minion_pre)
	_lib.hook("aispawner-spawnminion-post",       _on_spawn_minion_post)
	_lib.hook("aispawner-spawnboss-pre",          _on_spawn_boss_pre)
	_lib.hook("aispawner-spawnboss-post",         _on_spawn_boss_post)
	print("Faction Warfare: AISpawner hooks registered")


# --- Replace: aispawner-_ready -----------------------------------------------
# Vanilla picks one agent based on zone. We pick a mixed faction pool, set
# spawn limits from the preset profile, run initial population, fire MapStart
# debug event.
func _replace_ready() -> void:
	var spawner = _lib._caller
	if spawner == null:
		return

	spawner.GetPoints()
	spawner.HidePoints()

	spawner.active = true
	spawner.spawnDistance = EnemyAISettings.spawn_distance
	spawner.spawnLimit = _spawn_limit()
	spawner.spawnPool = _spawn_pool()
	spawner.initialGuard = EnemyAISettings.initial_guard
	spawner.initialHider = EnemyAISettings.initial_hider
	spawner.noHiding = EnemyAISettings.disable_hiding

	_debug_begin_map(spawner, "Spawner initialized")

	if !spawner.active:
		return

	spawner.agent = _select_agent_scene(spawner)
	var faction_pool := _build_faction_pool(spawner)
	spawner.set_meta("factionPool", faction_pool)
	spawner.set_meta("currentFactionName", _describe_faction_pool(spawner))
	spawner.set_meta("spawnedThisMap", 0)

	spawner.CreatePools()
	_initial_population(spawner, _initial_population_count())

	if spawner.initialGuard:
		spawner.SpawnGuard()

	if spawner.initialHider:
		if randi_range(0, 100) < EnemyAISettings.initial_hider_chance:
			spawner.SpawnHider()

	_lib.skip_super()


# --- Replace: aispawner-createpools ------------------------------------------
# Vanilla creates a uniform pool from `agent`. We create a mixed-faction pool
# from the precomputed factionPool meta, plus a single Punisher boss.
func _replace_create_pools() -> void:
	var spawner = _lib._caller
	if spawner == null:
		return
	spawner.APool.global_position = Vector3(0, 1000, 0)
	spawner.BPool.global_position = Vector3(0, 1000, 0)

	var faction_pool: Array = _meta_get(spawner, "factionPool", [])
	if !faction_pool.is_empty():
		for _amount in spawner.spawnPool:
			var next_scene = faction_pool.pick_random()
			var newAgent = next_scene.instantiate()
			spawner.APool.add_child(newAgent, true)
			newAgent.boss = false
			newAgent.AISpawner = spawner
			newAgent.set_meta("enemy_ai_faction", _packed_scene_name(spawner, next_scene))
			newAgent.global_position = spawner.APool.global_position + Vector3(randf_range(-10, 10), 0, randf_range(-10, 10))
			newAgent.Pause()

	var newBoss = spawner.punisher.instantiate()
	spawner.BPool.add_child(newBoss, true)
	newBoss.boss = true
	newBoss.AISpawner = spawner
	newBoss.set_meta("enemy_ai_faction", "Punisher")
	newBoss.global_position = spawner.BPool.global_position + Vector3(randf_range(-10, 10), 0, randf_range(-10, 10))
	newBoss.Pause()

	_lib.skip_super()


# --- Pre+post on aispawner-_physics_process ---------------------------------
# Vanilla runs its spawn cadence (spawnFrequency enum). After vanilla's
# spawnTime crosses zero and gets reset, we overwrite it with the mod's
# preset-profile range. Detection: prev<=0 && current>0 means vanilla just
# wrote a fresh spawnTime.
func _on_phys_pre(_delta: float) -> void:
	var spawner = _lib._caller
	if spawner == null:
		return
	spawner.set_meta("_fw_prev_spawnTime", float(spawner.spawnTime))


func _on_phys_post(_delta: float) -> void:
	var spawner = _lib._caller
	if spawner == null or not spawner.has_meta("_fw_prev_spawnTime"):
		return
	var prev: float = _meta_get_float(spawner, "_fw_prev_spawnTime", 0.0)
	spawner.remove_meta("_fw_prev_spawnTime")
	if prev <= 0.0 and spawner.spawnTime > 0.0:
		var profile := _interval_profile()
		spawner.spawnTime = randf_range(profile["min"], profile["max"])
		_debug_push_status(spawner, "Spawn timer reset")


# --- Pre+post: spawn methods ------------------------------------------------
# Pre stashes activeAgents BEFORE vanilla runs so the post can detect "did
# vanilla actually spawn anything." Vanilla may bail (no points available
# etc.) without changing activeAgents.

func _on_spawn_pre_0arg() -> void:
	var spawner = _lib._caller
	if spawner == null:
		return
	spawner.set_meta("_fw_before_active", spawner.activeAgents)


func _on_spawn_minion_pre(_pos) -> void:
	var spawner = _lib._caller
	if spawner == null:
		return
	spawner.set_meta("_fw_before_active", spawner.activeAgents)


func _on_spawn_boss_pre(_pos) -> void:
	var spawner = _lib._caller
	if spawner == null:
		return
	spawner.set_meta("_fw_before_active", spawner.activeAgents)


func _on_spawn_wanderer_post() -> void:
	var spawner = _lib._caller
	if spawner == null:
		return
	_handle_spawn_result(spawner, "Wanderer", _meta_get(spawner, "_fw_before_active", spawner.activeAgents))


func _on_spawn_guard_post() -> void:
	var spawner = _lib._caller
	if spawner == null:
		return
	_handle_spawn_result(spawner, "Guard", _meta_get(spawner, "_fw_before_active", spawner.activeAgents))


func _on_spawn_hider_post() -> void:
	var spawner = _lib._caller
	if spawner == null:
		return
	_handle_spawn_result(spawner, "Hider", _meta_get(spawner, "_fw_before_active", spawner.activeAgents))


func _on_spawn_minion_post(_pos) -> void:
	var spawner = _lib._caller
	if spawner == null:
		return
	_handle_spawn_result(spawner, "Minion", _meta_get(spawner, "_fw_before_active", spawner.activeAgents))


func _on_spawn_boss_post(_pos) -> void:
	var spawner = _lib._caller
	if spawner == null:
		return
	_handle_spawn_result(spawner, "Boss", _meta_get(spawner, "_fw_before_active", spawner.activeAgents))


# Public method called from AIHooks's death handler. Refills the regular
# spawn pool when an AI dies, if the setting is enabled.
func replenish_regular_pool(spawner: Node, faction_name: String) -> void:
	if !EnemyAISettings.replenish_spawn_pool:
		return
	var scene_resource = _scene_for_faction_name(spawner, faction_name)
	if scene_resource == null:
		return
	var newAgent = scene_resource.instantiate()
	spawner.APool.add_child(newAgent, true)
	newAgent.boss = false
	newAgent.AISpawner = spawner
	newAgent.set_meta("enemy_ai_faction", faction_name)
	newAgent.global_position = spawner.APool.global_position + Vector3(randf_range(-10, 10), 0, randf_range(-10, 10))
	newAgent.Pause()


# --- Preset profile + scaling -----------------------------------------------

func _preset_profile() -> Dictionary:
	match EnemyAISettings.intensity_preset:
		1: return {"spawn_limit": 8,  "spawn_pool": 24,  "initial_population": 2,  "spawn_min": 5.0, "spawn_max": 28.0}
		2: return {"spawn_limit": 12, "spawn_pool": 36,  "initial_population": 4,  "spawn_min": 4.0, "spawn_max": 20.0}
		3: return {"spawn_limit": 16, "spawn_pool": 48,  "initial_population": 5,  "spawn_min": 3.0, "spawn_max": 16.0}
		4: return {"spawn_limit": 32, "spawn_pool": 96,  "initial_population": 10, "spawn_min": 1.5, "spawn_max": 8.0}
		5: return {"spawn_limit": 52, "spawn_pool": 156, "initial_population": 16, "spawn_min": 0.9, "spawn_max": 4.5}
		_: return {"spawn_limit": 3,  "spawn_pool": 10,  "initial_population": 0,  "spawn_min": 10.0, "spawn_max": 60.0}


func _rate_scale() -> float:
	match EnemyAISettings.spawn_rate_adjustment:
		0: return 1.25
		2: return 0.75
		_: return 1.0


func _spawn_limit() -> int:
	return max(1, _preset_profile()["spawn_limit"] + EnemyAISettings.spawn_limit_bonus)


func _spawn_pool() -> int:
	return max(1, _preset_profile()["spawn_pool"] + EnemyAISettings.spawn_pool_bonus)


func _initial_population_count() -> int:
	return max(0, _preset_profile()["initial_population"] + EnemyAISettings.initial_population_bonus)


func _interval_profile() -> Dictionary:
	var profile := _preset_profile()
	var rate := _rate_scale()
	return {"min": max(0.5, profile["spawn_min"] * rate), "max": max(1.0, profile["spawn_max"] * rate)}


# --- Faction pool building --------------------------------------------------

func _select_agent_scene(spawner: Node):
	return _default_agent_scene(spawner)


func _default_agent_scene(spawner: Node):
	if spawner.zone == spawner.Zone.Area05:
		return spawner.bandit
	elif spawner.zone == spawner.Zone.BorderZone:
		return spawner.guard
	elif spawner.zone == spawner.Zone.Vostok:
		return spawner.military
	return spawner.bandit


func _build_faction_pool(spawner: Node) -> Array:
	var pool: Array = []
	var default_scene = _default_agent_scene(spawner)
	_append_faction_by_mode(pool, default_scene, spawner.bandit, EnemyAISettings.bandit_spawn_mode)
	_append_faction_by_mode(pool, default_scene, spawner.guard, EnemyAISettings.guard_spawn_mode)
	_append_faction_by_mode(pool, default_scene, spawner.military, EnemyAISettings.military_spawn_mode)
	return _dedupe(pool)


func _append_faction_by_mode(pool: Array, default_scene, scene_resource, mode_value: int) -> void:
	var mode := int(mode_value)
	if mode == 2:
		return
	if mode == 1:
		pool.append(scene_resource)
		return
	if scene_resource == default_scene:
		pool.append(scene_resource)


func _dedupe(pool: Array) -> Array:
	var unique: Array = []
	for s in pool:
		if !unique.has(s):
			unique.append(s)
	return unique


func _describe_faction_pool(spawner: Node) -> String:
	var faction_pool: Array = _meta_get(spawner, "factionPool", [])
	var names: Array[String] = []
	for s in faction_pool:
		names.append(_packed_scene_name(spawner, s))
	if names.is_empty():
		return "None"
	return ", ".join(names)


func _packed_scene_name(spawner: Node, scene_resource) -> String:
	if scene_resource == spawner.bandit:
		return "Bandit"
	elif scene_resource == spawner.guard:
		return "Guard"
	elif scene_resource == spawner.military:
		return "Military"
	elif scene_resource == spawner.punisher:
		return "Punisher"
	return "Unknown"


func _scene_for_faction_name(spawner: Node, faction_name: String):
	match faction_name:
		"Bandit":   return spawner.bandit
		"Guard":    return spawner.guard
		"Military": return spawner.military
		_:          return null


# --- Spawn handling ---------------------------------------------------------

func _initial_population(spawner: Node, count: int) -> void:
	for _i in count:
		if spawner.activeAgents < spawner.spawnLimit:
			spawner.SpawnWanderer()


func _handle_spawn_result(spawner: Node, spawn_type: String, before_active: int) -> void:
	spawner.remove_meta("_fw_before_active")
	if spawner.activeAgents > before_active:
		var spawned_this_map: int = int(_meta_get(spawner, "spawnedThisMap", 0)) + 1
		spawner.set_meta("spawnedThisMap", spawned_this_map)
		var spawned_agent = spawner.agents.get_child(spawner.agents.get_child_count() - 1)
		var spawned_faction := "Unknown"
		if spawned_agent and spawned_agent.has_meta("enemy_ai_faction"):
			spawned_faction = str(spawned_agent.get_meta("enemy_ai_faction"))
		_debug_record_spawn(spawner, "%s spawned (%s)" % [spawn_type, spawned_faction], spawn_type, spawned_faction)
		_audit_spawned_agent(spawner, spawned_agent, spawn_type, "spawn")
		_schedule_audit(spawner, spawned_agent, spawn_type)
	else:
		_debug_push_status(spawner, "%s spawn failed" % spawn_type)


# --- Spawn auditing ---------------------------------------------------------

func _schedule_audit(spawner: Node, spawned_agent, spawn_type: String) -> void:
	await get_tree().create_timer(1.25, false).timeout
	if is_instance_valid(spawner):
		_audit_spawned_agent(spawner, spawned_agent, spawn_type, "delayed")


func _audit_spawned_agent(spawner: Node, spawned_agent, spawn_type: String, phase: String) -> void:
	if !is_instance_valid(spawned_agent):
		return
	var audit := _floor_audit(spawned_agent)
	if !bool(audit.get("suspicious", false)):
		return
	var reason := str(audit.get("reason", "unknown"))
	var floor_y := float(audit.get("floor_y", spawned_agent.global_position.y))
	var delta_y := float(audit.get("delta_y", 0.0))
	var source_name := "Unknown"
	if spawned_agent.get("currentPoint") is Node3D:
		source_name = spawned_agent.currentPoint.name
	var event_text := "Suspicious %s spawn (%s): %s dy=%.2f floor=%.2f agent=%.2f point=%s" % [
		spawn_type, phase, reason, delta_y, floor_y, spawned_agent.global_position.y, source_name
	]
	if main and main.has_method("record_suspicious_spawn"):
		main.record_suspicious_spawn(event_text, spawner.activeAgents, _status_info(spawner, event_text))


func _floor_audit(spawned_agent) -> Dictionary:
	var origin: Vector3 = spawned_agent.global_position + Vector3(0, SPAWN_AUDIT_RAY_ABOVE, 0)
	var destination: Vector3 = spawned_agent.global_position + Vector3(0, -SPAWN_AUDIT_RAY_BELOW, 0)
	var query := PhysicsRayQueryParameters3D.create(origin, destination)
	query.exclude = [spawned_agent]
	var result: Dictionary = spawned_agent.get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return {"suspicious": true, "reason": "no_floor_hit"}
	var hit_pos: Vector3 = result["position"]
	var floor_y: float = hit_pos.y
	var delta_y: float = floor_y - spawned_agent.global_position.y
	if delta_y > SPAWN_AUDIT_BELOW_FLOOR_THRESHOLD:
		return {"suspicious": true, "reason": "below_floor_surface", "floor_y": floor_y, "delta_y": delta_y}
	if delta_y < -SPAWN_AUDIT_ABOVE_FLOOR_THRESHOLD:
		return {"suspicious": true, "reason": "floating_above_floor", "floor_y": floor_y, "delta_y": delta_y}
	return {"suspicious": false, "floor_y": floor_y, "delta_y": delta_y}


# --- Debug overlay status pushers ------------------------------------------

func _debug_begin_map(spawner: Node, event_text: String) -> void:
	if main == null or not main.has_method("begin_map"):
		return
	main.begin_map(get_tree().current_scene.name, _zone_name(spawner), {
		"spawn_limit": spawner.spawnLimit,
		"spawn_pool":  spawner.spawnPool,
		"spawn_distance": spawner.spawnDistance,
		"preset_name": _preset_name(),
		"rate_name":   _rate_name(),
		"current_faction": _meta_get(spawner, "currentFactionName", "Unknown"),
		"last_event":  event_text,
	})


func _debug_record_spawn(spawner: Node, event_text: String, role_name: String, faction_name: String) -> void:
	if main == null or not main.has_method("record_spawn"):
		return
	main.record_spawn(event_text, spawner.activeAgents, {
		"spawn_limit": spawner.spawnLimit,
		"spawn_pool":  spawner.spawnPool,
		"spawn_distance": spawner.spawnDistance,
		"preset_name": _preset_name(),
		"rate_name":   _rate_name(),
		"current_faction": _meta_get(spawner, "currentFactionName", "Unknown"),
		"spawn_faction": faction_name,
		"spawn_role":  role_name,
	})


func _debug_push_status(spawner: Node, event_text: String) -> void:
	if main == null or not main.has_method("update_status"):
		return
	main.update_status(spawner.activeAgents, _status_info(spawner, event_text))


func _status_info(spawner: Node, event_text: String) -> Dictionary:
	return {
		"spawn_limit": spawner.spawnLimit,
		"spawn_pool":  spawner.spawnPool,
		"spawn_distance": spawner.spawnDistance,
		"preset_name": _preset_name(),
		"rate_name":   _rate_name(),
		"current_faction": _meta_get(spawner, "currentFactionName", "Unknown"),
		"last_event":  event_text,
	}


func _zone_name(spawner: Node) -> String:
	match spawner.zone:
		spawner.Zone.Area05:     return "Area05"
		spawner.Zone.BorderZone: return "BorderZone"
		spawner.Zone.Vostok:     return "Vostok"
		_:                       return "Unknown"


func _preset_name() -> String:
	match EnemyAISettings.intensity_preset:
		1: return "Medium"
		2: return "Medium High"
		3: return "High"
		4: return "Very High"
		5: return "Insane"
		_: return "Default"


func _rate_name() -> String:
	match EnemyAISettings.spawn_rate_adjustment:
		0: return "Lower"
		2: return "Higher"
		_: return "Vanilla"
