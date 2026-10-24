extends SceneTree

## 回归测试：导出 Dock 的高度必须可以自由缩放（最小高度约 80px）。
##
## 背景：Dock 根节点曾经是纯 VBoxContainer，VBox 的计算最小高度等于所有子控件
## 最小高度之和（标签/下拉/输入框/按钮/分隔线/日志区合计约 600px+），编辑器停靠
## 槽以此为缩放下限，面板于是“高度不可调节”。现在内容整体包进 ScrollContainer，
## 根节点与 DockScroll 的 custom_minimum_size 固定为 300x80：Dock 可缩到 80px
## 高，超出部分由滚动条承接。

const DOCK_SCENE := preload("res://addons/godot_mini_game/export_dock.tscn")
const EXPECTED_MIN := Vector2(300, 80)

var _failed := false


func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_failed = true


func _init() -> void:
	var dock = DOCK_SCENE.instantiate()
	root.add_child(dock)
	# 等一帧，确保 _ready 与首次容器布局完成。
	await process_frame

	_assert(dock.custom_minimum_size == EXPECTED_MIN,
		"dock root custom_minimum_size must be %s, got %s" % [EXPECTED_MIN, dock.custom_minimum_size])
	_assert(dock.get_minimum_size() == EXPECTED_MIN,
		"dock computed minimum must stay %s (content must not force a tall min), got %s" % [EXPECTED_MIN, dock.get_minimum_size()])
	_assert(dock.get_combined_minimum_size() == EXPECTED_MIN,
		"dock combined minimum must be %s, got %s" % [EXPECTED_MIN, dock.get_combined_minimum_size()])

	var scroll = dock.get_node("DockScroll")
	_assert(scroll is ScrollContainer, "content must be wrapped in a ScrollContainer")
	_assert(scroll.get_combined_minimum_size() == EXPECTED_MIN,
		"ScrollContainer custom_minimum_size must pin the floor at %s, got %s" % [EXPECTED_MIN, scroll.get_combined_minimum_size()])
	_assert(dock.get_node("DockScroll/Content") is VBoxContainer,
		"ScrollContainer must hold the content VBoxContainer")

	# 内容本身依旧很高：80px 下限不是靠删控件换来的，超长部分由滚动条承接。
	var content = dock.get_node("DockScroll/Content")
	_assert(content.get_minimum_size().y > 300.0,
		"content should still report its natural height, got %s" % content.get_minimum_size())

	# 全部 @onready 引用可达：场景重构后节点路径全部变更，防止空引用。
	for property_name in [
		"platform_option", "appid_input", "orientation_option", "preset_option",
		"output_path", "browse_btn", "export_btn", "cancel_export_btn",
		"timeout_input", "status_label", "folder_dialog", "template_status",
		"import_btn", "refresh_btn", "template_file_dialog",
	]:
		_assert(dock.get(property_name) != null,
			"dock.%s must resolve after the restructure" % property_name)

	dock.queue_free()

	if _failed:
		quit(1)
		return
	print("dock_layout_test.gd: ok")
	quit(0)
