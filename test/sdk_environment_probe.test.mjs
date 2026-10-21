import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../", import.meta.url);
const source = readFileSync(
  new URL("addons/godot_mini_game/MiniGameSDK.gd", root),
  "utf8",
);

const readyStart = source.indexOf("func _ready() -> void:");
const probeStart = source.indexOf("static func _probe_bridge_interface()");
const probeEnd = source.indexOf("static func _bridge_validation_error(");

assert.notEqual(readyStart, -1, "MiniGameSDK.gd must define _ready()");
assert.notEqual(probeStart, -1, "MiniGameSDK.gd must define _probe_bridge_interface()");
assert.notEqual(probeEnd, -1, "MiniGameSDK.gd must define _bridge_validation_error()");

const ready = source.slice(readyStart, probeStart);
const probe = source.slice(probeStart, probeEnd);
const code = source
  .split("\n")
  .filter((line) => !line.trimStart().startsWith("#"))
  .join("\n");

// 普通 Web 导出没有 godotMiniGameBridgeV1。直接 get_interface(BRIDGE_GLOBAL_NAME)
// 会让引擎在接口缺失时打印 ERROR，因此必须先经 window 探测，再读取桥对象。
assert.match(
  probe,
  /get_interface\("window"\)/,
  "bridge probe must obtain window without an interface-missing error",
);
assert.match(
  probe,
  /window\.get\(BRIDGE_GLOBAL_NAME\)/,
  "bridge probe must read the bridge from window",
);
assert.doesNotMatch(
  code,
  /get_interface\(BRIDGE_GLOBAL_NAME\)/,
  "get_interface(BRIDGE_GLOBAL_NAME) must not be used for detection",
);

// 探测不到桥时必须静默返回，而不是走 ABI 失败告警。
assert.match(
  ready,
  /if candidate == null:[\s\S]*?return/,
  "_ready must return silently when no mini-game bridge is present",
);
assert.doesNotMatch(
  ready,
  /is not available/,
  "plain Web exports must not report a missing mini-game bridge",
);

console.log("sdk_environment_probe.test.mjs: ok");
