extends Node

# Autoload entry point. Owns the debug overlay, state tracking, MCM compat
# patch, and instantiates the per-vanilla-script hook hosts as children.
# All hook callback bodies live in CharacterHooks.gd, SpawnerHooks.gd,
# and AIHooks.gd respectively.

const EnemyAISettings := preload("res://RoadToVostokEnemyAI/EnemyAISettings.tres")
const _CharacterHooksScript := preload("res://RoadToVostokEnemyAI/CharacterHooks.gd")
const _SpawnerHooksScript := preload("res://RoadToVostokEnemyAI/SpawnerHooks.gd")
const _AIHooksScript := preload("res://RoadToVostokEnemyAI/AIHooks.gd")

var debugLayer: CanvasLayer
var debugLabel: Label
var currentMap = "Unknown"
var currentZone = "Unknown"
var spawnedThisMap = 0
var activeAI = 0
var spawnLimit = 0
var spawnPool = 0
var spawnDistance = 0
var lastEvent = "Waiting for map"
var presetName = "Default"
var rateName = "Vanilla"
var currentFaction = "Unknown"
var currentTarget = "None"
var deathCount = 0
var suspiciousSpawnCount = 0
var corpseCleanupCount = 0
var corpseCleanupLimit = 0
var corpseRecords: Array = []
var corpseSequence = 0
var hitCounts = {
	"Torso": 0,
	"Head": 0,
	"Legs": 0,
	"Other": 0,
	"RootFallback": 0,
}
var spawnCountsByFaction = {
	"Bandit": 0,
	"Guard": 0,
	"Military": 0,
	"Punisher": 0,
}
var spawnCountsByRole = {
	"Wanderer": 0,
	"Guard": 0,
	"Hider": 0,
	"Minion": 0,
	"Boss": 0,
}
var mcm_compat_patch_attempted = false
var mcm_compat_patch_applied = false
var mcm_compat_timer = 0.0

var _character_hooks: Node = null
var _spawner_hooks: Node = null
var _ai_hooks: Node = null


func _ready():
	name = "EnemyAIMain"

	# Spin up the per-vanilla-script hook hosts as children of this autoload.
	# Each one registers its own hooks once frameworks_ready fires.
	_character_hooks = _CharacterHooksScript.new()
	_character_hooks.name = "CharacterHooks"
	add_child(_character_hooks)

	_spawner_hooks = _SpawnerHooksScript.new()
	_spawner_hooks.name = "SpawnerHooks"
	add_child(_spawner_hooks)

	_ai_hooks = _AIHooksScript.new()
	_ai_hooks.name = "AIHooks"
	add_child(_ai_hooks)

	if Engine.has_meta("RTVModLib"):
		var lib = Engine.get_meta("RTVModLib")
		if lib._is_ready:
			_register_all_hooks(lib)
		else:
			lib.frameworks_ready.connect(_register_all_hooks.bind(lib))
	else:
		push_warning("Faction Warfare: RTVModLib not found; hooks unavailable")

	call_deferred("_schedule_mcm_compatibility_patch")
	_ensure_debug_overlay()


func _register_all_hooks(lib) -> void:
	_character_hooks.register_hooks(lib)
	_spawner_hooks.register_hooks(lib, self)
	_ai_hooks.register_hooks(lib, self, _spawner_hooks)


func _process(delta):
	# Recreate the overlay if its layer was freed (defensive; shouldn't happen
	# in normal flow since the autoload owns the layer). Visibility is driven
	# directly by Config.gd's MCM callback (set_debug_overlay_visible), not
	# polled here, so toggling MCM updates the overlay immediately without
	# requiring a process tick to notice.
	if !is_instance_valid(debugLayer):
		_ensure_debug_overlay()

	if !mcm_compat_patch_applied and mcm_compat_patch_attempted:
		mcm_compat_timer -= delta
		if mcm_compat_timer <= 0.0:
			_apply_mcm_compatibility_patch()

	_prune_invalid_corpse_records()
	_enforce_corpse_limit()


func _schedule_mcm_compatibility_patch():
	mcm_compat_patch_attempted = true
	mcm_compat_timer = 1.0


func _apply_mcm_compatibility_patch():
	var mcm_main_path = "res://ModConfigurationMenu/Main.gd"
	if !FileAccess.file_exists(mcm_main_path):
		mcm_compat_patch_applied = true
		return

	var file = FileAccess.open(mcm_main_path, FileAccess.READ)
	if file == null:
		mcm_compat_patch_applied = true
		return

	var source = file.get_as_text()
	file.close()

	var vulnerable_signature = 'MCMHelpers.SettingsMenu = get_tree().root.find_child("Map", true, false).find_child("Settings", true, false)'
	if source.find(vulnerable_signature) == -1:
		mcm_compat_patch_applied = true
		return

	var compat_script: Script = load("res://RoadToVostokEnemyAI/MCMCompat_Main.gd")
	if compat_script == null:
		mcm_compat_patch_applied = true
		return

	compat_script.reload()
	compat_script.take_over_path(mcm_main_path)

	var live_mcm = get_node_or_null("/root/MCM")
	if is_instance_valid(live_mcm):
		live_mcm.set_script(compat_script)

	mcm_compat_patch_applied = true


# === Public API for hook hosts to push state into the debug overlay =========

func begin_map(map_name: String, zone_name: String, info: Dictionary = {}):
	currentMap = map_name
	currentZone = zone_name
	spawnedThisMap = 0
	activeAI = 0
	spawnLimit = int(info.get("spawn_limit", 0))
	spawnPool = int(info.get("spawn_pool", 0))
	spawnDistance = int(info.get("spawn_distance", 0))
	presetName = str(info.get("preset_name", "Default"))
	rateName = str(info.get("rate_name", "Vanilla"))
	currentFaction = str(info.get("current_faction", "Unknown"))
	currentTarget = str(info.get("current_target", "None"))
	deathCount = 0
	suspiciousSpawnCount = 0
	corpseCleanupCount = 0
	corpseCleanupLimit = int(EnemyAISettings.corpse_cleanup_limit)
	corpseRecords.clear()
	corpseSequence = 0
	hitCounts = {"Torso": 0, "Head": 0, "Legs": 0, "Other": 0, "RootFallback": 0}
	spawnCountsByFaction = {"Bandit": 0, "Guard": 0, "Military": 0, "Punisher": 0}
	spawnCountsByRole = {"Wanderer": 0, "Guard": 0, "Hider": 0, "Minion": 0, "Boss": 0}
	lastEvent = str(info.get("last_event", "Map loaded"))
	_render_debug()


func record_spawn(event_name: String, active_count: int, info: Dictionary = {}):
	spawnedThisMap += 1
	activeAI = active_count
	spawnLimit = int(info.get("spawn_limit", spawnLimit))
	spawnPool = int(info.get("spawn_pool", spawnPool))
	spawnDistance = int(info.get("spawn_distance", spawnDistance))
	presetName = str(info.get("preset_name", presetName))
	rateName = str(info.get("rate_name", rateName))
	currentFaction = str(info.get("current_faction", currentFaction))
	if info.has("current_target"):
		currentTarget = str(info["current_target"])
	var factionName = str(info.get("spawn_faction", "Unknown"))
	var roleName = str(info.get("spawn_role", "Unknown"))
	if spawnCountsByFaction.has(factionName):
		spawnCountsByFaction[factionName] += 1
	if spawnCountsByRole.has(roleName):
		spawnCountsByRole[roleName] += 1
	lastEvent = event_name
	_render_debug()


func update_status(active_count: int, info: Dictionary = {}):
	activeAI = active_count
	corpseCleanupLimit = int(EnemyAISettings.corpse_cleanup_limit)
	spawnLimit = int(info.get("spawn_limit", spawnLimit))
	spawnPool = int(info.get("spawn_pool", spawnPool))
	spawnDistance = int(info.get("spawn_distance", spawnDistance))
	if info.has("preset_name"):
		presetName = str(info["preset_name"])
	if info.has("rate_name"):
		rateName = str(info["rate_name"])
	if info.has("current_faction"):
		currentFaction = str(info["current_faction"])
	if info.has("current_target"):
		currentTarget = str(info["current_target"])
	if info.has("last_event"):
		lastEvent = str(info["last_event"])
	_render_debug()


func record_hit(hit_type: String, used_root_fallback: bool = false):
	if used_root_fallback:
		hitCounts["RootFallback"] += 1
	else:
		match hit_type:
			"Torso":          hitCounts["Torso"] += 1
			"Head":           hitCounts["Head"] += 1
			"Leg_L", "Leg_R": hitCounts["Legs"] += 1
			_:                hitCounts["Other"] += 1
	_render_debug()


func record_death(active_count: int, info: Dictionary = {}):
	deathCount += 1
	update_status(active_count, info)


func register_corpse(corpse: Node, info: Dictionary = {}):
	if !is_instance_valid(corpse):
		return
	_prune_invalid_corpse_records()
	corpseSequence += 1
	corpseRecords.append({
		"node": corpse,
		"sequence": corpseSequence,
		"label": str(info.get("label", corpse.name)),
		"faction": str(info.get("faction", "Unknown")),
	})
	_enforce_corpse_limit()
	_render_debug()


func record_suspicious_spawn(event_name: String, active_count: int, info: Dictionary = {}):
	suspiciousSpawnCount += 1
	update_status(active_count, info)
	lastEvent = event_name
	_render_debug()


# === Debug overlay ==========================================================

# Public: called from Config.gd's MCM callback when the show_debug_overlay
# toggle changes. Updates the live label visibility immediately. Safe to call
# before _ensure_debug_overlay has run (no-op if the label isn't built yet;
# next _ensure_debug_overlay reads the current value during creation).
func set_debug_overlay_visible(visible: bool) -> void:
	if is_instance_valid(debugLabel):
		debugLabel.visible = visible


func _ensure_debug_overlay():
	debugLayer = CanvasLayer.new()
	debugLayer.layer = 100
	add_child(debugLayer)

	debugLabel = Label.new()
	debugLabel.name = "EnemyAIDebug"
	debugLabel.position = Vector2(12, 12)
	debugLabel.size = Vector2(980, 360)
	debugLabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	debugLabel.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	debugLabel.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	debugLabel.add_theme_constant_override("shadow_offset_x", 2)
	debugLabel.add_theme_constant_override("shadow_offset_y", 2)
	debugLayer.add_child(debugLabel)
	debugLabel.visible = EnemyAISettings.show_debug_overlay

	_render_debug()


func _render_debug():
	if !is_instance_valid(debugLabel):
		return

	var liveCapSummary = "LIVE CAP: %d | PRESET: %s | RATE: %s" % [spawnLimit, presetName, rateName]
	var factionSummary = "Bandit %d | Guard %d | Military %d | Punisher %d" % [
		spawnCountsByFaction["Bandit"], spawnCountsByFaction["Guard"],
		spawnCountsByFaction["Military"], spawnCountsByFaction["Punisher"]]
	var roleSummary = "Wanderer %d | Guard %d | Hider %d | Minion %d | Boss %d" % [
		spawnCountsByRole["Wanderer"], spawnCountsByRole["Guard"], spawnCountsByRole["Hider"],
		spawnCountsByRole["Minion"], spawnCountsByRole["Boss"]]
	var hitSummary = "Deaths %d | Torso %d | Head %d | Legs %d | Root %d" % [
		deathCount, hitCounts["Torso"], hitCounts["Head"], hitCounts["Legs"], hitCounts["RootFallback"]]
	var spawnAuditSummary = "Suspicious Spawns %d" % suspiciousSpawnCount
	var corpseSummary = "Corpses %d | Cleaned %d | Limit %d" % [
		corpseRecords.size(), corpseCleanupCount, corpseCleanupLimit]
	var spectatorStatus = "ON" if EnemyAISettings.player_invulnerable else "OFF"

	debugLabel.text = "\n".join([
		"Enemy AI Debug",
		"Map: %s | Zone: %s" % [currentMap, currentZone],
		liveCapSummary,
		"Faction Pool: %s" % currentFaction,
		"Spectator Invulnerable: %s" % spectatorStatus,
		"Current Target: %s" % currentTarget,
		"Spawned This Map: %d | Active AI: %d" % [spawnedThisMap, activeAI],
		"Spawn Limit: %d | Spawn Pool: %d | Distance: %d" % [spawnLimit, spawnPool, spawnDistance],
		"Spawn Audit: %s" % spawnAuditSummary,
		"Corpse Cleanup: %s" % corpseSummary,
		"Combat Totals: %s" % hitSummary,
		"Faction Totals: %s" % factionSummary,
		"Role Totals: %s" % roleSummary,
		"Last Event: %s" % lastEvent,
	])


func _prune_invalid_corpse_records():
	if corpseRecords.is_empty():
		return
	var validRecords: Array = []
	for record in corpseRecords:
		var corpse = record.get("node", null)
		if is_instance_valid(corpse):
			validRecords.append(record)
	corpseRecords = validRecords


func _enforce_corpse_limit():
	var limit = int(EnemyAISettings.corpse_cleanup_limit)
	corpseCleanupLimit = limit
	if limit <= 0:
		return
	while corpseRecords.size() > limit:
		var oldestRecord = corpseRecords.pop_front()
		var corpse = oldestRecord.get("node", null)
		if !is_instance_valid(corpse):
			continue
		if corpse.has_meta("enemy_ai_cleanup_queued"):
			continue
		corpse.set_meta("enemy_ai_cleanup_queued", true)
		corpse.call_deferred("queue_free")
		corpseCleanupCount += 1
		lastEvent = "Cleaned oldest corpse: %s (%s)" % [
			str(oldestRecord.get("faction", "Unknown")),
			str(oldestRecord.get("label", corpse.name)),
		]
