# Full engine cut: the stock web template with only the modules that cannot
# work on a mini-game host removed.
#
# This is the profile the `mod` branch ships. Keep it equivalent to the
# original build command so upgrading the engine never silently changes the
# certified engine identity.
#
# Build invariants (platform, target, arch, threads, javascript_eval, ...) are
# passed on the scons command line by scripts/build_wasm_template.sh and
# .github/workflows/build-template.yml, not from this file.

module_webrtc_enabled = "no"
module_webxr_enabled = "no"
module_openxr_enabled = "no"
