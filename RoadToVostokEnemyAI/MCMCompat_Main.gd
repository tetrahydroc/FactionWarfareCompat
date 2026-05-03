extends "res://ModConfigurationMenu/Main.gd"

func _process(delta):
    if (!is_instance_valid(MCMHelpers.MCMButton)) and get_tree().current_scene:
        CreateMCMButton()

func CreateMCMButton():
    if is_instance_valid(MCMHelpers.MCM_Menu):
        MCMHelpers.MCM_Menu.queue_free()

    if !get_tree().current_scene:
        return

    var scene_name = get_tree().current_scene.name
    var settings = get_tree().root.find_child("UI_Settings", true, false)
    var map = get_tree().root.find_child("Map", true, false)

    if settings:
        MCMHelpers.SettingsMenu = settings
    elif is_instance_valid(map):
        MCMHelpers.SettingsMenu = map.find_child("Settings", true, false)
    else:
        MCMHelpers.SettingsMenu = null

    if !is_instance_valid(MCMHelpers.SettingsMenu):
        return

    var settings_parent = MCMHelpers.SettingsMenu.get_parent()
    if !is_instance_valid(settings_parent):
        return

    MCMHelpers.MCM_Menu = mcmMenuScene.instantiate()
    MCMHelpers.MCM_Menu.uiManager = self
    MCMHelpers.MCM_Menu.hide()

    if scene_name == "Menu":
        if !settings_parent.visibility_changed.is_connected(_on_settings_visibility_changed):
            settings_parent.visibility_changed.connect(_on_settings_visibility_changed)
        get_tree().root.add_child(MCMHelpers.MCM_Menu)
    else:
        settings_parent.add_child(MCMHelpers.MCM_Menu)

    var button = Button.new()
    button.tooltip_text = "Mod Configuration Menu"
    button.icon = MCMButtonIcon
    button.expand_icon = true
    button.add_theme_constant_override("icon_max_width", 35)
    button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER

    var button_size = Vector2(55, 55)
    button.size.x = button_size.x
    button.size.y = button_size.x

    button.set_anchor(SIDE_LEFT, 1)
    button.set_anchor(SIDE_TOP, 0)
    button.set_anchor(SIDE_RIGHT, 1)
    button.set_anchor(SIDE_BOTTOM, 0)
    button.set_position(Vector2(-(button_size.x + 30), 30))

    MCMHelpers.MCMButton = button

    if scene_name == "Menu":
        MCMHelpers.MCMButton.visible = false
        var settings_grandparent = settings_parent.get_parent()
        if !is_instance_valid(settings_grandparent):
            MCMHelpers.MCMButton.queue_free()
            MCMHelpers.MCMButton = null
            return
        settings_grandparent.add_child(MCMHelpers.MCMButton)
    else:
        MCMHelpers.SettingsMenu.add_child(MCMHelpers.MCMButton)

    MCMHelpers.MCMButton.button_down.connect(MCMHelpers.ToggleMCMMenu)

func _on_settings_visibility_changed():
    if is_instance_valid(MCMHelpers.SettingsMenu) and is_instance_valid(MCMHelpers.MCMButton):
        var settings_parent = MCMHelpers.SettingsMenu.get_parent()
        if is_instance_valid(settings_parent):
            MCMHelpers.MCMButton.visible = settings_parent.visible
