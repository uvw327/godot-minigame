# WeChat mini-game engine cut.
#
# Target: a 3D planet model rendered with custom spatial shaders, plus a 2D
# RimWorld-style colony sim (management + combat) running in the same exported
# game.  3D therefore stays; what goes away is everything the game never
# touches.
#
# Every option below exists in godotengine/godot SConstruct at 4.7.2-stable.
# Build invariants (platform, target, arch, threads, javascript_eval, ...) are
# passed on the scons command line, not from this file.
#
# The web platform already forces vulkan=no (so the RenderingDevice and the
# Forward+/Mobile renderers are never compiled), optimize=size and
# module_raycast_enabled=no.  The 3D renderer on web is therefore the
# Compatibility (OpenGL ES 3.0) renderer, which supports custom spatial
# shaders but has no SSAO/SSIL/SSR/SDFGI and no volumetric fog.

# --- Size ------------------------------------------------------------------
debug_symbols = "no"
lto = "thin"  # "full" is smaller but needs ~16 GB of RAM on the runner
deprecated = "no"  # drops the compatibility code for removed APIs

# --- Removed subsystems ----------------------------------------------------
disable_xr = "yes"  # XR nodes and XRServer
disable_physics_3d = "yes"  # the planet is a shader-rendered model
disable_navigation_3d = "yes"  # only the 2D colonists path

# disable_advanced_gui stays off: the colony UI needs PopupMenu, RichTextLabel,
# Tree, OptionButton and TextEdit.

# --- Modules: everything off except the whitelist ----------------------------
modules_enabled_by_default = "no"

module_gdscript_enabled = "yes"  # game code
module_freetype_enabled = "yes"  # font rasterization
module_text_server_adv_enabled = "yes"  # CJK shaping and line breaking
module_text_server_fb_enabled = "no"  # the advanced server covers it
module_webp_enabled = "yes"  # lossless textures are stored as WebP
module_ogg_enabled = "yes"  # audio
module_vorbis_enabled = "yes"
module_godot_physics_2d_enabled = "yes"  # 2D combat collisions
module_navigation_2d_enabled = "yes"  # 2D colonist pathing
module_noise_enabled = "yes"  # FastNoiseLite terrain generation
module_regex_enabled = "yes"  # RegEx in gameplay scripts

# Not whitelisted on purpose (re-enable if the game needs them):
#   module_svg_enabled       - runtime SVG loading
#   module_jpg_enabled       - runtime JPEG loading
#   module_mp3_enabled       - MP3 audio
#   module_msdfgen_enabled   - MSDF fonts (CJK is served by a subset font)
#   module_mbedtls_enabled   - Crypto/save signing
#   module_websocket_enabled - WebSocketPeer
#   module_multiplayer_enabled / enet / jsonrpc / upnp - networking
#   module_csg / gridmap / meshoptimizer - editor and 3D tooling
#   module_camera / mobile_vr - AR/VR
