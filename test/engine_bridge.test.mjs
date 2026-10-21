import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../", import.meta.url);

function read(relativePath) {
  return readFileSync(new URL(relativePath, root), "utf8");
}

const manifest = JSON.parse(read("addons/godot_mini_game/engine/template.json"));
const engine = read("addons/godot_mini_game/engine/godot.js");
const matrix = JSON.parse(read("support-matrix.json"));
const bundled = matrix.certified.find((target) => target.template.source === "bundled");

// 内置引擎必须保留 JavaScriptBridge。Godot 4.7 把
// js/libs/library_godot_javascript_singleton.js（GodotJSWrapper）和
// javascript_eval 开关绑死，javascript_eval=no 会让
// JavaScriptBridge.get_interface() 永远返回 null，运行时就会报
// "Mini-game Bridge ABI 1 (godotMiniGameBridgeV1) is not available"。
assert.equal(
  manifest.features.javascriptEval,
  true,
  "内置模板必须保持 javascriptEval 开启，否则 JavaScriptBridge 会被编译掉",
);
assert.ok(
  engine.includes("GodotJSWrapper"),
  "内置 godot.js 必须包含 GodotJSWrapper",
);
assert.ok(
  engine.includes("godot_js_wrapper_interface_get"),
  "内置 godot.js 必须包含 godot_js_wrapper_interface_get",
);

// 内置引擎身份必须与 support-matrix.json 的 bundled 行保持一致。
assert.equal(
  manifest.revision,
  bundled.templateRevision,
  "template.json 的 revision 必须等于 support-matrix.json 的 templateRevision",
);
assert.equal(manifest.godot.version, bundled.godotVersion);
assert.equal(manifest.godot.commit, bundled.godotCommit);
assert.equal(manifest.emscriptenVersion, bundled.emscriptenVersion);
assert.equal(manifest.bridgeAbi, matrix.bridgeAbi);

console.log("engine_bridge.test.mjs: ok");
