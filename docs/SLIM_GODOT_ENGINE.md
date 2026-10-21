# 引擎裁剪与版本发布规范

本文档约束本项目（fork 版）的分支、Tag 与发布流程。Agent 执行版本相关操作时须遵守本规范。

---

## 1. 版本主轴

以 **Godot 版本 + 类型 + 序号** 为主轴：

- `<GodotTag>`：Godot 官方 tag，必须完全一致，如 `4.7.2-stable`
- 类型：`mod`（插件功能）或 `engine.<name>`（自定义引擎）
- `<N>` / `<M>`：迭代序号，从 `1` 开始

---

## 2. 分支命名

| 分支 | 命名 | 示例 | 用途 |
| :--- | :--- | :--- | :--- |
| 上游追踪 | `main` | `main` | 同步 fork 源，不直接开发 |
| 插件开发 | `mod` | `mod` | 修改功能、UI、逻辑 |
| 引擎构建 | `engine/<name>` | `engine/minigame` | 基于 `mod` 创建，请求裁剪引擎构建 |

规则：
- `engine/<name>` **必须基于 `mod` 创建**。
- `<name>` 用小写字母和连字符，如 `minigame`、`minigame-lite`。
- 不允许直接在 `mod` 分支触发引擎构建。

---

## 3. Tag 命名

### 3.1 mod 正式版 Tag（在 `mod` 分支打）

格式：`v<GodotTag>.mod.<N>`

示例：
- `v4.7.2-stable.mod.1`
- `v4.7.2-stable.mod.2`

含义：适配 Godot `4.7.2-stable` 的第 N 个 mod 稳定版本。

规则：
- `<GodotTag>` 必须与 Godot 官方 tag 完全一致。
- `<N>` 从 `1` 开始，每次发布递增。
- Godot 版本升级时，`<GodotTag>` 跟着变，`<N>` **重置为 `1`**。

### 3.2 自定义引擎 Tag（在 `engine/<name>` 分支打）

格式：`v<GodotTag>.mod.<N>-engine.<name>.<M>`

示例：
- `v4.7.2-stable.mod.1-engine.minigame.1`
- `v4.7.2-stable.mod.1-engine.minigame.2`
- `v4.7.2-stable.mod.2-engine.minigame.1`

含义：基于 `v<GodotTag>.mod.<N>` 的第 M 次 `<name>` 引擎裁剪。

规则：
- 前缀 `v<GodotTag>.mod.<N>` **必须对应一个已存在的 mod tag**。
- `<name>` 与分支名 `engine/<name>` 中的 `<name>` 一致。
- `<M>` 从 `1` 开始，同一基线上每次裁剪递增。
- 基线变化（换 mod tag）时，`<M>` **重置为 `1`**。
- `-engine.` 是视觉分隔符，表示“mod 部分结束，engine 部分开始”。

### 3.3 插件功能版本（可选）

如需要独立的插件功能版本（如 `1.0.0`），**不塞进 tag 名**，而是：
- 写入 Release notes 的 `pluginVersion` 字段；
- 或另建 `plugin-v1.0.0` 系列 tag，与 engine tag 解耦。

---

## 4. 版本演进示例

| 场景 | 分支 | Tag |
| :--- | :--- | :--- |
| 适配 Godot 4.7.2-stable 的 mod 首次稳定 | `mod` | `v4.7.2-stable.mod.1` |
| mod 修复 bug 再次稳定 | `mod` | `v4.7.2-stable.mod.2` |
| 基于 mod.1 首次裁剪 minigame | `engine/minigame` | `v4.7.2-stable.mod.1-engine.minigame.1` |
| 同一基线裁剪配置微调 | `engine/minigame` | `v4.7.2-stable.mod.1-engine.minigame.2` |
| 基于 mod.2 重新裁剪 | `engine/minigame` | `v4.7.2-stable.mod.2-engine.minigame.1` |
| Godot 升级到 4.8.0-stable，mod 首次稳定 | `mod` | `v4.8.0-stable.mod.1` |
| 基于新基线裁剪 | `engine/minigame` | `v4.8.0-stable.mod.1-engine.minigame.1` |

---

## 5. 引擎裁剪方案（engine profile）

引擎裁剪方案用 **profile** 表达，一个方案一个选项文件：

| 文件 | 用途 |
| :--- | :--- |
| `scripts/engine_profiles/2d_full.py` | 全功能方案，`mod` 分支默认使用 |
| `scripts/engine_profiles/minigame.py` | 微信小游戏方案：保留 3D 渲染与 2D 经营/战斗，裁掉用不到的子系统 |

选项文件是 scons 的 profile（Godot 4.7.2 的 `SConstruct` 支持 `profile=<file.py>`），
里面的顶层变量就是 scons 选项。构建命令只负责平台不变量（`platform` / `target` /
`arch` / `threads` / `javascript_eval` / `wasm_simd` / `dlink_enabled`），其余全部
来自 profile 文件。

- 分支名决定 profile：`engine/minigame` → profile `minigame`
- profile 名会写进 `template.json`、`support-matrix.json` 的认证行和本地模板缓存路径，
  插件据此拒绝混用不同裁剪方案的引擎
- 切换 profile 会改变引擎体积，属于不可变输入的一部分：改用新 revision 号

> **注意**：Web 平台的 3D 只有 Compatibility（OpenGL ES 3.0）渲染器，没有 SSAO/SSIL/SSR、
> SDFGI 和体积雾。星球地表、光照与生态需要自己在 spatial shader 里实现。

---

## 6. 规范的落地方式

| 脚本 / 工作流 | 职责 |
| :--- | :--- |
| `scripts/validate_release_tag.sh` | 校验 tag 格式、`<GodotTag>` 与内置认证引擎是否一致、`plugin.cfg` 与 `support-matrix.json` 的插件版本是否一致，并输出 tag 的各字段 |
| `scripts/check_release_iteration.sh` | 用远端 tag 列表校验迭代序号：mod 序号必须递增、引擎 tag 的基线 mod tag 必须已存在且 `<M>` 递增；解析不出一律中止 |
| `scripts/release_plugin.sh` | 按本规范创建并推送不可变 tag，校验迭代序号，打包可复现的安装 zip |
| `scripts/package_plugin.sh` | 打包插件；接受可选归档名参数，使发布物按 tag 命名 |
| `scripts/build_wasm_template.sh` | 按 profile 编译并打包引擎模板；本地与 CI 共用同一份实现 |
| `scripts/install_engine_template.sh` | 安装引擎模板并把 profile 同步进 `support-matrix.json` |
| `.github/workflows/build-template.yml` | `engine/**` 分支推送触发，按分支名选择 profile，构建后把认证引擎回写到该分支 |
| `.github/workflows/release-plugin.yml` | 由 `v*` tag 触发，复用冒烟测试后发布 GitHub Release，发布物以 tag 命名 |

校验一律 fail-closed：tag 格式不合法、`<GodotTag>` 与内置引擎不符、迭代序号不连续、
引擎裁剪的基线 mod tag 不存在、或同名 Release 已存在，发布都会中止。

