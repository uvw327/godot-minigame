# Engine bridge contract and the 0.4.2 regression / 引擎桥契约与 0.4.2 回归复盘

`JavaScriptBridge` is the only path between GDScript and a mini-game host. This
document records the contract that keeps it linked, the regression that broke it
in template revision 2, and the rules that now prevent a repeat. Read it before
rebuilding an engine template or changing the export-time `godot.js` patches.

`JavaScriptBridge` 是 GDScript 与小程序宿主之间的唯一通道。本文记录让它保持链接的
契约、模板 revision 2 中导致它失效的回归，以及现在用于防止复发的规则。重编引擎模板
或修改导出期的 `godot.js` 补丁前，请先读完本文。

---

## 1. Summary / 摘要

Godot 4.7 gates `js/libs/library_godot_javascript_singleton.js` — the file that
defines `GodotJSWrapper` — behind the `javascript_eval` build flag. Template
revision 2 was built with `javascript_eval=no`, so the browser build had no
JavaScript side for the bridge: `JavaScriptBridge.get_interface()` returned
`null`, the ABI handshake never ran, and the runtime reported:

```
Mini-game Bridge ABI 1 (godotMiniGameBridgeV1) is not available
```

The fix is not to bypass the bridge but to **keep it compiled in**
(`javascript_eval=yes`, revision 3) and to **remove `eval` at export time** for
hosts that forbid it. TikTok never receives an engine that can evaluate strings;
WeChat and Douyin keep the full bridge.

Godot 4.7 把定义 `GodotJSWrapper` 的 `js/libs/library_godot_javascript_singleton.js`
放进了 `javascript_eval` 编译开关里。模板 revision 2 以 `javascript_eval=no` 构建，
浏览器产物里因此没有桥的 JavaScript 侧：`JavaScriptBridge.get_interface()` 返回
`null`，ABI 握手从未执行，运行时输出 `Mini-game Bridge ABI 1 ... is not available`。

修复思路不是绕开桥，而是**让桥参与编译**（`javascript_eval=yes`，revision 3），再
对禁止 `eval` 的宿主在**导出期**剥离。TikTok 拿到的引擎不具备字符串求值能力，
微信与抖音保留完整桥。

---

## 2. Impact / 影响面

| Axis | Value |
|---|---|
| Plugin version affected | `v0.4.1`（内置模板 revision 2） |
| Engine | Godot `4.7.2.stable` · emsdk `4.0.11` · `2d_full` · `release` · ABI 1 |
| Failure point | `addons/godot_mini_game/MiniGameSDK.gd:175` via `_fail_bridge_initialization()` |
| Platforms | 微信、抖音、TikTok 全部（桥是共享 ABI，不是单平台问题） |
| User-visible effect | 导出成功但运行即失败；宿主 API、存储、生命周期全部不可用 |
| Fixed in | `v0.4.2`，内置模板 revision 3 |

微信、抖音、TikTok 同时失效这一点很关键：它说明问题在**引擎产物**，而不在任何一个
平台适配层。看到多平台同时报同一个 ABI 错误时，应先检查引擎，而不是平台代码。

---

## 3. Timeline / 时间线

1. 插件升级目标版本到 Godot `4.7.2.stable`，内置模板重建为 revision 2。
2. 用户安装 `v0.4.1` 后，微信/抖音运行时输出 ABI 不可用。
3. 对产物符号计数，确认 r2 引擎缺失 `GodotJSWrapper`、`godot_js_wrapper_interface_get`
   与 `_godot_js_eval`；同期 4.6.1 旧引擎三者齐全。
4. 阅读 Godot 4.7 源码：`platform/web/detect.py` 在 `javascript_eval` 时定义
   `JAVASCRIPT_EVAL_ENABLED`，`js/libs/SCsub` 据此条件链接
   `library_godot_javascript_singleton.js`。
5. 构建脚本与 CI 工作流改为 `javascript_eval=yes`，revision 提到 3。
6. 构建 run `39284075687` 失败：verifier 在 wasm 二进制里断言桥符号。
7. 放宽为条件式符号检查后，run `39289466563` 仍失败：
   `godot.wasm has no godot_js_wrapper_interface_get import`。
8. 把证明从 wasm 移到 `godot.js`（run `39347380307`）后构建成功；回写 job 产生
   `9a3d447`。
9. 核对 r3 产物时发现 wasm import 名已被压缩为 `ze:_godot_js_eval`，TikTok 剥离
   逻辑会误判，遂修正并按新形态模拟验证。
10. 合入 `main`（`bae6be0`）→ smoke 通过 → 打 `v0.4.2` tag → 三平台 smoke 与打包
    全部通过。

---

## 4. Root cause / 根因

For a Web build Godot compiles the JavaScript singleton library only when
`javascript_eval` is enabled. That library is what exposes:

- `GodotJSWrapper` — the JavaScript object `JavaScriptBridge` talks to;
- `godot_js_wrapper_interface_get` — the lookup used by
  `JavaScriptBridge.get_interface()`;
- `_godot_js_eval` — the same library's string-evaluation entry point.

Disabling `javascript_eval` therefore does not merely disable `eval`; it removes
the whole bridge. There is no supported way to keep `GodotJSWrapper` and drop
`eval` at compile time, which is why the platform restriction has to be handled
in the exported JavaScript instead.

Web 构建中，Godot 只在 `javascript_eval` 开启时编译这个 JavaScript singleton 库。
该库同时提供三样东西：`GodotJSWrapper`（`JavaScriptBridge` 对话的 JavaScript
对象）、`godot_js_wrapper_interface_get`（`get_interface()` 的查找入口）、以及
`_godot_js_eval`（同一个库里的字符串求值入口）。

所以关闭 `javascript_eval` 不是"只关掉 eval"，而是**整个桥一起消失**。Godot 没有
提供"保留 `GodotJSWrapper`、编译期去掉 eval"的开关，平台限制只能放到导出产物里处理。

---

## 5. Evidence / 证据

Symbol counts in the shipped `godot.js`:

| Symbol | 4.6.1（旧引擎） | 4.7.2 r2（坏） | 4.7.2 r3（修好） |
|---|---:|---:|---:|
| `GodotJSWrapper` | 38 | 0 | 37 |
| `godot_js_wrapper_interface_get` | 3 | 0 | 2 |
| `_godot_js_eval` | 1 | 0 | 2 |
| `function _godot_js_eval(` | 1 | 0 | 1 |
| `eval(` | 3 | 0 | 3 |
| `var IDHandler` | 1 | 1 | 1 |

r2 的 `eval(` 为 0 曾经造成"这个模板很安全"的错觉；实际上它是把整座桥删掉了。

r3 的 wasm import 映射形态（`optimize=size` 下键名被压缩）：

```text
…,ze:_godot_js_eval,Db:_godot_js_fetch_create,…
```

因此**不能**把 `godot_js_eval:_godot_js_eval` 当作稳定锚点，只能匹配值侧的
`:_godot_js_eval`。

---

## 6. Connected failures and fixes / 连带问题与修复

### 6.1 Verifier asserted on the wasm binary / 校验器把断言写进了 wasm

**Problem.** The verifier looked for unminified symbol names inside `godot.wasm`.
`optimize=size` renames wasm imports, so a correct bridge still failed the check.

**Fix.** Prove the bridge on the JavaScript side: require `GodotJSWrapper` and
`godot_js_wrapper_interface_get` in `godot.js`, and check `_godot_js_eval` only
when `eval(` is present. Do not assert on minified wasm import names. Diagnostics
use `::error::` annotations so CI failures are readable without job-log access.

**问题**：校验器在 `godot.wasm` 里找未压缩的符号名，而 `optimize=size` 会重命名
wasm import，正确的桥也会被判失败。

**修复**：证明位置改到 JavaScript 侧——在 `godot.js` 里要求
`GodotJSWrapper` 与 `godot_js_wrapper_interface_get`，`_godot_js_eval` 仅在存在
`eval(` 时条件校验；不对压缩后的 wasm import 名做断言。诊断统一用 `::error::`。

### 6.2 TikTok strip hard-coded the unminified key / TikTok 剥离硬编码了未压缩键名

**Problem.** `exporter.gd` required `content.count("godot_js_eval:_godot_js_eval") == 1`
and returned `ERR_FILE_CORRUPT` otherwise. r3 emits `ze:_godot_js_eval`, so correct
engines would have been rejected at TikTok export time.

**Fix.** Match the stable value side and replace it with the disabled stub:

```gdscript
var eval_start := content.find("function _godot_js_eval(")
var eval_end := content.find("var IDHandler", eval_start)
# … splice out the eval implementation, insert _godot_js_disabled …
if not content.contains(":_godot_js_eval"):
    return ERR_FILE_CORRUPT
content = content.replace(":_godot_js_eval", ":_godot_js_disabled")
```

After the rewrite the exporter rejects any residual `eval(` **or**
`_godot_js_eval`, so a half-applied patch can never ship.

**问题**：`exporter.gd` 要求 `godot_js_eval:_godot_js_eval` 恰好出现一次，否则返回
`ERR_FILE_CORRUPT`。r3 实际是 `ze:_godot_js_eval`，正确的引擎反而会被拒绝。

**修复**：匹配稳定的值侧 `:_godot_js_eval` 并替换为 `:_godot_js_disabled`；剥离后
若仍残留 `eval(` 或 `_godot_js_eval` 一律拒绝出包，避免"改了一半"的产物发布。

### 6.3 CI committed the engine bundle / CI 把引擎包提交进了仓库

**Problem.** The auto-write-back job ran `git add -A` while the downloaded bundle
still sat in `engine-bundle/`, adding a 6.8 MB ZIP to history.

**Fix.** The installer step now runs `rm -rf engine-bundle` before committing, and
`/engine-bundle/` is ignored. Release artifacts belong to GitHub Releases, not to
the source tree.

**问题**：回写 job 执行 `git add -A` 时，下载的 bundle 还在 `engine-bundle/`，
把 6.8 MB 的 ZIP 写进了历史。

**修复**：安装步骤在提交前 `rm -rf engine-bundle`，并把 `/engine-bundle/` 加入
`.gitignore`。发布产物只属于 GitHub Release，不进源码树。

### 6.4 Tags package, they do not build / tag 只打包，不构建

**Problem.** `v*` tags trigger `release-plugin.yml`, which packages whatever engine
is committed. It never rebuilds the template. Tagging before the new engine lands
ships the old, broken bundle.

**Fix.** Engine changes are pushed to an `engine/**` branch, which triggers
`build-template.yml`; its `sync-engine-files` job installs the certified bundle and
commits it back. Because `push` events have no `inputs`, defaults use
`${{ inputs.x || 'default' }}`. A tag is created only after that commit is merged
into `main` and the `main` smoke run is green.

**问题**：`v*` tag 触发 `release-plugin.yml`，它只打包仓库里现有的引擎，从不重建
模板。在新引擎回写前打 tag，发布的就是旧的坏包。

**修复**：引擎改动推到 `engine/**` 分支触发构建；`sync-engine-files` job 安装认证
bundle 并回写提交。`push` 事件没有 `inputs`，默认值用
`${{ inputs.x || 'default' }}` 兜底。只有当回写提交合入 `main` 且 `main` 的 smoke
通过后，才创建 tag。

---

## 7. Current defenses / 现在的防线

| Defense | What it catches |
|---|---|
| `scripts/verify_wasm_template.sh` | 缺少 `GodotJSWrapper` / `godot_js_wrapper_interface_get` 的模板 |
| `test/engine_bridge.test.mjs` | 内置引擎丢失桥，或 manifest 与 `support-matrix.json` 身份不一致 |
| `core/template_bundle.gd` | 默认 `javascriptEval: true`，并拒绝显式关闭桥的模板 |
| `test/release_contract.test.mjs` | 构建脚本/工作流回退到 `javascript_eval=no`、revision 不匹配 |
| `test/exporter_platform_contract_test.gd` | TikTok 剥离后残留 `eval(`，或未路由到 `_godot_js_disabled` |
| `scripts/locate_godot_js_anchors.mjs` | `godot.js` 锚点漂移（含 TikTok eval 锚点） |
| CI `rm -rf engine-bundle` + `.gitignore` | 引擎包再次进入源码树 |

`test/engine_bridge.test.mjs` 是这次回归的直接守门员：它读取真实的
`engine/template.json` 与 `engine/godot.js`，断言 `javascriptEval === true` 且两个
桥符号存在。把 `javascript_eval` 改回 `no` 会让它立即失败。

---

## 8. Checklist / 检查清单

### Before rebuilding an engine / 重编引擎前

- [ ] 确认目标 Godot 源码里 `library_godot_javascript_singleton.js` 的链接条件
- [ ] 构建参数包含 `javascript_eval=yes`
- [ ] `template.json` 的 `features.javascriptEval` 为 `true`，revision 递增
- [ ] `support-matrix.json` 的 `bundled` 行同步 revision / 版本 / commit

### After a build / 构建完成后

- [ ] `godot.js` 含 `GodotJSWrapper` 与 `godot_js_wrapper_interface_get`
- [ ] `eval(` 仍存在（说明桥完整），且 `_godot_js_eval` 锚点可定位
- [ ] `node scripts/locate_godot_js_anchors.mjs <godot.js>` 全部 `OK`
- [ ] 用真实产物模拟 TikTok 剥离：`eval(` → 0，无 `_godot_js_eval` 残留，语法有效
- [ ] `node --test test/*.test.mjs` 全绿（含 `engine_bridge`）

### Before tagging / 打 tag 前

- [ ] 引擎回写提交已合入 `main`
- [ ] `main` 的 **Smoke Test Export** 通过（微信 / 抖音 / TikTok 三平台）
- [ ] `plugin.cfg`、`support-matrix.json`、README 与目标 tag 版本一致
- [ ] `engine-bundle/` 未出现在 `git status` 中

### After publishing / 发布后

- [ ] Release 非 draft、非 prerelease，ZIP 与 `.sha256` 均存在
- [ ] 真机冷启动不再出现 `Mini-game Bridge ABI 1 ... is not available`
- [ ] 微信/抖音保留完整桥；TikTok 产物中 `eval(` 为 0

---

## 9. Rejected options / 未采用的方案

| Option | Why not |
|---|---|
| Rewrite the SDK to avoid `JavaScriptBridge` | 文件、网络、生命周期、平台 API 几乎全部建立在它之上，工作量不可接受且会引入新的不一致 |
| Quick patch on the WeChat side | 只治一个平台，且无法在仓库内复现与回归 |
| Build the engine locally | 可行但不可重复；CI 构建约 15 分钟，且能自动回写与留痕 |
| Keep `javascript_eval=no` and stub the SDK | 桥不存在时 SDK 只能返回假值，宿主能力全部失效，等于放弃插件核心功能 |

结论：**桥必须在编译期保留，`eval` 只能在导出期按平台裁剪。** 任何试图在编译期
同时满足"有桥"和"无 eval"的方案，在 Godot 4.7 的构建系统里都不成立。
