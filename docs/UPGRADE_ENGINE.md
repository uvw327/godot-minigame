# Upgrading the bundled engine / 升级内置引擎

Godot Mini Game pins an **exact-version** mini-game engine template: a custom
Godot Web build plus a `template.json` that records the four-part Godot version,
the full source commit, the Emscripten release, the WASM feature profile, and the
SHA-256 of both engine files. `exporter.gd` additionally rewrites the generated
`godot.js` with exact-string patches and fails closed if an anchor is missing.
Moving the plugin to a new Godot release therefore has **two independent parts**:

1. **Rebuild the engine bundle** for the new Godot tag + Emscripten release, and
   re-align the `_patch_godot_js()` anchors.
2. **Re-sync the identity data** (manifest, support matrix, site data, prose).

Only step 1 needs a compiler. Everything else is data and is scripted below.

> Godot Mini Game 0.4 targets **Godot `4.7.2.stable`** (`4.7.2-stable`,
> commit `ed1daf0bf001b61586d9930840f2f1394092c079`) with **Emscripten `4.0.11`**.

---

## 1. Build the bundle

Either trigger the **Build Mini-Game WASM Template** GitHub Actions workflow with
`godot_version=4.7.2-stable` and `emscripten_version=4.0.11`, or build locally:

```bash
./scripts/build_wasm_template.sh 4.7.2-stable 4.0.11
```

This installs the exact Emscripten SDK, checks out the exact Godot tag, forces
`SUPPORT_LONGJMP=emscripten` (mini-game hosts have no WASM exception support),
builds with `wasm_simd=no threads=no dlink_enabled=no javascript_eval=yes` and
the engine cut described by `scripts/engine_profiles/{BUILD_PROFILE}.py`, and
validates the result with `scripts/verify_wasm_template.sh`. The output is a
`godot_minigame_template_4.7.2-stable_emsdk-4.0.11_{profile}_release_abi-1_r<N>.zip`
(the profile segment uses dashes, for example `2d-full` or `minigame`).

> `javascript_eval=yes` is mandatory. In Godot 4.7 the flag also gates
> `js/libs/library_godot_javascript_singleton.js` (`GodotJSWrapper`), so a
> `javascript_eval=no` build has no `javascript_bridge_singleton` JS side and
> `JavaScriptBridge.get_interface()` silently returns `null`. TikTok, which
> forbids `eval`, is handled at export time by `exporter.gd`, which rewrites
> `_godot_js_eval` into a disabled stub. `scripts/verify_wasm_template.sh`
> hard-fails a bundle that lacks `GodotJSWrapper` or the
> `godot_js_wrapper_interface_get` import.

Two rules come straight from the 0.4.2 regression:

- Prove the bridge in `godot.js`, never in the minified wasm. `optimize=size`
  renames wasm imports, so binary symbol assertions reject correct engines.
- Match the TikTok eval strip on the value side (`:_godot_js_eval`) instead of a
  fixed `godot_js_eval:_godot_js_eval` key. The import key can be minified to
  something like `ze`.

Full background and a pre-tag checklist: [Engine bridge contract](ENGINE_BRIDGE.md).

Local prerequisites: `emcc`, `scons`, `brotli`, `jq`, `node`, `wabt`
(`wasm-validate`), `zip`, `python3`.

## 2. Align the `godot.js` patch anchors

`exporter.gd` `_patch_godot_js()` matches these regions by exact string. A new
Emscripten release can change the Emscripten-owned anchors, and a new Godot
release can change the `platform/web/js/libs/engine.js`-owned anchors. Audit the
freshly built `godot.js`:

```bash
node scripts/locate_godot_js_anchors.mjs \
  /path/to/godot.web.template_release.wasm32.nothreads.wrapped.js
```

Godot 4.7 emits three JavaScript artifacts — `<stem>.engine.js`, `<stem>.js`,
and `<stem>.wrapped.js` — and installs the **wrapped** file as the Web template's
`godot.js`, so that is the single entry point the bundle ships and the file to
audit. (The build script and CI select it explicitly.)

The script prints `OK` (with the matched region) or `MISSING` (with the
`exporter.gd` variable to update), and exits non-zero if any anchor is missing.
For each `MISSING` anchor, copy the exact new region out of the engine and update
the matching `_old`/`_new` pair in `exporter.gd` `_patch_godot_js()` (around lines
1578–1860). Re-run the locator until it reports every anchor `OK`.

The anchors cover: canvas `parentElement`, `GL.createContext`,
`connectPositionWorklet`, `isWebGLAvailable`, the engine `instantiateWasm`
wrapper, the Emscripten `instantiateWasm` callback, the `Module["copyToFS"]` /
`ensureFSDirectory` injection point, the `Engine` FS methods injection point, and
the `Engine.prototype['copyToFS']` export anchor.

## 3. Install the verified bundle

```bash
./scripts/install_engine_template.sh \
  build_wasm/output/4.7.2-stable/emsdk-4.0.11/{profile}/release/abi-1/r3/<bundle>.zip
```

The installer runs the shared verifier, copies `godot.js`, `godot.wasm.br`,
`version.txt`, and `template.json` into `addons/godot_mini_game/engine/`, copies
`GODOT_COPYRIGHT.txt` beside `THIRD_PARTY_NOTICES.md`, re-points the single
`bundled` row in `support-matrix.json`, and regenerates
`website/app/site-data.generated.ts`. It refuses a tampered bundle, a missing
bundled row, or multiple bundled rows.

## 4. Update the prose

The installer deliberately leaves human-readable text alone. Update the identity
strings in these files (search-and-replace, in this order so prefixes match
first):

| File | Old → new |
|---|---|
| `README.md`, `README_zh.md` | badge `Godot-4.6.1` → `Godot-4.7.2`; table `4.6.1.stable` → `4.7.2.stable`; `14d19694e0c8` → `ed1daf0bf001`; `4.0.3` → `4.0.11`; `revision \`2\`` → `revision \`3\`` (must equal `support-matrix.json` `templateRevision`) |
| `docs/USAGE.md`, `docs/USAGE_zh.md` | `4.6.1` → `4.7.2`; `4.6.1-stable` → `4.7.2-stable`; `4.0.3` → `4.0.11` |
| `docs/ARCHITECTURE.md` | `4.6.1.stable` → `4.7.2.stable`; full commit; `emsdk-4.0.3` → `emsdk-4.0.11`; prose examples |
| `addons/godot_mini_game/THIRD_PARTY_NOTICES.md` | `Godot 4.6.1-stable` → `Godot 4.7.2-stable` |

Ordered replacement (full commit **before** the short prefix):

```bash
perl -pi -e 's/14d19694e0c88a3f9e82d899a0400f27a24c176e/ed1daf0bf001b61586d9930840f2f1394092c079/g' \
  README.md README_zh.md docs/USAGE.md docs/USAGE_zh.md docs/ARCHITECTURE.md addons/godot_mini_game/THIRD_PARTY_NOTICES.md
```

Then review `git diff` for the badge, table rows, short commit, Emscripten
version, and the `revision` number; adjust any sentence that reads oddly (for
example the `4.6` / `4.6.1` version-normalization examples in
`docs/ARCHITECTURE.md`). The local build script and the CI workflow both default
to `TEMPLATE_REVISION=3`, so the current bridge-enabled template expects
`revision 3` in the READMEs; keep it equal to `support-matrix.json`
`templateRevision`.

## 5. Verify

```bash
GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot ./scripts/test.sh
```

`scripts/test.sh` runs the Node contract tests and every GDScript test against a
disposable project, including a real mini-game export smoke test per platform.
`test/release_contract.test.mjs` and `test/readme_homepage.test.mjs` derive their
expectations from `support-matrix.json` and `engine/template.json`, so they will
pass automatically once steps 3 and 4 are complete.

---

## 版本升级（中文）

Godot Mini Game 锁定一份**精确版本**的小游戏引擎模板：自定义 Godot Web 构建 + 记录
四段式版本、40 位源码提交、Emscripten 版本、WASM 特性与两个引擎文件 SHA-256 的
`template.json`。`exporter.gd` 还会对 `godot.js` 做精确字符串补丁，锚点对不上直接
失败。因此升级到新 Godot 版本分为**两件独立的事**：重编引擎模板并对齐补丁锚点；再
同步身份数据（manifest、支持矩阵、站点数据、文案）。

0.4 目标为 **Godot `4.7.2.stable`**（tag `4.7.2-stable`，commit
`ed1daf0bf001b61586d9930840f2f1394092c079`）与 **Emscripten `4.0.11`**。

步骤：① 用 `scripts/build_wasm_template.sh 4.7.2-stable 4.0.11`（或 CI 工作流）构建
模板；② 用 `node scripts/locate_godot_js_anchors.mjs <godot.js>` 审计锚点，逐一修正
`exporter.gd` 的 `_patch_godot_js()`；③ 用
`scripts/install_engine_template.sh <bundle.zip>` 安装并同步 `support-matrix.json` 与
站点数据；④ 按第 4 节清单更新 README/docs/THIRD_PARTY_NOTICES 文案；⑤ 用
`GODOT_BIN=<godot> ./scripts/test.sh` 回归。

两条来自 0.4.2 回归的硬规则：**桥的证明必须放在 `godot.js`，不能放在压缩后的
wasm 里**（`optimize=size` 会重命名 import，二进制符号断言会误杀正确产物）；**TikTok
的 eval 剥离必须匹配值侧 `:_godot_js_eval`**，不能依赖 `godot_js_eval:_godot_js_eval`
这种会被压缩成 `ze:_godot_js_eval` 的键名。完整背景与打 tag 前检查清单见
[引擎桥契约](ENGINE_BRIDGE.md)。
