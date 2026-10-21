#!/usr/bin/env node
// Audit and locate the `godot.js` patch anchors that exporter.gd rewrites in
// `_patch_godot_js()`. `_patch_godot_js` matches exact strings and fails closed,
// so a rebuilt engine (new Godot version and/or Emscripten) can break an anchor.
//
// Usage:
//   node scripts/locate_godot_js_anchors.mjs <path/to/godot.js>
//
// For every anchor it prints OK (with the matched region) or MISSING (with the
// hint that names the exporter.gd variable to update). It exits non-zero when
// any anchor is missing, so it can gate a rebuild loop.
//
// Keep ANCHORS in sync with exporter.gd `_patch_godot_js`. Each entry is
// satisfied when any of its needles is present: the pre-patch form (which the
// exporter replaces) or the post-patch marker (which the exporter detects and
// skips), so re-running on an already-patched file still reports OK.

import { readFileSync } from "node:fs";

const path = process.argv[2];
if (!path) {
  console.error("Usage: node scripts/locate_godot_js_anchors.mjs <path/to/godot.js>");
  process.exit(2);
}

let source;
try {
  source = readFileSync(path, "utf8");
} catch (error) {
  console.error(`Cannot read ${path}: ${error.message}`);
  process.exit(2);
}

const ANCHORS = [
  {
    name: "canvas parentElement",
    variable: "_pe / _pe_patched",
    needles: [
      "GodotConfig.canvas.parentElement.appendChild(",
      "(GodotConfig.canvas.parentElement||document.body).appendChild(",
    ],
  },
  {
    name: "GL.createContext",
    variable: "_gl_create_old / _gl_create_new",
    needles: [
      'createContext:(canvas,webGLContextAttributes)=>{if(webGLContextAttributes.renderViaOffscreenBackBuffer)webGLContextAttributes["preserveDrawingBuffer"]=true;var ctx=webGLContextAttributes.majorVersion>1?canvas.getContext("webgl2",webGLContextAttributes):canvas.getContext("webgl",webGLContextAttributes);if(!ctx)return 0;var handle=GL.registerContext(ctx,webGLContextAttributes);return handle}',
      'var type=webGLContextAttributes.majorVersion>1?"webgl2":"webgl";',
    ],
  },
  {
    name: "AudioWorklet connectPositionWorklet",
    variable: "_cpw_old / _cpw_new",
    needles: [
      "async connectPositionWorklet(start){await GodotAudio.audioPositionWorkletPromise;if(this.isCanceled){return}this._source.connect(this.getPositionWorklet());if(start){this.start()}}",
      "async connectPositionWorklet(start){if(start){this.start()}}",
    ],
  },
  {
    name: "isWebGLAvailable",
    variable: "_webgl_check / _webgl_check_patched",
    needles: [
      "return !!document.createElement('canvas').getContext(['webgl', 'webgl2'][majorVersion - 1]);",
      "console.log('[isWebGLAvailable] v='+majorVersion+' r='+!!_r);",
    ],
  },
  {
    name: "engine instantiateWasm wrapper",
    variable: "_instantiate_wrapper_old / _instantiate_wrapper_new",
    needles: [
      "\t\t\t'instantiateWasm': function (imports, onSuccess) {\n\t\t\t\tfunction done(result) {\n\t\t\t\t\tonSuccess(result['instance'], result['module']);\n\t\t\t\t}\n\t\t\t\tif (typeof (WebAssembly.instantiateStreaming) !== 'undefined') {\n\t\t\t\t\tWebAssembly.instantiateStreaming(Promise.resolve(r), imports).then(done);\n\t\t\t\t} else {\n\t\t\t\t\tr.arrayBuffer().then(function (buffer) {\n\t\t\t\t\t\tWebAssembly.instantiate(buffer, imports).then(done);\n\t\t\t\t\t});\n\t\t\t\t}\n\t\t\t\tr = null;\n\t\t\t\treturn {};\n\t\t\t},",
      "operation = WebAssembly.instantiateStreaming(Promise.resolve(r), imports).then(done);",
    ],
  },
  {
    name: "emscripten instantiateWasm callback",
    variable: "_emscripten_instantiate_old / _emscripten_instantiate_new",
    needles: [
      'if(Module["instantiateWasm"]){return new Promise((resolve,reject)=>{Module["instantiateWasm"](info,(mod,inst)=>{resolve(receiveInstance(mod,inst))})})}',
      'var instantiateOperation=Module["instantiateWasm"]',
    ],
  },
  {
    // Also anchors the `Module["ensureFSDirectory"]` injection.
    name: "Module copyToFS / ensureFSDirectory injection point",
    variable: "_module_copy_anchor",
    needles: [
      'Module["copyToFS"]=GodotFS.copy_to_fs;',
      'Module["copyFSToAdapter"]=',
    ],
  },
  {
    // Also anchors the `Engine.prototype.ensureFSDirectory` injection.
    name: "Engine FS methods injection point",
    variable: "_engine_copy_anchor / _engine_ensure_anchor",
    needles: [
      "\n\t\t\t/**\n\t\t\t * Request that the current instance quit.",
      "copyFSToAdapter: function (adapter, roots)",
    ],
  },
  {
    name: "Engine.prototype export anchor",
    variable: "_prototype_copy_anchor",
    needles: [
      "Engine.prototype['copyToFS'] = Engine.prototype.copyToFS;",
      "Engine.prototype['copyFSToAdapter']",
    ],
  },
  {
    // exporter.gd rewrites the eval implementation for TikTok. The pre-patch
    // function and the post-patch marker both satisfy the anchor, so auditing
    // an already-patched file still reports OK.
    name: "TikTok eval bridge strip",
    variable: "_eval_old / _eval_new",
    needles: [
      "function _godot_js_eval(",
      "godot_js_eval:_godot_js_eval",
      "godot_js_eval:_godot_js_disabled",
    ],
  },
];

function context(index, needleLength) {
  const start = Math.max(0, index - 70);
  const end = Math.min(source.length, index + needleLength + 70);
  return source.slice(start, end).replace(/\s+/g, " ").trim();
}

let missing = 0;
for (const anchor of ANCHORS) {
  let hit = null;
  for (const needle of anchor.needles) {
    const index = source.indexOf(needle);
    if (index !== -1) {
      hit = { needle, index };
      break;
    }
  }
  if (hit) {
    console.log(`OK       ${anchor.name} @ ${hit.index}`);
    console.log(`         … ${context(hit.index, hit.needle.length)} …`);
  } else {
    missing += 1;
    console.log(`MISSING  ${anchor.name}`);
    console.log(`         update exporter.gd \`${anchor.variable}\``);
    console.log(`         needles tried: ${anchor.needles.map((n) => JSON.stringify(n)).join(", ")}`);
  }
}

console.log("");
if (missing > 0) {
  console.log(`${missing} anchor(s) missing: re-derive them from the engine below and update exporter.gd.`);
  process.exit(1);
}
console.log("All anchors located. exporter.gd _patch_godot_js should patch this engine cleanly.");
