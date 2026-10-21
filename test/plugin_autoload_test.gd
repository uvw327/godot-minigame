extends SceneTree

## 校验 plugin.gd 对 autoload 值的路径归一化。
##
## Godot 4.7 可能把 autoload 写成 `*uid://...`，而插件自身的约定路径是
## `res://addons/godot_mini_game/MiniGameSDK.gd`。两者必须被视为同一个脚本，
## 否则编辑器每次启动都会误报“名字被占用”。

const Plugin = preload("res://addons/godot_mini_game/plugin.gd")
const SDK_PATH := "res://addons/godot_mini_game/MiniGameSDK.gd"
const OTHER_PATH := "res://addons/godot_mini_game/exporter.gd"

var _failed := false


func _assert_eq(actual: Variant, expected: Variant, message: String) -> void:
	if actual != expected:
		push_error("%s: expected %s, got %s" % [message, str(expected), str(actual)])
		_failed = true


## 写一个与真实项目同形的 project.godot，autoload 使用 uid 写法。
func _write_uid_project(uid_text: String) -> String:
	var dir_path := ProjectSettings.globalize_path("user://autoload_uid_fixture")
	DirAccess.make_dir_recursive_absolute(dir_path)
	var project_path := dir_path.path_join("project.godot")
	var file := FileAccess.open(project_path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write fixture project.godot")
		_failed = true
		return project_path
	file.store_string(
		"config_version=5\n\n[autoload]\n\nMiniGameSDK=\"*%s\"\n" % uid_text
	)
	file.close()
	return project_path


func _init() -> void:
	var sdk_uid := ResourceLoader.get_resource_uid(SDK_PATH)
	_assert_eq(sdk_uid != ResourceUID.INVALID_ID, true, "SDK script must have a uid")
	if sdk_uid == ResourceUID.INVALID_ID:
		quit(1)
		return
	var uid_text := ResourceUID.id_to_text(sdk_uid)

	# 1. 读取真实 project.godot 中的 `*uid://...`，解析结果必须等于 SDK_PATH。
	var fixture_path := _write_uid_project(uid_text)
	var config := ConfigFile.new()
	_assert_eq(config.load(fixture_path), OK, "fixture project.godot must load")
	var stored := str(config.get_value("autoload", "MiniGameSDK", ""))
	_assert_eq(stored, "*" + uid_text, "fixture must keep the *uid:// form")
	_assert_eq(
		Plugin._resolve_autoload_path(stored),
		SDK_PATH,
		"uid autoload must resolve to the plugin script",
	)

	# 2. load() 兜底本身可用：即使不查 uid 缓存，也能从 uid 得到真实路径。
	var loaded := load(uid_text)
	_assert_eq(loaded != null, true, "uid must be loadable")
	if loaded != null:
		_assert_eq(
			loaded.resource_path,
			SDK_PATH,
			"load(uid) must expose the real resource path",
		)

	# 3. 原有的 res:// 写法保持等价。
	_assert_eq(
		Plugin._resolve_autoload_path("*" + SDK_PATH),
		SDK_PATH,
		"plain res:// autoload must still match",
	)
	_assert_eq(
		Plugin._resolve_autoload_path(SDK_PATH),
		SDK_PATH,
		"a value without the * prefix must also match",
	)

	# 4. 真有另一个脚本占用同名时，仍然应被识别为冲突。
	var other_uid := ResourceLoader.get_resource_uid(OTHER_PATH)
	_assert_eq(other_uid != ResourceUID.INVALID_ID, true, "other script must have a uid")
	if other_uid != ResourceUID.INVALID_ID:
		_assert_eq(
			Plugin._resolve_autoload_path("*" + ResourceUID.id_to_text(other_uid)),
			OTHER_PATH,
			"a different uid must resolve to its own path",
		)

	# 5. 无法解析的值原样返回，保守起见不误判。
	_assert_eq(
		Plugin._resolve_autoload_path("*uid://aaaaaaaaaaaa"),
		"uid://aaaaaaaaaaaa",
		"unresolvable uid must fall back to the raw value",
	)
	_assert_eq(
		Plugin._resolve_autoload_path("*"),
		"",
		"an empty autoload value must stay empty",
	)

	if _failed:
		quit(1)
		return
	print("plugin_autoload_test.gd: ok")
	quit(0)
