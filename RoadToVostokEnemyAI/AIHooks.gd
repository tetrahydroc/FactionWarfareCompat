extends Node

# Hook bodies for vanilla AI.gd. Implements faction warfare, faction
# infighting, AI-vs-AI targeting/audio sensing, recoil/spread overrides,
# spawn-pool replenishment on death, and debug overlay tracking.
#
# Per-AI mod state lives entirely on the AI node's metadata (via set_meta),
# since each AI instance needs its own targeting/timer/jitter values and
# this script can't add member vars to the wrapped vanilla AI class.
# Helper methods take the AI as an explicit `ai` arg.
#
# Pattern split:
#   * Activate -- pre (init mod state before vanilla runs)
#   * Parameters/ChangeState/Death -- post (additive after vanilla)
#   * LOSCheck/Hearing/FireFrequency/GetHide/Vantage/Cover/Shift/Spine
#     -- pre+post stash-and-restore (vanilla runs unmodified, we tweak the
#     state vanilla reads before, restore after)
#   * Sensor/Decision/Shift/Hunt/Attack/Return/Fire/FireAccuracy/Raycast
#     /FireDetection -- replace (genuine wholesale rewrites of vanilla logic)

const EnemyAISettings := preload("res://RoadToVostokEnemyAI/EnemyAISettings.tres")

const PLAYER_PRIORITY_LOS_TIME := 3.0
const PLAYER_PRIORITY_HEARING_TIME := 2.5
const PLAYER_PRIORITY_GUNSHOT_TIME := 3.5
const AI_HEARING_RUN_DISTANCE := 22.0
const AI_HEARING_WALK_DISTANCE := 8.0
const AI_HEARING_GUNSHOT_DISTANCE := 60.0
const AI_GUNSHOT_MEMORY_TIME := 1.25
const AI_AUDIO_LOG_COOLDOWN := 2.0

var _lib = null
var main: Node = null  # back-ref to Main.gd for record_*/update_status calls
var spawner_hooks: Node = null  # back-ref for replenish_regular_pool
var _gameData: Resource = preload("res://Resources/GameData.tres")


func register_hooks(lib, main_ref: Node, spawner_hooks_ref: Node) -> void:
	_lib = lib
	main = main_ref
	spawner_hooks = spawner_hooks_ref
	_lib.hook_many({
		# Composable -- pre
		"ai-activate-pre":             _on_activate_pre,

		# Composable -- post
		"ai-parameters-post":          _on_parameters_post,
		"ai-changestate-post":         _on_changestate_post,
		"ai-death-post":               _on_death_post,

		# Composable -- pre+post stash-and-restore
		"ai-loscheck-pre":             _on_loscheck_pre,
		"ai-loscheck-post":            _on_loscheck_post,
		"ai-hearing-pre":              _on_hearing_pre,
		"ai-hearing-post":             _on_hearing_post,
		"ai-firefrequency-pre":        _on_firefreq_pre,
		"ai-firefrequency-post":       _on_firefreq_post,
		"ai-gethidepoint-pre":         _on_gethide_pre,
		"ai-gethidepoint-post":        _on_gethide_post,
		"ai-getvantagepoint-pre":      _on_getvantage_pre,
		"ai-getvantagepoint-post":     _on_getvantage_post,
		"ai-getcoverpoint-pre":        _on_getcover_pre,
		"ai-getcoverpoint-post":       _on_getcover_post,
		"ai-getshiftwaypoint-pre":     _on_getshift_pre,
		"ai-getshiftwaypoint-post":    _on_getshift_post,
		"ai-spine-pre":                _on_spine_pre,
		"ai-spine-post":               _on_spine_post,

		# Replace
		"ai-sensor":                   _replace_sensor,
		"ai-firedetection":            _replace_firedetection,
		"ai-decision":                 _replace_decision,
		"ai-shift":                    _replace_shift,
		"ai-hunt":                     _replace_hunt,
		"ai-attack":                   _replace_attack,
		"ai-return":                   _replace_return,
		"ai-fire":                     _replace_fire,
		"ai-fireaccuracy":             _replace_fireaccuracy,
		"ai-raycast":                  _replace_raycast,
	})
	print("Faction Warfare: AI hooks registered")


# === Per-AI state init ======================================================

# Called from activate-pre. Seeds all the mod-added timer/jitter values on
# the AI node's meta. Idempotent -- safe to call again on respawn.
func _ai_init_state(ai: Node) -> void:
	ai.set_meta("currentAITarget", null)
	ai.set_meta("currentAITargetVisible", false)
	ai.set_meta("currentAITargetDistance", 9999.0)
	ai.set_meta("targetRefreshTimer", randf_range(0.0, _current_target_refresh_cycle(ai)))
	ai.set_meta("targetRefreshCycle", 0.4)
	ai.set_meta("targetRefreshJitter", randf_range(0.0, 0.12))
	ai.set_meta("targetVisibilityTimer", randf_range(0.0, _current_target_visibility_cycle(ai)))
	ai.set_meta("targetVisibilityJitter", randf_range(0.0, 0.06))
	ai.set_meta("aiAudioSenseTimer", randf_range(0.0, _current_ai_audio_cycle(ai)))
	ai.set_meta("aiAudioSenseJitter", randf_range(0.0, 0.1))
	ai.set_meta("targetLabel", "None")
	ai.set_meta("previousAITargetVisible", false)
	ai.set_meta("playerPriorityTimer", 0.0)
	ai.set_meta("playerPriorityReason", "")
	ai.set_meta("lastAISoundTarget", null)
	ai.set_meta("lastAISoundReason", "")
	ai.set_meta("aiAudioLogCooldowns", {})


# === Composable -- pre/post hook bodies =====================================

func _on_activate_pre() -> void:
	var ai = _lib._caller
	if ai == null:
		return
	# Apply health multipliers from settings before vanilla writes the value.
	# Vanilla's Activate sets `health = 100.0` (or 300 for boss) unconditionally,
	# so we override it AFTER vanilla via a meta marker; keep the mod state init.
	_ai_init_state(ai)
	ai.set_meta("_fw_apply_health_mult", true)


func _on_parameters_post(delta: float) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	# First-tick health multiplier application. Activate-pre sets the marker;
	# we apply on the first Parameters-post since vanilla's Activate has run
	# by then and written the base health.
	if ai.has_meta("_fw_apply_health_mult"):
		ai.remove_meta("_fw_apply_health_mult")
		if ai.boss:
			ai.health = 300.0 * EnemyAISettings.boss_health_multiplier
		else:
			ai.health = 100.0 * EnemyAISettings.ai_health_multiplier

	_refresh_player_alignment_state(ai)
	var ppt: float = float(ai.get_meta("playerPriorityTimer", 0.0))
	if ppt > 0.0:
		ppt = max(0.0, ppt - delta)
		ai.set_meta("playerPriorityTimer", ppt)
		if _player_priority_active(ai):
			ai.lastKnownLocation = ai.playerPosition
			ai.LKL = ai.playerPosition
	_update_hostile_ai_targeting(ai, delta)


func _on_changestate_post(_state) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	var cycle_scale := _tactics_cycle_scale()
	if ai.currentState == ai.State.Guard:
		ai.guardCycle *= cycle_scale
	elif ai.currentState == ai.State.Defend:
		ai.defendCycle *= cycle_scale
	elif ai.currentState == ai.State.Combat:
		ai.combatCycle *= cycle_scale
	elif ai.currentState == ai.State.Shift:
		ai.shiftCycle *= cycle_scale
	elif ai.currentState == ai.State.Hunt:
		ai.huntCycle *= cycle_scale
	elif ai.currentState == ai.State.Attack:
		ai.attackCycle *= cycle_scale
	elif ai.currentState == ai.State.Ambush:
		ai.ambushCycle *= cycle_scale


func _on_death_post(_direction, _force) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	if is_instance_valid(ai.AISpawner) and !ai.boss:
		if spawner_hooks and spawner_hooks.has_method("replenish_regular_pool"):
			spawner_hooks.replenish_regular_pool(ai.AISpawner, _self_faction(ai))
	_clear_ai_target(ai)
	if main:
		if main.has_method("record_death"):
			main.record_death(ai.AISpawner.activeAgents, {
				"last_event": "AI died",
				"current_target": "None",
			})
		if main.has_method("register_corpse"):
			main.register_corpse(ai, {
				"label": ai.name,
				"faction": _self_faction(ai),
			})


# --- LOSCheck pre+post stash-and-restore -----------------------------------
# Modded version multiplies `(25 + extraVisibility)` by ai_sight_multiplier
# AND calls _activate_player_priority on success. Pre inflates extraVisibility
# so vanilla's `(25 + extraVisibility)` lands at the modded value; post
# restores extraVisibility and fires the priority activation if vanilla saw
# the player.

func _on_loscheck_pre(_target: Vector3) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	var sight_mult: float = max(0.1, EnemyAISettings.ai_sight_multiplier)
	if sight_mult == 1.0:
		return  # no-op, no need to stash
	ai.set_meta("_fw_los_orig_extra", float(ai.extraVisibility))
	# Choose the right base for the adjustment matching vanilla's branches.
	# Vanilla: (25 + extra) for TOD==4, (100 + extra) for fog, else 200.
	# We want the final z to be (base_with_extra) * sight_mult.
	var base: float
	if _gameData.TOD == 4 and !_gameData.flashlight and !ai.boss:
		base = 25.0
	elif _gameData.fog and !ai.boss:
		base = 100.0
	else:
		base = 200.0
		# Vanilla's else branch is `Vector3(0, 0, 200)` -- no extraVisibility
		# term. So the formula `target.z = (base + extra) * mult` becomes
		# `target.z = base * mult`. Set extra to base*(mult-1) doesn't apply
		# because vanilla doesn't add extra here. Different approach: stash
		# and let vanilla run, then post overwrites LOS.target_position.
		ai.set_meta("_fw_los_branch_else", true)
		return
	# Solve: (25 + new_extra) = (25 + orig_extra) * mult
	#        new_extra = (25 + orig_extra) * mult - 25
	var orig_extra: float = float(ai.extraVisibility)
	ai.extraVisibility = (base + orig_extra) * sight_mult - base


func _on_loscheck_post(target: Vector3) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	# Restore extraVisibility if we stashed it.
	if ai.has_meta("_fw_los_orig_extra"):
		var orig_extra: float = float(ai.get_meta("_fw_los_orig_extra"))
		ai.extraVisibility = orig_extra
		ai.remove_meta("_fw_los_orig_extra")
	# Else-branch fixup: vanilla's else used Vector3(0,0,200). Multiply post.
	if ai.has_meta("_fw_los_branch_else"):
		ai.remove_meta("_fw_los_branch_else")
		var sight_mult: float = max(0.1, EnemyAISettings.ai_sight_multiplier)
		# Re-run the LOS check with the multiplier applied.
		ai.LOS.target_position = Vector3(0, 0, 200.0 * sight_mult)
		ai.LOS.look_at(target, Vector3.UP, true)
		ai.LOS.force_raycast_update()
		if ai.LOS.is_colliding() and ai.LOS.get_collider().is_in_group("Player"):
			ai.lastKnownLocation = ai.playerPosition
			ai.playerVisible = true
		else:
			ai.playerVisible = false
	# Fire player priority on detection.
	if ai.playerVisible:
		_activate_player_priority(ai, "LOS", PLAYER_PRIORITY_LOS_TIME)


# --- Hearing pre+post stash-and-restore ------------------------------------
# Modded: skip if !_can_target_player(); use multiplied distances; activate
# player priority on detection. Pre divides playerDistance3D by hearing_mult
# so vanilla's hardcoded 20/5 thresholds compare against the scaled value.
# Post restores playerDistance3D and runs activate if vanilla updated LKL.

func _on_hearing_pre() -> void:
	var ai = _lib._caller
	if ai == null:
		return
	if !_can_target_player(ai):
		# Force vanilla to skip its detection by setting playerDistance3D huge.
		ai.set_meta("_fw_hearing_orig_dist", float(ai.playerDistance3D))
		ai.set_meta("_fw_hearing_orig_lkl", ai.lastKnownLocation)
		ai.set_meta("_fw_hearing_skip", true)
		ai.playerDistance3D = 99999.0
		return
	var hearing_mult: float = max(0.1, EnemyAISettings.ai_hearing_multiplier)
	if hearing_mult == 1.0:
		return  # no-op
	ai.set_meta("_fw_hearing_orig_dist", float(ai.playerDistance3D))
	ai.set_meta("_fw_hearing_orig_lkl", ai.lastKnownLocation)
	# Vanilla checks `playerDistance3D < 20 && isRunning` and `< 5 && isWalking`.
	# Divide distance by multiplier so threshold effectively scales by it.
	ai.playerDistance3D = ai.playerDistance3D / hearing_mult


func _on_hearing_post() -> void:
	var ai = _lib._caller
	if ai == null:
		return
	if !ai.has_meta("_fw_hearing_orig_dist"):
		return
	var orig_dist: float = float(ai.get_meta("_fw_hearing_orig_dist"))
	var orig_lkl = ai.get_meta("_fw_hearing_orig_lkl")
	var was_skip: bool = ai.has_meta("_fw_hearing_skip")
	ai.playerDistance3D = orig_dist
	ai.remove_meta("_fw_hearing_orig_dist")
	ai.remove_meta("_fw_hearing_orig_lkl")
	ai.remove_meta("_fw_hearing_skip")
	if was_skip:
		# Make sure vanilla didn't sneak any LKL update in.
		ai.lastKnownLocation = orig_lkl
		return
	# Vanilla updated lastKnownLocation = playerPosition iff it heard the
	# player. Detect by comparing pre-LKL to current.
	if ai.lastKnownLocation != orig_lkl:
		_activate_player_priority(ai, "Hearing", PLAYER_PRIORITY_HEARING_TIME)


# --- FireFrequency pre+post stash-and-restore ------------------------------
# Modded uses _get_engagement_distance() (could be AI target) instead of
# playerDistance3D, AND divides fireTime by ai_fire_rate_multiplier at the
# end. Pre swaps playerDistance3D to engagement distance; post restores +
# applies the rate multiplier.

func _on_firefreq_pre() -> void:
	var ai = _lib._caller
	if ai == null:
		return
	ai.set_meta("_fw_freq_orig_dist", float(ai.playerDistance3D))
	ai.playerDistance3D = _get_engagement_distance(ai)


func _on_firefreq_post() -> void:
	var ai = _lib._caller
	if ai == null or not ai.has_meta("_fw_freq_orig_dist"):
		return
	ai.playerDistance3D = float(ai.get_meta("_fw_freq_orig_dist"))
	ai.remove_meta("_fw_freq_orig_dist")
	var rate_mult: float = max(0.1, EnemyAISettings.ai_fire_rate_multiplier)
	ai.fireTime = max(0.05, ai.fireTime / rate_mult)


# --- GetHide/Vantage/Cover/Shift point pre+post stash-and-restore ---------
# Modded reads _get_engagement_position() instead of playerPosition for
# distance/direction calcs. Swap playerPosition before vanilla, restore after.

func _on_gethide_pre() -> void: _waypoint_pre_swap(_lib._caller)
func _on_gethide_post() -> void: _waypoint_post_restore(_lib._caller)
func _on_getvantage_pre() -> void: _waypoint_pre_swap(_lib._caller)
func _on_getvantage_post() -> void: _waypoint_post_restore(_lib._caller)
func _on_getcover_pre() -> void: _waypoint_pre_swap(_lib._caller)
func _on_getcover_post() -> void: _waypoint_post_restore(_lib._caller)
func _on_getshift_pre() -> void: _waypoint_pre_swap(_lib._caller)
func _on_getshift_post() -> void: _waypoint_post_restore(_lib._caller)


func _waypoint_pre_swap(ai) -> void:
	if ai == null:
		return
	var engagement_pos := _get_engagement_position(ai)
	if engagement_pos == ai.playerPosition:
		return  # no-op
	ai.set_meta("_fw_wp_orig_pp", ai.playerPosition)
	ai.playerPosition = engagement_pos


func _waypoint_post_restore(ai) -> void:
	if ai == null or not ai.has_meta("_fw_wp_orig_pp"):
		return
	ai.playerPosition = ai.get_meta("_fw_wp_orig_pp")
	ai.remove_meta("_fw_wp_orig_pp")


# --- Spine pre+post stash-and-restore --------------------------------------
# Modded uses _get_spine_target_position() instead of LKL for the aim target.
# Stash LKL, swap to spine target if applicable, restore in post.

func _on_spine_pre(_delta: float) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	var spine_target := _get_spine_target_position(ai)
	if spine_target == ai.LKL:
		return  # no-op
	ai.set_meta("_fw_spine_orig_lkl", ai.LKL)
	ai.LKL = spine_target


func _on_spine_post(_delta: float) -> void:
	var ai = _lib._caller
	if ai == null or not ai.has_meta("_fw_spine_orig_lkl"):
		return
	ai.LKL = ai.get_meta("_fw_spine_orig_lkl")
	ai.remove_meta("_fw_spine_orig_lkl")


# === Replace hooks ==========================================================

# --- Replace: ai-sensor ----------------------------------------------------
# Modded re-implements the sensor cycle: player LOS, AI target visibility,
# AI audio sensing, then hearing fallback.
func _replace_sensor(delta: float) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	ai.sensorTimer += delta
	var aas: float = float(ai.get_meta("aiAudioSenseTimer", 0.0)) - delta
	ai.set_meta("aiAudioSenseTimer", aas)

	if ai.sensorTimer > ai.sensorCycle:
		var player_detected := _sense_player_los(ai)

		if _custom_ai_targeting_active(ai):
			_update_target_visibility(ai)
			if !player_detected and _has_valid_ai_target(ai) and bool(ai.get_meta("currentAITargetVisible", false)):
				ai.lastKnownLocation = _get_ai_target_position(ai)
				ai.playerVisible = true
				if ai.currentState == ai.State.Wander or ai.currentState == ai.State.Guard or ai.currentState == ai.State.Patrol:
					ai.Decision()
				elif ai.currentState == ai.State.Ambush:
					ai.ChangeState("Combat")

		if !_player_priority_active(ai) and _custom_ai_targeting_active(ai) and !_has_stable_visible_ai_target(ai) and float(ai.get_meta("aiAudioSenseTimer", 0.0)) <= 0.0:
			_sense_ai_audio(ai)
			ai.set_meta("aiAudioSenseTimer", _current_ai_audio_cycle(ai))

		if !ai.playerVisible:
			ai.Hearing()

		ai.sensorTimer = 0.0
	_lib.skip_super()


# --- Replace: ai-firedetection ---------------------------------------------
func _replace_firedetection(delta: float) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	if !_can_target_player(ai):
		_lib.skip_super()
		return

	ai.fireDetectionTime = EnemyAISettings.ai_gunshot_alert_duration
	var hearing_mult: float = max(0.1, EnemyAISettings.ai_hearing_multiplier)
	var local_alert_distance: float = 50.0 * hearing_mult

	if _gameData.isFiring and !ai.playerVisible:
		if ai.fireVector > 0.95:
			ai.lastKnownLocation = ai.playerPosition
			_activate_player_priority(ai, "Gunshot", PLAYER_PRIORITY_GUNSHOT_TIME)
			ai.fireDetected = true
			ai.extraVisibility = 50.0 * max(0.25, EnemyAISettings.ai_sight_multiplier)
		elif ai.playerDistance3D < local_alert_distance:
			if ai.currentState != ai.State.Ambush:
				ai.lastKnownLocation = ai.playerPosition
			_activate_player_priority(ai, "Nearby gunshot", PLAYER_PRIORITY_GUNSHOT_TIME)
			ai.fireDetected = true
			ai.extraVisibility = 50.0 * max(0.25, EnemyAISettings.ai_sight_multiplier)

	if ai.fireDetected:
		ai.fireDetectionTimer += delta
		if ai.fireDetectionTimer > ai.fireDetectionTime:
			ai.extraVisibility = 0.0
			ai.fireDetectionTimer = 0.0
			ai.fireDetected = false
	_lib.skip_super()


# --- Replace: ai-decision --------------------------------------------------
func _replace_decision() -> void:
	var ai = _lib._caller
	if ai == null:
		return
	var engagement_distance := _get_engagement_distance(ai)
	var engagement_visible := _engagement_visible(ai)
	var can_direct_attack := _can_direct_attack_target(ai)

	if engagement_distance > 20:
		var decision := randi_range(1, 9)
		if decision == 1:
			ai.ChangeState("Combat")
		elif decision == 2 and !ai.AISpawner.noHiding:
			ai.ChangeState("Hide")
		elif decision == 3:
			ai.ChangeState("Cover")
		elif decision == 4:
			ai.ChangeState("Vantage")
		elif decision == 5:
			ai.ChangeState("Defend")
		elif decision == 6 and engagement_visible and engagement_distance < 100 and can_direct_attack:
			ai.ChangeState("Hunt")
		elif decision == 7 and engagement_visible and engagement_distance < 100 and can_direct_attack:
			ai.ChangeState("Shift")
		elif decision == 8 and engagement_visible and engagement_distance < 100 and can_direct_attack and (ai.weaponData.weaponAction != "Manual"):
			ai.ChangeState("Attack")
		else:
			ai.ChangeState("Combat")
	else:
		var decision_close := randi_range(1, 4)
		if decision_close == 1:
			ai.ChangeState("Combat")
		elif decision_close == 2:
			ai.ChangeState("Defend")
		elif decision_close == 3 and engagement_visible and can_direct_attack:
			ai.ChangeState("Hunt")
		elif decision_close == 4 and engagement_visible and can_direct_attack and (ai.weaponData.weaponAction != "Manual"):
			ai.ChangeState("Attack")
		else:
			ai.ChangeState("Combat")
	_lib.skip_super()


# --- Replace: ai-shift -----------------------------------------------------
func _replace_shift(delta: float) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	ai.shiftTimer += delta
	if _engagement_visible(ai):
		ai.Fire(delta)
	if ai.shiftTimer > ai.shiftCycle:
		ai.shiftCount -= 1
		ai.shiftTimer = 0.0
		if !ai.GetShiftWaypoint():
			ai.ChangeState("Combat")
	if ai.shiftCount == 0:
		ai.ChangeState("Combat")
	if _get_engagement_distance(ai) < 10 or ai.agent.is_target_reached() or ai.agent.is_navigation_finished():
		ai.ChangeState("Combat")
	_lib.skip_super()


# --- Replace: ai-hunt ------------------------------------------------------
func _replace_hunt(delta: float) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	ai.huntTimer += delta
	if _engagement_visible(ai):
		ai.Fire(delta)
	if ai.huntTimer > ai.huntCycle:
		ai.GetHuntWaypoint()
		ai.huntTimer = 0.0
	if ai.agent.is_target_reached() or ai.agent.is_navigation_finished() or _player_only_combat_blocked(ai):
		ai.ChangeState("Combat")
	_lib.skip_super()


# --- Replace: ai-attack ----------------------------------------------------
func _replace_attack(delta: float) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	ai.attackTimer += delta
	if _engagement_visible(ai):
		ai.Fire(delta)
	if ai.attackTimer > ai.attackCycle:
		ai.GetAttackWaypoint()
		ai.attackTimer = 0.0
	if ai.agent.is_target_reached() or ai.agent.is_navigation_finished() or _player_only_combat_blocked(ai):
		if ai.attackReturn and !_engagement_visible(ai):
			ai.ChangeState("Return")
		else:
			ai.ChangeState("Combat")
	_lib.skip_super()


# --- Replace: ai-return ----------------------------------------------------
func _replace_return() -> void:
	var ai = _lib._caller
	if ai == null:
		return
	var dist_to_target: float = ai.global_transform.origin.distance_to(ai.agent.target_position)
	if dist_to_target < 2.0:
		ai.speed = 1.0
		ai.turnSpeed = 2.0
	elif dist_to_target < 4.0:
		ai.speed = 3.0
		ai.turnSpeed = 5.0
	if ai.agent.is_target_reached() or ai.agent.is_navigation_finished():
		ai.ChangeState("Combat")
	if _get_engagement_distance(ai) < 10:
		ai.ChangeState("Combat")
	_lib.skip_super()


# --- Replace: ai-fire ------------------------------------------------------
func _replace_fire(delta: float) -> void:
	var ai = _lib._caller
	if ai == null:
		return
	if ai.impact or _player_only_combat_blocked(ai):
		_lib.skip_super()
		return
	if ai.LKL.distance_to(_get_engagement_position(ai)) > 4.0:
		_lib.skip_super()
		return
	if ai.weaponData.weaponAction == "Semi-Auto":
		ai.Selector(delta)
	ai.fireTime -= delta
	if ai.fireTime <= 0:
		_mark_ai_gunshot(ai)
		ai.Raycast()
		ai.PlayFire()
		ai.PlayTail()
		ai.MuzzleVFX()
		ai.impulseTime = ai.spineData.impulse / 2
		ai.impulseTimer = 0.0
		ai.recoveryTime = ai.spineData.impulse
		ai.recoveryTimer = 0.0
		if ai.fullAuto:
			var ix = ai.spineTarget.x - ai.spineData.recoil / 10.0
			ai.impulseTarget = Vector3(ix, ai.spineTarget.y, ai.spineTarget.z)
		else:
			var ix2 = ai.spineTarget.x - ai.spineData.recoil
			ai.impulseTarget = Vector3(ix2, ai.spineTarget.y, ai.spineTarget.z)
		ai.flash.global_position = ai.muzzle.global_position
		ai.flash.Activate()
		ai.FireFrequency()
		if _should_play_player_bullet_audio(ai) and _get_engagement_distance(ai) > 50:
			await get_tree().create_timer(0.1, false).timeout
			if is_instance_valid(ai):
				ai.PlayCrack()
	_lib.skip_super()


# --- Replace: ai-fireaccuracy (returns Vector3) ----------------------------
func _replace_fireaccuracy() -> Vector3:
	var ai = _lib._caller
	if ai == null:
		_lib.skip_super()
		return Vector3.ZERO
	var fireDirection: Vector3 = _get_fire_target_position(ai)
	var spreadMultiplier: float = 1.0
	var accuracy_multiplier: float = max(0.1, EnemyAISettings.ai_accuracy_multiplier)
	var engagement_distance := _get_engagement_distance(ai)
	var ai_target := _has_valid_ai_target(ai)

	if ai.fullAuto and !ai.boss:
		spreadMultiplier = 2.0

	if ai_target:
		var horizontalSpread: float
		var verticalSpread: float
		if engagement_distance < 10 or ai.boss:
			horizontalSpread = 0.05
			verticalSpread = 0.02
		elif engagement_distance > 10 and engagement_distance < 50:
			horizontalSpread = 0.25
			verticalSpread = 0.08
		else:
			horizontalSpread = 0.5
			verticalSpread = 0.15
		fireDirection.x += randf_range(-horizontalSpread, horizontalSpread) * spreadMultiplier / accuracy_multiplier
		fireDirection.y += randf_range(-verticalSpread, verticalSpread) * spreadMultiplier / accuracy_multiplier
	elif engagement_distance < 10 or ai.boss:
		fireDirection.x += randf_range(-0.1, 0.1) * spreadMultiplier / accuracy_multiplier
		fireDirection.y += randf_range(-0.1, 0.1) * spreadMultiplier / accuracy_multiplier
	elif engagement_distance > 10 and engagement_distance < 50:
		fireDirection.x += randf_range(-1.0, 1.0) * spreadMultiplier / accuracy_multiplier
		fireDirection.y += randf_range(-1.0, 1.0) * spreadMultiplier / accuracy_multiplier
	else:
		fireDirection.x += randf_range(-2.0, 2.0) * spreadMultiplier / accuracy_multiplier
		fireDirection.y += randf_range(-2.0, 2.0) * spreadMultiplier / accuracy_multiplier

	_lib.skip_super()
	return fireDirection


# --- Replace: ai-raycast ---------------------------------------------------
func _replace_raycast() -> void:
	var ai = _lib._caller
	if ai == null:
		return
	ai.fire.look_at(ai.FireAccuracy(), Vector3.UP, true)
	ai.fire.force_raycast_update()
	if ai.fire.is_colliding():
		var hitCollider = ai.fire.get_collider()
		if hitCollider is Hitbox:
			_apply_damage_to_hitbox(ai, hitCollider, _shot_damage(ai))
		elif _is_ai_root_hit(ai, hitCollider):
			if !_try_apply_targeted_hitbox_damage(ai, hitCollider):
				var rootDamage := _shot_damage(ai)
				hitCollider.WeaponDamage("Torso", rootDamage)
				if main and main.has_method("record_hit"):
					main.record_hit("Torso", true)
		elif hitCollider.is_in_group("Player"):
			if ai.boss:
				hitCollider.get_child(0).WeaponDamage(ai.weaponData.damage * 2.0, ai.weaponData.penetration)
			else:
				hitCollider.get_child(0).WeaponDamage(ai.weaponData.damage, ai.weaponData.penetration)
		else:
			var hitPoint: Vector3 = ai.fire.get_collision_point()
			var hitNormal: Vector3 = ai.fire.get_collision_normal()
			var hitSurface = hitCollider.get("surface")
			ai.BulletDecal(hitCollider, hitPoint, hitNormal, hitSurface)
	elif _should_play_player_bullet_audio(ai) and _get_engagement_distance(ai) > 50:
		await get_tree().create_timer(0.1, false).timeout
		if is_instance_valid(ai):
			ai.PlayFlyby()
	_lib.skip_super()


# === Helpers (all take ai: Node as first arg) ==============================

# --- Faction targeting predicates ------------------------------------------

func _custom_ai_targeting_active(ai: Node) -> bool:
	if ai.boss:
		return false
	return _same_faction_infighting_active(ai) or _faction_warfare_active(ai)


func _same_faction_infighting_active(ai: Node) -> bool:
	return _same_faction_targeting_allowed(_self_faction(ai))


func _faction_warfare_active(ai: Node) -> bool:
	var faction := _self_faction(ai)
	return EnemyAISettings.warfare_enabled and _is_supported_warfare_faction(faction)


func _player_priority_active(ai: Node) -> bool:
	return float(ai.get_meta("playerPriorityTimer", 0.0)) > 0.0


func _can_target_player(ai: Node) -> bool:
	var aligned := _player_aligned_faction()
	return aligned == "" or aligned != _self_faction(ai)


func _player_aligned_faction() -> String:
	match EnemyAISettings.player_faction_alignment:
		1: return "Bandit"
		2: return "Guard"
		3: return "Military"
		_: return ""


func _self_faction(ai: Node) -> String:
	if ai.has_meta("enemy_ai_faction"):
		return str(ai.get_meta("enemy_ai_faction"))
	return "Unknown"


func _same_faction_targeting_allowed(faction: String) -> bool:
	match faction:
		"Bandit":   return EnemyAISettings.bandit_infighting_enabled
		"Guard":    return EnemyAISettings.guard_infighting_enabled
		"Military": return EnemyAISettings.military_infighting_enabled
		_:          return false


func _is_supported_warfare_faction(faction: String) -> bool:
	return faction == "Bandit" or faction == "Guard" or faction == "Military"


func _is_hostile_faction(self_faction: String, other_faction: String) -> bool:
	if other_faction == "" or other_faction == "Unknown":
		return false
	if self_faction == other_faction:
		return _same_faction_targeting_allowed(self_faction)
	return _is_supported_warfare_faction(self_faction) and _is_supported_warfare_faction(other_faction) and EnemyAISettings.warfare_enabled


# --- Player priority management --------------------------------------------

func _refresh_player_alignment_state(ai: Node) -> void:
	if _can_target_player(ai):
		return
	if _player_priority_active(ai):
		ai.set_meta("playerPriorityTimer", 0.0)
		ai.set_meta("playerPriorityReason", "")
		ai.playerVisible = false
		if !_has_valid_ai_target(ai):
			ai.set_meta("targetLabel", "None")


func _activate_player_priority(ai: Node, reason: String, duration: float) -> void:
	var was_active := _player_priority_active(ai)
	var current: float = float(ai.get_meta("playerPriorityTimer", 0.0))
	ai.set_meta("playerPriorityTimer", max(current, duration))
	ai.set_meta("playerPriorityReason", reason)
	ai.lastKnownLocation = ai.playerPosition
	ai.LKL = ai.playerPosition
	if ai.currentState == ai.State.Wander or ai.currentState == ai.State.Guard or ai.currentState == ai.State.Patrol:
		ai.Decision()
	elif ai.currentState == ai.State.Ambush or ai.currentState == ai.State.Hide or ai.currentState == ai.State.Cover or ai.currentState == ai.State.Vantage or ai.currentState == ai.State.Return or ai.currentState == ai.State.Defend:
		ai.ChangeState("Combat")
	elif !was_active and ai.currentState != ai.State.Combat:
		ai.ChangeState("Combat")


# --- Cycle calculations (active-AI-count scaling) --------------------------

func _active_ai_count(ai: Node) -> int:
	if is_instance_valid(ai.AISpawner):
		return int(ai.AISpawner.activeAgents)
	return 0


func _current_target_refresh_cycle(ai: Node) -> float:
	var active_count := _active_ai_count(ai)
	var jitter: float = float(ai.get_meta("targetRefreshJitter", 0.0))
	var base_cycle: float = float(ai.get_meta("targetRefreshCycle", 0.4)) + jitter
	if active_count >= 64:   base_cycle = 1.45 + jitter
	elif active_count >= 60: base_cycle = 1.36 + jitter
	elif active_count >= 56: base_cycle = 1.3 + jitter
	elif active_count >= 52: base_cycle = 1.22 + jitter
	elif active_count >= 48: base_cycle = 1.15 + jitter
	elif active_count >= 45: base_cycle = 1.08 + jitter
	elif active_count >= 40: base_cycle = 1.0 + jitter
	elif active_count >= 32: base_cycle = 0.82 + jitter
	elif active_count >= 24: base_cycle = 0.58 + jitter
	if _has_stable_visible_ai_target(ai):
		return max(0.25, base_cycle * 0.72)
	if !_has_valid_ai_target(ai):
		return base_cycle * 1.25
	return base_cycle


func _current_target_visibility_cycle(ai: Node) -> float:
	var active_count := _active_ai_count(ai)
	var jitter: float = float(ai.get_meta("targetVisibilityJitter", 0.0))
	var base_cycle: float = 0.08 + jitter
	if active_count >= 64:   base_cycle = 0.42 + jitter
	elif active_count >= 60: base_cycle = 0.38 + jitter
	elif active_count >= 56: base_cycle = 0.35 + jitter
	elif active_count >= 52: base_cycle = 0.32 + jitter
	elif active_count >= 48: base_cycle = 0.29 + jitter
	elif active_count >= 45: base_cycle = 0.265 + jitter
	elif active_count >= 40: base_cycle = 0.24 + jitter
	elif active_count >= 32: base_cycle = 0.18 + jitter
	elif active_count >= 24: base_cycle = 0.12 + jitter
	if _has_valid_ai_target(ai):
		var dist: float = float(ai.get_meta("currentAITargetDistance", 9999.0))
		if dist > 90.0:
			return base_cycle * 1.6
		if dist > 50.0:
			return base_cycle * 1.35
		if dist < 20.0:
			return max(0.05, base_cycle * 0.8)
	return base_cycle


func _current_ai_audio_cycle(ai: Node) -> float:
	var active_count := _active_ai_count(ai)
	var jitter: float = float(ai.get_meta("aiAudioSenseJitter", 0.0))
	if active_count >= 64: return 1.35 + jitter
	if active_count >= 60: return 1.25 + jitter
	if active_count >= 56: return 1.15 + jitter
	if active_count >= 52: return 1.05 + jitter
	if active_count >= 48: return 0.95 + jitter
	if active_count >= 45: return 0.9 + jitter
	if active_count >= 40: return 0.85 + jitter
	if active_count >= 32: return 0.65 + jitter
	if active_count >= 24: return 0.45 + jitter
	return 0.25 + jitter


# --- Sensor sub-helpers ----------------------------------------------------

func _sense_player_los(ai: Node) -> bool:
	if !_can_target_player(ai):
		ai.playerVisible = false
		return false
	if ai.playerDistance3D <= 200.0:
		var directionToPlayer: Vector3 = (ai.eyes.global_position - _gameData.cameraPosition).normalized()
		var viewDirection: Vector3 = -ai.eyes.global_transform.basis.z.normalized()
		var viewRadius: float = viewDirection.dot(directionToPlayer)
		if viewRadius > 0.5:
			ai.LOSCheck(_gameData.cameraPosition)
			return ai.playerVisible
	ai.playerVisible = false
	return false


# --- Hostile AI targeting --------------------------------------------------

func _update_hostile_ai_targeting(ai: Node, delta: float) -> void:
	if !_custom_ai_targeting_active(ai):
		_clear_ai_target(ai, false)
		return

	var current_refresh_cycle := _current_target_refresh_cycle(ai)
	var refresh_timer: float = float(ai.get_meta("targetRefreshTimer", 0.0))
	if refresh_timer > current_refresh_cycle:
		refresh_timer = current_refresh_cycle

	var current_visibility_cycle := _current_target_visibility_cycle(ai)
	var visibility_timer: float = float(ai.get_meta("targetVisibilityTimer", 0.0))
	if visibility_timer > current_visibility_cycle:
		visibility_timer = current_visibility_cycle

	refresh_timer -= delta
	visibility_timer -= delta

	if !_has_valid_ai_target(ai) or refresh_timer <= 0.0:
		var previousTarget = ai.get_meta("currentAITarget", null)
		var newTarget: Node3D = _acquire_hostile_ai_target(ai)
		ai.set_meta("currentAITarget", newTarget)
		refresh_timer = current_refresh_cycle
		visibility_timer = 0.0
		if newTarget != previousTarget:
			if is_instance_valid(newTarget):
				_update_target_visibility(ai)
				visibility_timer = current_visibility_cycle

	if !_has_valid_ai_target(ai):
		_update_target_visibility(ai)
	else:
		var target: Node3D = ai.get_meta("currentAITarget")
		ai.set_meta("currentAITargetDistance", ai.global_position.distance_to(target.global_position))
		_set_target_label(ai)
		if visibility_timer <= 0.0:
			_update_target_visibility(ai)
			visibility_timer = current_visibility_cycle

	ai.set_meta("targetRefreshTimer", refresh_timer)
	ai.set_meta("targetVisibilityTimer", visibility_timer)


func _sense_ai_audio(ai: Node) -> void:
	var audible_target: Node3D = _find_audible_hostile_target(ai)
	if !is_instance_valid(audible_target):
		return
	ai.set_meta("currentAITarget", audible_target)
	ai.set_meta("currentAITargetDistance", ai.global_position.distance_to(audible_target.global_position))
	ai.set_meta("currentAITargetVisible", false)
	ai.lastKnownLocation = _get_ai_target_position(ai, audible_target)
	var reason := _get_audible_target_reason(audible_target)
	if reason == "":
		reason = "AI sound"
	var dist: float = float(ai.get_meta("currentAITargetDistance", 0.0))
	ai.set_meta("targetLabel", "%s %.1fm" % [_self_or_target_faction_name(audible_target), dist])
	if ai.currentState == ai.State.Wander or ai.currentState == ai.State.Guard or ai.currentState == ai.State.Patrol:
		ai.Decision()
	elif ai.currentState == ai.State.Ambush or ai.currentState == ai.State.Return:
		ai.ChangeState("Combat")
	ai.set_meta("lastAISoundTarget", audible_target)
	ai.set_meta("lastAISoundReason", reason)


func _find_audible_hostile_target(ai: Node) -> Node3D:
	if !is_instance_valid(ai.AISpawner) or !is_instance_valid(ai.AISpawner.agents):
		return null
	var nearest_target: Node3D = null
	var nearest_distance: float = 9999.0
	for child in ai.AISpawner.agents.get_children():
		if !_is_valid_hostile_ai_target(ai, child):
			continue
		var distance_to_target: float = ai.global_position.distance_to(child.global_position)
		if !_target_is_audible(child, distance_to_target):
			continue
		if distance_to_target < nearest_distance:
			nearest_distance = distance_to_target
			nearest_target = child
	return nearest_target


func _target_is_audible(target_node: Node3D, distance_to_target: float) -> bool:
	var hearing_multiplier: float = max(0.1, EnemyAISettings.ai_hearing_multiplier)
	var movement_speed: float = float(target_node.get("movementSpeed"))
	var running_distance: float = AI_HEARING_RUN_DISTANCE * hearing_multiplier
	var walking_distance: float = AI_HEARING_WALK_DISTANCE * hearing_multiplier
	var gunshot_distance: float = AI_HEARING_GUNSHOT_DISTANCE * hearing_multiplier
	if _target_fired_recently(target_node) and distance_to_target <= gunshot_distance:
		return true
	if movement_speed >= 2.0 and distance_to_target <= running_distance:
		return true
	if movement_speed > 0.15 and distance_to_target <= walking_distance:
		return true
	return false


func _get_audible_target_reason(target_node: Node3D) -> String:
	if _target_fired_recently(target_node):
		return "Gunshot"
	var movement_speed: float = float(target_node.get("movementSpeed"))
	if movement_speed >= 2.0:
		return "Running"
	if movement_speed > 0.15:
		return "Walking"
	return ""


func _target_fired_recently(target_node: Node3D) -> bool:
	if !is_instance_valid(target_node):
		return false
	if !target_node.has_meta("enemy_ai_last_shot_time"):
		return false
	var shot_time: float = float(target_node.get_meta("enemy_ai_last_shot_time"))
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	return now - shot_time <= AI_GUNSHOT_MEMORY_TIME


func _mark_ai_gunshot(ai: Node) -> void:
	ai.set_meta("enemy_ai_last_shot_time", float(Time.get_ticks_msec()) / 1000.0)


func _acquire_hostile_ai_target(ai: Node) -> Node3D:
	if !is_instance_valid(ai.AISpawner) or !is_instance_valid(ai.AISpawner.agents):
		return null
	var nearestTarget: Node3D = null
	var nearestDistance: float = 9999.0
	for child in ai.AISpawner.agents.get_children():
		if !_is_valid_hostile_ai_target(ai, child):
			continue
		var distanceToTarget: float = ai.global_position.distance_to(child.global_position)
		if distanceToTarget < nearestDistance and distanceToTarget <= 120.0:
			nearestDistance = distanceToTarget
			nearestTarget = child
	return _choose_hostile_target_with_hysteresis(ai, nearestTarget, nearestDistance)


func _choose_hostile_target_with_hysteresis(ai: Node, best_candidate: Node3D, best_distance: float) -> Node3D:
	if !_has_valid_ai_target(ai):
		return best_candidate
	if !is_instance_valid(best_candidate):
		return ai.get_meta("currentAITarget", null)
	var current: Node3D = ai.get_meta("currentAITarget", null)
	if best_candidate == current:
		return current
	var current_distance: float = ai.global_position.distance_to(current.global_position)
	if bool(ai.get_meta("currentAITargetVisible", false)):
		if best_distance < current_distance * 0.75:
			return best_candidate
		return current
	if best_distance < current_distance * 0.9:
		return best_candidate
	return current


func _is_valid_hostile_ai_target(ai: Node, node) -> bool:
	if !is_instance_valid(node):
		return false
	if node == ai:
		return false
	if !node.has_method("WeaponDamage"):
		return false
	if bool(node.get("dead")):
		return false
	if bool(node.get("pause")):
		return false
	if !node.has_meta("enemy_ai_faction"):
		return false
	return _is_hostile_faction(_self_faction(ai), str(node.get_meta("enemy_ai_faction")))


func _update_target_visibility(ai: Node) -> void:
	if _has_valid_ai_target(ai):
		var target: Node3D = ai.get_meta("currentAITarget")
		ai.set_meta("currentAITargetDistance", ai.global_position.distance_to(target.global_position))
		var visible := _can_see_ai_target(ai, target)
		ai.set_meta("currentAITargetVisible", visible)
		_set_target_label(ai)
		ai.set_meta("previousAITargetVisible", visible)
		if visible:
			ai.lastKnownLocation = _get_ai_target_position(ai)
	else:
		ai.set_meta("currentAITargetVisible", false)
		ai.set_meta("currentAITargetDistance", 9999.0)
		if _player_priority_active(ai):
			ai.set_meta("targetLabel", "Player %.1fm" % ai.playerDistance3D)
		else:
			ai.set_meta("targetLabel", "None")
		ai.set_meta("previousAITargetVisible", false)


func _can_see_ai_target(ai: Node, target_node: Node3D) -> bool:
	if !is_instance_valid(target_node):
		return false
	var target_position: Vector3 = _get_ai_target_position(ai, target_node)
	var sight_multiplier: float = max(0.1, EnemyAISettings.ai_sight_multiplier)
	if _gameData.TOD == 4 and !_gameData.flashlight and !ai.boss:
		ai.LOS.target_position = Vector3(0, 0, (25 + ai.extraVisibility) * sight_multiplier)
	elif _gameData.fog and !ai.boss:
		ai.LOS.target_position = Vector3(0, 0, (100 + ai.extraVisibility) * sight_multiplier)
	else:
		ai.LOS.target_position = Vector3(0, 0, 200 * sight_multiplier)
	ai.LOS.look_at(target_position, Vector3.UP, true)
	ai.LOS.force_raycast_update()
	if !ai.LOS.is_colliding():
		return false
	var collider = ai.LOS.get_collider()
	if collider == target_node:
		return true
	if collider is Hitbox and collider.owner == target_node:
		return true
	return false


func _has_valid_ai_target(ai: Node) -> bool:
	return _is_valid_hostile_ai_target(ai, ai.get_meta("currentAITarget", null))


func _has_stable_visible_ai_target(ai: Node) -> bool:
	return _has_valid_ai_target(ai) and bool(ai.get_meta("currentAITargetVisible", false))


# --- Engagement position/distance/visibility -------------------------------

func _get_ai_target_position(ai: Node, target_node: Node3D = null) -> Vector3:
	if target_node == null:
		target_node = ai.get_meta("currentAITarget", null)
	if !is_instance_valid(target_node):
		return ai.playerPosition
	var torsoPosition := _get_ai_torso_position(target_node)
	if torsoPosition != Vector3.ZERO:
		return torsoPosition
	var targetHead = target_node.get("head")
	if targetHead is Node3D:
		return targetHead.global_position + Vector3(0, -0.35, 0)
	var targetEyes = target_node.get("eyes")
	if targetEyes is Node3D:
		return targetEyes.global_position + Vector3(0, -0.6, 0)
	return target_node.global_position + Vector3(0, 0.8, 0)


func _get_fire_target_position(ai: Node) -> Vector3:
	if _player_priority_active(ai):
		return ai.playerPosition + Vector3(0, 1.0, 0)
	if _has_valid_ai_target(ai):
		var target: Node3D = ai.get_meta("currentAITarget")
		var torsoPosition := _get_ai_torso_position(target)
		if torsoPosition != Vector3.ZERO:
			return torsoPosition
	return ai.playerPosition + Vector3(0, 1.0, 0)


func _get_spine_target_position(ai: Node) -> Vector3:
	if _player_priority_active(ai):
		return ai.playerPosition
	if _has_valid_ai_target(ai):
		var target: Node3D = ai.get_meta("currentAITarget")
		var spineTorso := _get_ai_spine_torso_position(target)
		if spineTorso != Vector3.ZERO:
			return spineTorso
		return target.global_position + Vector3(0, 1.0, 0)
	return ai.LKL


func _get_ai_torso_position(target_node: Node3D) -> Vector3:
	if !is_instance_valid(target_node):
		return Vector3.ZERO
	var targetChest = target_node.get("chest")
	if targetChest is Node3D:
		return targetChest.global_position + Vector3(0, -0.25, 0)
	return Vector3.ZERO


func _get_ai_spine_torso_position(target_node: Node3D) -> Vector3:
	if !is_instance_valid(target_node):
		return Vector3.ZERO
	var targetChest = target_node.get("chest")
	if targetChest is Node3D:
		return targetChest.global_position
	var targetHead = target_node.get("head")
	if targetHead is Node3D:
		return targetHead.global_position + Vector3(0, -0.6, 0)
	return target_node.global_position + Vector3(0, 1.0, 0)


func _is_ai_root_hit(ai: Node, hitCollider) -> bool:
	if !is_instance_valid(hitCollider):
		return false
	if hitCollider == ai:
		return false
	if !hitCollider.has_method("WeaponDamage"):
		return false
	if !hitCollider.has_meta("enemy_ai_faction"):
		return false
	return _is_valid_hostile_ai_target(ai, hitCollider)


func _get_engagement_position(ai: Node) -> Vector3:
	if _player_priority_active(ai):
		return ai.playerPosition
	if _has_valid_ai_target(ai):
		return _get_ai_target_position(ai)
	return ai.playerPosition


func _get_engagement_distance(ai: Node) -> float:
	if _player_priority_active(ai):
		return ai.playerDistance3D
	if _has_valid_ai_target(ai):
		return float(ai.get_meta("currentAITargetDistance", ai.playerDistance3D))
	return ai.playerDistance3D


func _engagement_visible(ai: Node) -> bool:
	if _player_priority_active(ai):
		return ai.playerVisible
	if _has_valid_ai_target(ai):
		return bool(ai.get_meta("currentAITargetVisible", false))
	return ai.playerVisible


func _can_direct_attack_target(ai: Node) -> bool:
	if _player_priority_active(ai):
		return true
	if _has_valid_ai_target(ai):
		return true
	return !_gameData.isTrading


func _player_only_combat_blocked(ai: Node) -> bool:
	if _player_priority_active(ai):
		return false
	if _has_valid_ai_target(ai):
		return false
	return _gameData.isTrading


func _should_play_player_bullet_audio(ai: Node) -> bool:
	return _player_priority_active(ai) and _can_target_player(ai)


func _clear_ai_target(ai: Node, _push_status: bool = true) -> void:
	ai.set_meta("currentAITarget", null)
	ai.set_meta("currentAITargetVisible", false)
	ai.set_meta("currentAITargetDistance", 9999.0)
	ai.set_meta("targetLabel", "None")
	ai.set_meta("previousAITargetVisible", false)


func _set_target_label(ai: Node) -> void:
	if _player_priority_active(ai):
		ai.set_meta("targetLabel", "Player %.1fm" % ai.playerDistance3D)
		return
	if !_has_valid_ai_target(ai):
		ai.set_meta("targetLabel", "None")
		return
	var target: Node3D = ai.get_meta("currentAITarget")
	var dist: float = float(ai.get_meta("currentAITargetDistance", 0.0))
	ai.set_meta("targetLabel", "%s %.1fm" % [_self_or_target_faction_name(target), dist])


func _self_or_target_faction_name(target_node: Node3D) -> String:
	if is_instance_valid(target_node) and target_node.has_meta("enemy_ai_faction"):
		return str(target_node.get_meta("enemy_ai_faction"))
	return "Unknown"


# --- Damage application (Raycast helpers) ----------------------------------

func _shot_damage(ai: Node) -> float:
	var damage: float = ai.weaponData.damage
	if ai.boss:
		damage *= 2.0
	return damage


func _apply_damage_to_hitbox(ai: Node, hitbox: Hitbox, damage: float) -> void:
	hitbox.ApplyDamage(damage)
	if main and main.has_method("record_hit"):
		main.record_hit(str(hitbox.type), false)


func _try_apply_targeted_hitbox_damage(ai: Node, hitCollider) -> bool:
	var space_state: PhysicsDirectSpaceState3D = ai.get_world_3d().direct_space_state
	var shot_origin: Vector3 = ai.muzzle.global_position
	var preferred_targets: Array = _get_preferred_hit_targets(ai, hitCollider)
	var fallbackHitbox: Hitbox = null
	for preferred_target in preferred_targets:
		var query := PhysicsRayQueryParameters3D.create(shot_origin, preferred_target)
		query.exclude = [ai, hitCollider]
		var result: Dictionary = space_state.intersect_ray(query)
		if result.is_empty():
			continue
		var secondaryCollider = result["collider"]
		if secondaryCollider is Hitbox:
			if str(secondaryCollider.type) == "Torso":
				_apply_damage_to_hitbox(ai, secondaryCollider, _shot_damage(ai))
				return true
			if fallbackHitbox == null:
				fallbackHitbox = secondaryCollider
	if fallbackHitbox != null:
		_apply_damage_to_hitbox(ai, fallbackHitbox, _shot_damage(ai))
		return true
	return false


func _get_preferred_hit_targets(ai: Node, hitCollider) -> Array:
	var targets: Array = []
	var current: Node3D = ai.get_meta("currentAITarget", null)
	if is_instance_valid(hitCollider) and hitCollider == current:
		var directTorso := _get_ai_torso_position(hitCollider)
		if directTorso != Vector3.ZERO:
			targets.append(directTorso)
		else:
			targets.append(_get_ai_target_position(ai, hitCollider))
	if is_instance_valid(current):
		var torso := _get_ai_torso_position(current)
		if torso != Vector3.ZERO:
			targets.append(torso)
		var head = current.get("head")
		if head is Node3D:
			targets.append(head.global_position + Vector3(0, -0.4, 0))
		var eyesNode = current.get("eyes")
		if eyesNode is Node3D:
			targets.append(eyesNode.global_position + Vector3(0, -0.8, 0))
	targets.append(_get_fire_target_position(ai))
	return targets


# --- Misc helpers ----------------------------------------------------------

func _tactics_cycle_scale() -> float:
	match EnemyAISettings.ai_tactics_preset:
		0: return 1.5
		2: return 0.75
		3: return 0.5
		_: return 1.0
