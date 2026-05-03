extends Node

# Hook bodies for vanilla Character.gd. Implements the player-invulnerability
# cheat from the original Character.gd override. Two patterns in use:
#
#   * Force-state: post-hook writes constants regardless of what vanilla did
#     (Health, Oxygen, BurnDamage, _physics_process maintenance).
#
#   * Stash-and-restore: pre-hook snapshots player state before vanilla runs,
#     post-hook restores it so vanilla's mutations are undone (WeaponDamage,
#     ExplosionDamage, FallDamage, Death). Sentinel-based: _stash_health<0
#     means no snapshot is active, so the post-hook knows to no-op when the
#     pre-hook didn't fire (predicate was false).

const EnemyAISettings := preload("res://RoadToVostokEnemyAI/EnemyAISettings.tres")

var _lib = null
var _gameData: Resource = preload("res://Resources/GameData.tres")

# Stash slots. All on the autoload because gameData is a singleton (one player).
var _stash_health: float = -1.0
var _stash_oxygen: float = -1.0
var _stash_damage: bool = false
var _stash_impact: bool = false
var _stash_isDead: bool = false
var _stash_isBurning: bool = false
var _stash_burn: bool = false


func register_hooks(lib) -> void:
	_lib = lib
	_lib.hook_many({
		"character-_physics_process-post":  _on_phys_post,
		"character-health-post":            _on_health_post,
		"character-oxygen-post":            _on_oxygen_post,
		"character-burndamage-post":        _on_burn_post,
		"character-weapondamage-pre":       _on_weapon_pre,
		"character-weapondamage-post":      _on_weapon_post,
		"character-explosiondamage-pre":    _on_explosion_pre,
		"character-explosiondamage-post":   _on_explosion_post,
		"character-falldamage-pre":         _on_fall_pre,
		"character-falldamage-post":        _on_fall_post,
		"character-death-pre":              _on_death_pre,
		"character-death-post":             _on_death_post,
	})
	print("Faction Warfare: Character hooks registered")


func _player_invulnerable() -> bool:
	return EnemyAISettings.player_invulnerable


# --- Force-state callbacks ---------------------------------------------------

func _on_phys_post(_delta: float) -> void:
	if _player_invulnerable():
		_maintain_invulnerable_stats()


func _on_health_post(_delta: float) -> void:
	if _player_invulnerable():
		_gameData.health = 100.0
		_gameData.damage = false


func _on_oxygen_post(_delta: float) -> void:
	if _player_invulnerable():
		_gameData.oxygen = 100.0


func _on_burn_post(_delta: float) -> void:
	if _player_invulnerable():
		_gameData.isBurning = false
		_gameData.burn = false
		_gameData.damage = false


# --- Stash-and-restore callbacks --------------------------------------------

func _on_weapon_pre(_damage: int, _penetration: int) -> void:
	if _player_invulnerable():
		_stash_player_combat_state()


func _on_weapon_post(_damage: int, _penetration: int) -> void:
	if _has_combat_stash():
		_restore_player_combat_state()


func _on_explosion_pre() -> void:
	if _player_invulnerable():
		_stash_player_combat_state()


func _on_explosion_post() -> void:
	if _has_combat_stash():
		_restore_player_combat_state()


func _on_fall_pre(_distance: float) -> void:
	if _player_invulnerable():
		_stash_player_combat_state()


func _on_fall_post(_distance: float) -> void:
	if _has_combat_stash():
		_restore_player_combat_state()


func _on_death_pre() -> void:
	if _player_invulnerable():
		_stash_player_combat_state()


func _on_death_post() -> void:
	if _has_combat_stash():
		_restore_player_combat_state()
		_maintain_invulnerable_stats()


# --- Stash helpers ----------------------------------------------------------

func _stash_player_combat_state() -> void:
	_stash_health = _gameData.health
	_stash_oxygen = _gameData.oxygen
	_stash_damage = _gameData.damage
	_stash_impact = _gameData.impact
	_stash_isDead = _gameData.isDead
	_stash_isBurning = _gameData.isBurning
	_stash_burn = _gameData.burn


func _has_combat_stash() -> bool:
	return _stash_health >= 0.0


func _restore_player_combat_state() -> void:
	_gameData.health = _stash_health
	_gameData.oxygen = _stash_oxygen
	_gameData.damage = _stash_damage
	_gameData.impact = _stash_impact
	_gameData.isDead = _stash_isDead
	_gameData.isBurning = _stash_isBurning
	_gameData.burn = _stash_burn
	_stash_health = -1.0


func _maintain_invulnerable_stats() -> void:
	_gameData.health = 100.0
	_gameData.oxygen = 100.0
	_gameData.damage = false
	_gameData.impact = false
	_gameData.isDead = false
