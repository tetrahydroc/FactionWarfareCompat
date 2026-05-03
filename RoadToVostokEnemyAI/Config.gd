extends Node

var enemyAISettings = preload("res://RoadToVostokEnemyAI/EnemyAISettings.tres")
var McmHelpers = load("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres")

const FILE_PATH = "user://MCM/RoadToVostokEnemyAI"
const MOD_ID = "RoadToVostokEnemyAI"
const MOD_VERSION = "0.1.18"

func _ready() -> void:
    var config = ConfigFile.new()

    config.set_value("Meta", "mod_version", MOD_VERSION)

    config.set_value("Dropdown", "intensity_preset", {
        "name" = "Enemy Density Preset",
        "tooltip" = "Main enemy count preset. Higher options allow more enemies, larger reserve pools, faster reinforcements, and more enemies already active when the map starts.",
        "default" = 3,
        "value" = 3,
        "menu_pos" = 1,
        "options" = [
            "Default",
            "Medium",
            "Medium High",
            "High",
            "Very High",
            "Insane"
        ]
    })

    config.set_value("Dropdown", "spawn_rate_adjustment", {
        "name" = "Reinforcement Speed",
        "tooltip" = "Controls how quickly new enemies arrive after the initial wave. Lower slows reinforcements down, while Higher fills the map faster.",
        "default" = 1,
        "value" = 1,
        "menu_pos" = 9,
        "options" = [
            "Lower",
            "Vanilla",
            "Higher"
        ]
    })

    config.set_value("Int", "spawn_limit_bonus", {
        "name" = "Extra Enemies Alive",
        "tooltip" = "Adds more live enemies on top of the chosen density preset.",
        "default" = 0,
        "value" = 0,
        "menu_pos" = 11,
        "minRange" = 0,
        "maxRange" = 20
    })

    config.set_value("Int", "spawn_pool_bonus", {
        "name" = "Extra Reserve Enemies",
        "tooltip" = "Adds more backup enemies to the spawner's reserve pool so it can keep sending in reinforcements for longer.",
        "default" = 0,
        "value" = 0,
        "menu_pos" = 11,
        "minRange" = 0,
        "maxRange" = 60
    })

    config.set_value("Int", "initial_population_bonus", {
        "name" = "Extra Enemies At Start",
        "tooltip" = "Adds more enemies to the opening population when the map begins.",
        "default" = 0,
        "value" = 0,
        "menu_pos" = 12,
        "minRange" = 0,
        "maxRange" = 20
    })

    config.set_value("Int", "spawn_distance", {
        "name" = "Minimum Spawn Distance",
        "tooltip" = "How far away enemies must be from you before they are allowed to spawn. Higher values reduce close pop-in spawns.",
        "default" = 100,
        "value" = 100,
        "menu_pos" = 13,
        "minRange" = 30,
        "maxRange" = 200
    })

    config.set_value("Bool", "initial_guard", {
        "name" = "Spawn Opening Sentry",
        "tooltip" = "Lets the map start with one guard-style enemy already set up as a sentry.",
        "default" = false,
        "value" = false
        ,
        "menu_pos" = 11
    })

    config.set_value("Bool", "initial_hider", {
        "name" = "Spawn Opening Ambusher",
        "tooltip" = "Lets the map start with a chance for one ambush-style enemy already hiding nearby.",
        "default" = false,
        "value" = false
        ,
        "menu_pos" = 12
    })

    config.set_value("Int", "initial_hider_chance", {
        "name" = "Opening Ambusher Chance",
        "tooltip" = "Chance that the opening ambusher actually appears when opening ambushers are enabled.",
        "default" = 25,
        "value" = 25,
        "menu_pos" = 17,
        "minRange" = 0,
        "maxRange" = 100
    })

    config.set_value("Bool", "disable_hiding", {
        "name" = "Disable Hide Behavior",
        "tooltip" = "Stops enemies from choosing hide behavior during their tactics.",
        "default" = false,
        "value" = false
        ,
        "menu_pos" = 18
    })

    config.set_value("Dropdown", "bandit_spawn_mode", {
        "name" = "Allow Bandits",
        "tooltip" = "Map Default keeps the map's normal faction setup. On forces bandits into the spawn mix, and Off removes them even if the map would normally use them.",
        "default" = 1,
        "value" = 1,
        "menu_pos" = 3,
        "options" = [
            "Map Default",
            "On",
            "Off"
        ]
    })

    config.set_value("Dropdown", "guard_spawn_mode", {
        "name" = "Allow Guards",
        "tooltip" = "Map Default keeps the map's normal faction setup. On forces guards into the spawn mix, and Off removes them even if the map would normally use them.",
        "default" = 1,
        "value" = 1,
        "menu_pos" = 4,
        "options" = [
            "Map Default",
            "On",
            "Off"
        ]
    })

    config.set_value("Dropdown", "military_spawn_mode", {
        "name" = "Allow Military",
        "tooltip" = "Map Default keeps the map's normal faction setup. On forces military into the spawn mix, and Off removes them even if the map would normally use them.",
        "default" = 1,
        "value" = 1,
        "menu_pos" = 5,
        "options" = [
            "Map Default",
            "On",
            "Off"
        ]
    })

    config.set_value("Bool", "bandit_infighting_enabled", {
        "name" = "Enable Bandit Infighting",
        "tooltip" = "Allows bandits to treat other bandits as enemies and fight each other.",
        "default" = true,
        "value" = true
        ,
        "menu_pos" = 7
    })

    config.set_value("Bool", "guard_infighting_enabled", {
        "name" = "Enable Guard Infighting",
        "tooltip" = "Allows guards to treat other guards as enemies and fight each other.",
        "default" = false,
        "value" = false
        ,
        "menu_pos" = 8
    })

    config.set_value("Bool", "military_infighting_enabled", {
        "name" = "Enable Military Infighting",
        "tooltip" = "Allows military units to treat other military units as enemies and fight each other.",
        "default" = false,
        "value" = false
        ,
        "menu_pos" = 9
    })

    config.set_value("Bool", "warfare_enabled", {
        "name" = "Enable Faction Warfare",
        "tooltip" = "Allows Bandits, Guards, and Military to fight hostile factions instead of only focusing on the player.",
        "default" = true,
        "value" = true
        ,
        "menu_pos" = 10
    })

    config.set_value("Dropdown", "player_faction_alignment", {
        "name" = "Player Allegiance",
        "tooltip" = "Neutral means every faction can attack you. Choosing a faction makes that faction treat you as friendly in real time.",
        "default" = 0,
        "value" = 0,
        "menu_pos" = 6,
        "options" = [
            "Neutral",
            "Bandit",
            "Guard",
            "Military"
        ]
    })

    config.set_value("Int", "corpse_cleanup_limit", {
        "name" = "Maximum Bodies Kept",
        "tooltip" = "How many dead bodies can stay in the world before the oldest ragdoll and its dropped weapon are cleaned up. Set to 0 to disable cleanup.",
        "default" = 32,
        "value" = 32,
        "menu_pos" = 2,
        "minRange" = 0,
        "maxRange" = 120
    })

    config.set_value("Bool", "player_invulnerable", {
        "name" = "God Mode",
        "tooltip" = "Prevents the player from taking damage so you can safely watch firefights and test AI behavior.",
        "default" = false,
        "value" = false
        ,
        "menu_pos" = 21
    })

    config.set_value("Bool", "show_debug_overlay", {
        "name" = "Show AI Debug Overlay",
        "tooltip" = "Shows a top-left debug panel with map, faction, spawn, and AI activity information.",
        "default" = false,
        "value" = false
        ,
        "menu_pos" = 22
    })

    config.set_value("Bool", "replenish_spawn_pool", {
        "name" = "Replenish Spawn Pool",
        "tooltip" = "Keeps long sessions spawning by adding a fresh reserve enemy back into the pool when one dies.",
        "default" = true,
        "value" = true
        ,
        "menu_pos" = 23
    })

    config.set_value("Float", "ai_health_multiplier", {
        "name" = "Enemy Health Multiplier",
        "tooltip" = "Advanced. Multiplies normal enemy health without changing the density presets.",
        "default" = 1.0,
        "value" = 1.0,
        "menu_pos" = 31,
        "minRange" = 0.25,
        "maxRange" = 5.0
    })

    config.set_value("Float", "boss_health_multiplier", {
        "name" = "Boss Health Multiplier",
        "tooltip" = "Advanced. Multiplies boss health for boss-type enemies.",
        "default" = 1.0,
        "value" = 1.0,
        "menu_pos" = 32,
        "minRange" = 0.25,
        "maxRange" = 5.0
    })

    config.set_value("Float", "ai_sight_multiplier", {
        "name" = "Enemy Vision Multiplier",
        "tooltip" = "Advanced. Changes how far enemies can reliably see.",
        "default" = 1.0,
        "value" = 1.0,
        "menu_pos" = 33,
        "minRange" = 0.25,
        "maxRange" = 2.0
    })

    config.set_value("Float", "ai_hearing_multiplier", {
        "name" = "Enemy Hearing Multiplier",
        "tooltip" = "Advanced. Changes how far enemies can hear movement and nearby combat sounds.",
        "default" = 1.0,
        "value" = 1.0,
        "menu_pos" = 34,
        "minRange" = 0.25,
        "maxRange" = 3.0
    })

    config.set_value("Float", "ai_accuracy_multiplier", {
        "name" = "Enemy Accuracy Multiplier",
        "tooltip" = "Advanced. Higher values make enemies shoot more accurately.",
        "default" = 1.0,
        "value" = 1.0,
        "menu_pos" = 35,
        "minRange" = 0.25,
        "maxRange" = 3.0
    })

    config.set_value("Float", "ai_fire_rate_multiplier", {
        "name" = "Enemy Fire Rate Multiplier",
        "tooltip" = "Advanced. Higher values make enemies fire more often.",
        "default" = 1.0,
        "value" = 1.0,
        "menu_pos" = 36,
        "minRange" = 0.25,
        "maxRange" = 3.0
    })

    config.set_value("Float", "ai_gunshot_alert_duration", {
        "name" = "Gunshot Alert Time",
        "tooltip" = "Advanced. Controls how long enemies stay extra alert after hearing gunfire.",
        "default" = 5.0,
        "value" = 5.0,
        "menu_pos" = 37,
        "minRange" = 1.0,
        "maxRange" = 20.0
    })

    config.set_value("Dropdown", "ai_tactics_preset", {
        "name" = "Enemy Aggression",
        "tooltip" = "Advanced. Controls how aggressively enemies cycle through combat behaviors.",
        "default" = 1,
        "value" = 1,
        "menu_pos" = 10,
        "options" = [
            "Passive",
            "Default",
            "Aggressive",
            "Relentless"
        ]
    })

    if !FileAccess.file_exists(FILE_PATH + "/config.ini"):
        DirAccess.open("user://").make_dir_recursive(FILE_PATH)
        config.save(FILE_PATH + "/config.ini")
    else:
        if McmHelpers != null:
            McmHelpers.CheckConfigurationHasUpdated(MOD_ID, config, FILE_PATH + "/config.ini")
        config.load(FILE_PATH + "/config.ini")
        var config_changed = false
        config_changed = _sync_config_metadata(config) or config_changed
        config_changed = _sync_saved_mod_version(config) or config_changed
        if config_changed:
            config.save(FILE_PATH + "/config.ini")

    _on_config_updated(config)

    if McmHelpers != null:
        McmHelpers.RegisterConfiguration(
            MOD_ID,
            "Faction Warfare + More Enemies",
            FILE_PATH,
            "Preset-first enemy density mod with visible advanced controls.",
            {
                "config.ini" = _on_config_updated
            }
        )

func _on_config_updated(config: ConfigFile):
    enemyAISettings.intensity_preset = config.get_value("Dropdown", "intensity_preset")["value"]
    enemyAISettings.spawn_rate_adjustment = config.get_value("Dropdown", "spawn_rate_adjustment")["value"]
    enemyAISettings.spawn_limit_bonus = config.get_value("Int", "spawn_limit_bonus")["value"]
    enemyAISettings.spawn_pool_bonus = config.get_value("Int", "spawn_pool_bonus")["value"]
    enemyAISettings.initial_population_bonus = config.get_value("Int", "initial_population_bonus")["value"]
    enemyAISettings.spawn_distance = config.get_value("Int", "spawn_distance")["value"]
    enemyAISettings.initial_guard = config.get_value("Bool", "initial_guard")["value"]
    enemyAISettings.initial_hider = config.get_value("Bool", "initial_hider")["value"]
    enemyAISettings.initial_hider_chance = config.get_value("Int", "initial_hider_chance")["value"]
    enemyAISettings.disable_hiding = config.get_value("Bool", "disable_hiding")["value"]
    enemyAISettings.enemy_type_override_enabled = false
    enemyAISettings.bandit_spawn_mode = config.get_value("Dropdown", "bandit_spawn_mode")["value"]
    enemyAISettings.guard_spawn_mode = config.get_value("Dropdown", "guard_spawn_mode")["value"]
    enemyAISettings.military_spawn_mode = config.get_value("Dropdown", "military_spawn_mode")["value"]
    enemyAISettings.warfare_enabled = config.get_value("Bool", "warfare_enabled")["value"]
    enemyAISettings.bandit_infighting_enabled = config.get_value("Bool", "bandit_infighting_enabled", {"value": false})["value"]
    enemyAISettings.guard_infighting_enabled = config.get_value("Bool", "guard_infighting_enabled", {"value": false})["value"]
    enemyAISettings.military_infighting_enabled = config.get_value("Bool", "military_infighting_enabled", {"value": false})["value"]
    enemyAISettings.player_faction_alignment = config.get_value("Dropdown", "player_faction_alignment", {"value": 0})["value"]
    enemyAISettings.corpse_cleanup_limit = config.get_value("Int", "corpse_cleanup_limit", {"value": 20})["value"]
    enemyAISettings.player_invulnerable = config.get_value("Bool", "player_invulnerable", {"value": false})["value"]
    enemyAISettings.show_debug_overlay = config.get_value("Bool", "show_debug_overlay")["value"]
    enemyAISettings.replenish_spawn_pool = config.get_value("Bool", "replenish_spawn_pool", {"value": true})["value"]
    enemyAISettings.ai_health_multiplier = config.get_value("Float", "ai_health_multiplier")["value"]
    enemyAISettings.boss_health_multiplier = config.get_value("Float", "boss_health_multiplier")["value"]
    enemyAISettings.ai_sight_multiplier = config.get_value("Float", "ai_sight_multiplier")["value"]
    enemyAISettings.ai_hearing_multiplier = config.get_value("Float", "ai_hearing_multiplier")["value"]
    enemyAISettings.ai_accuracy_multiplier = config.get_value("Float", "ai_accuracy_multiplier")["value"]
    enemyAISettings.ai_fire_rate_multiplier = config.get_value("Float", "ai_fire_rate_multiplier")["value"]
    enemyAISettings.ai_gunshot_alert_duration = config.get_value("Float", "ai_gunshot_alert_duration")["value"]
    enemyAISettings.ai_tactics_preset = config.get_value("Dropdown", "ai_tactics_preset")["value"]
    enemyAISettings.mcm_enabled = true

func _sync_config_metadata(config: ConfigFile) -> bool:
    var changed = false

    changed = _migrate_intensity_preset_options(config) or changed

    changed = _sync_dropdown_options(config, "intensity_preset", [
        "Default",
        "Medium",
        "Medium High",
        "High",
        "Very High",
        "Insane"
    ]) or changed

    changed = _sync_dropdown_options(config, "spawn_rate_adjustment", [
        "Lower",
        "Vanilla",
        "Higher"
    ]) or changed

    changed = _sync_dropdown_options(config, "bandit_spawn_mode", [
        "Map Default",
        "On",
        "Off"
    ]) or changed

    changed = _sync_dropdown_options(config, "guard_spawn_mode", [
        "Map Default",
        "On",
        "Off"
    ]) or changed

    changed = _sync_dropdown_options(config, "military_spawn_mode", [
        "Map Default",
        "On",
        "Off"
    ]) or changed

    changed = _sync_dropdown_options(config, "player_faction_alignment", [
        "Neutral",
        "Bandit",
        "Guard",
        "Military"
    ]) or changed

    changed = _sync_dropdown_options(config, "ai_tactics_preset", [
        "Passive",
        "Default",
        "Aggressive",
        "Relentless"
    ]) or changed

    changed = _sync_dropdown_default(config, "intensity_preset", 3) or changed

    return changed

func _migrate_intensity_preset_options(config: ConfigFile) -> bool:
    if !config.has_section_key("Dropdown", "intensity_preset"):
        return false

    var entry = config.get_value("Dropdown", "intensity_preset")
    if !(entry is Dictionary) || !entry.has("options") || !entry.has("value"):
        return false

    var options = entry["options"]
    if !(options is Array) || options.size() != 4:
        return false

    var expected_old_options = ["Default", "High", "Very High", "Insane"]
    for i in range(expected_old_options.size()):
        if str(options[i]) != expected_old_options[i]:
            return false

    var old_value = int(entry["value"])
    match old_value:
        1:
            entry["value"] = 3
        2:
            entry["value"] = 4
        3:
            entry["value"] = 5
        _:
            entry["value"] = 0

    if entry.has("default"):
        var old_default = int(entry["default"])
        match old_default:
            1:
                entry["default"] = 3
            2:
                entry["default"] = 4
            3:
                entry["default"] = 5
            _:
                entry["default"] = 0

    config.set_value("Dropdown", "intensity_preset", entry)
    return true

func _sync_dropdown_options(config: ConfigFile, key: String, options: Array) -> bool:
    if !config.has_section_key("Dropdown", key):
        return false

    var entry = config.get_value("Dropdown", key)
    var changed = false

    if !entry.has("options") || entry["options"] != options:
        entry["options"] = options
        changed = true

    var max_index = options.size() - 1
    if entry.has("value"):
        var clamped_value = clamp(int(entry["value"]), 0, max_index)
        if clamped_value != int(entry["value"]):
            entry["value"] = clamped_value
            changed = true

    if entry.has("default"):
        var clamped_default = clamp(int(entry["default"]), 0, max_index)
        if clamped_default != int(entry["default"]):
            entry["default"] = clamped_default
            changed = true

    if changed:
        config.set_value("Dropdown", key, entry)

    return changed

func _sync_dropdown_default(config: ConfigFile, key: String, default_value: int) -> bool:
    if !config.has_section_key("Dropdown", key):
        return false

    var entry = config.get_value("Dropdown", key)
    if !(entry is Dictionary):
        return false

    if !entry.has("default") || int(entry["default"]) != default_value:
        entry["default"] = default_value
        config.set_value("Dropdown", key, entry)
        return true

    return false

func _sync_saved_mod_version(config: ConfigFile) -> bool:
    var saved_version = ""
    if config.has_section_key("Meta", "mod_version"):
        saved_version = str(config.get_value("Meta", "mod_version"))

    if saved_version == MOD_VERSION:
        return false

    config.set_value("Meta", "mod_version", MOD_VERSION)
    print("[EnemyAI] Updated saved mod version from '%s' to '%s' without changing player settings." % [saved_version, MOD_VERSION])
    return true
