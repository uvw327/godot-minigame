# Release process

Godot Mini Game releases are built from immutable Git tags. The tag workflow
runs the complete JavaScript, GDScript, WeChat, Douyin, and TikTok export matrix before
it is allowed to publish GitHub Release assets.

## 1. Choose and apply the version

Releases are tagged with the scheme defined in
[SLIM_GODOT_ENGINE.md](SLIM_GODOT_ENGINE.md):

- `v<GodotTag>.mod.<N>` — a plugin release, for example
  `v4.7.2-stable.mod.1`
- `v<GodotTag>.mod.<N>-engine.<name>.<M>` — an engine cut, for example
  `v4.7.2-stable.mod.1-engine.minigame.1`

`<GodotTag>` is the official Godot tag the release targets and must match the
Godot version the bundled certified engine actually ships. The mod iteration
`<N>` starts at 1 and increments on every release; it resets to 1 when the
Godot version changes. The plugin version is a separate axis: it lives in
`plugin.cfg` and is reported as `pluginVersion` in the release notes.

Never move or reuse an existing tag, including a tag whose workflow failed.

Update the plugin version in all release-facing sources:

- `addons/godot_mini_game/plugin.cfg`
- `support-matrix.json`
- `website/package.json`
- the root package version entries in `website/package-lock.json`
- the compatibility rows in `README.md` and `README_zh.md`

Then regenerate derived website data:

```bash
cd website
npm run generate:data
cd ..
```

`support-matrix.json` is authoritative for the project-validated Godot, Emscripten,
profile, target, revision, ABI, and schema tuple. Do not publish a version when
the bundled `addons/godot_mini_game/engine/template.json` disagrees with that
tuple.

Per-platform validation lives under `platformContracts`. A certified row's
`platforms.* = automated` value means the exporter smoke job is generated; it
does **not** mean the package has passed platform DevTools or a real device.

## 2. Validate the exact release source

Run the project contracts and website checks:

```bash
./scripts/test.sh

NEXT_PUBLIC_BASE_PATH=/godot_for_minigame npm --prefix website test
./scripts/package_plugin.sh
```

The test runner requires Node.js 22+ and the exact Godot editor listed in
`support-matrix.json`. Set `NODE_BIN` or `GODOT_BIN` when they are not on PATH.
It runs GDScript tests in a temporary project with the committed Web preset,
without replacing a developer's `export_presets.cfg`. JavaScript-only checks
can also run directly with `node --test test/*.test.mjs` on a fresh checkout.

TikTok Native is a beta target with an additional release gate. Export a fresh
TikTok package from the release candidate, then:

1. complete `ttmg setup`/`ttmg login`, run `ttmg init` inside the fresh export
   with its Client Key, then compile/debug it through `ttmg dev` using the
   pinned version declared in `support-matrix.json` (currently
   `0.4.1-beta.wasm1`), and require CI's
   offline package precheck through `ttmg-pack.checkPkgs` to pass; Native
   `ttmg build` is currently a placeholder and is not a release gate;
2. run it on a TikTok client 43.4.0 or newer;
3. verify boot, `TTWebAssembly`, both generated subpackages, input, audio,
   networking, persistence, and login;
4. record the DevTool and device evidence with the release notes.

The TikTok HTML runtime is outside the v0.3 release scope. Do not substitute an
HTML preview for the Native DevTool and real-device gate.

When the engine template changes, also validate the original artifact produced
locally or by **Build Mini-Game WASM Template**:

```bash
./scripts/verify_wasm_template.sh /absolute/path/to/template-bundle.zip
```

The verifier accepts a ZIP or directory containing exactly `template.json`,
`version.txt`, `godot.js`, `godot.wasm.br`, and `GODOT_COPYRIGHT.txt`.

Commit the complete release source, push `mod`, and wait for **Smoke Test
Export** to succeed.

## 3. Land engine changes before the tag

A `v*` tag only packages the engine that is already committed; it never rebuilds
the template. If anything under `addons/godot_mini_game/engine/` changed:

1. push the change to an `engine/**` branch;
2. wait for **Build Mini-Game WASM Template** to finish and its
   `sync-engine-files` job to commit the certified bundle back;
3. merge that commit into `mod` and let **Smoke Test Export** pass;
4. only then create the tag.

Never tag a revision whose engine bundle has not been rebuilt and verified. A tag
created too early publishes the previous bundle under the new version number. The
downloaded bundle is a temporary build input and must not be committed; CI deletes
`engine-bundle/` before write-back.

引擎有变更时，`v*` tag 只打包仓库里现有的引擎，不会重建模板。因此必须先推到
`engine/**` 分支触发构建，等回写 job 提交认证 bundle，合入 `mod` 并让
**Smoke Test Export** 通过，最后才创建 tag。提前打 tag 会把旧引擎套上新版本号。
下载的 bundle 只是临时构建输入，不得提交；CI 在回写前会删除 `engine-bundle/`。

## 4. Create the immutable tag

With a clean working tree on the tested `mod` commit, run:

```bash
./scripts/release_plugin.sh v4.7.2-stable.mod.1
```

The script validates the tag shape, the Godot version the bundled engine
ships, the plugin version agreement between `plugin.cfg` and
`support-matrix.json`, and the iteration sequence. It then rebuilds the
reproducible install ZIP, refuses existing local or remote tags, and pushes
the tag. It does not upload assets itself.

The tag-triggered **Release Plugin** workflow reruns the full export matrix,
verifies the ZIP and checksum, refuses an existing Release, and publishes:

- `godot_mini_game_v4.7.2-stable.mod.1.zip`
- `godot_mini_game_v4.7.2-stable.mod.1.zip.sha256`

## 5. Verify the published result

Confirm that the Release is neither a draft nor prerelease, both assets exist,
and the uploaded ZIP digest matches the local reproducible package. Finally,
open the public homepage and API reference to verify that they point to the new
release.

If a tag workflow fails before creating a Release, fix the cause on `mod` and
publish a new mod iteration. Do not delete or retarget the failed tag.
