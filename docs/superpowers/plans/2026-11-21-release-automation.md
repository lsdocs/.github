# Release Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merging a repository's release PR publishes its bumped crates to crates.io, tags them `<crate>/v<version>`, and builds and publishes their release artifacts (the `lsdocs` binaries, wheels, npm packages); Renovate moves dependents to new versions.

**Architecture:** Each releasing repository runs release-plz in its own `release.yml` (release PR, then publish on its merge) and a `tag.yml` on `*/v*` tags that creates the GitHub release with `gh` and publishes artifacts. `lsdocs/.github` (local clone `C:\dev\lsdocs-org`) holds reusable workflows that only build (`build-bin.yml`, `build-wheels.yml`, `build-npm.yml`) and the reusable `release-pr.yml`, plus an organization Renovate preset.

**Tech Stack:** release-plz 0.4.3, cross 0.2.5, maturin (`PyO3/maturin-action`), napi-rs CLI, uv, npm, `gh`, GitHub Actions, Renovate.

**Spec:** `C:\dev\lsdocs-org\docs\superpowers\specs\2026-11-21-release-automation-design.md`

## Global Constraints

- Branches: `feat/release-automation`, cut from an up-to-date `main`, in `lsdocs-org` and in every repository a task changes. Commit and push to it; never to `main`. Conventional Commits titles; every message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. LF line endings.
- Tags are `<crate>/v<version>` for every released crate, bindings included (`lsdocs-plugin-python/v0.1.0`).
- Actions only from `actions`, `github`, `lsdocs`, or the tool's own authors (`PyO3/maturin-action`, `jdx/mise-action`, `release-plz/action`, `rust-lang/crates-io-auth-action`, `cargo-bins/cargo-binstall`). Each action is pinned to a release's commit SHA, with a `# vX.Y.Z` comment.
- Workflows are checked with `mise exec zizmor@latest -- zizmor --config C:/dev/lsdocs-org/.github/zizmor.yml <path>` (online, `GH_TOKEN=$(gh auth token)`); not actionlint. Expected: `No findings to report.`
- GitHub releases are created, and assets uploaded, only with `gh release create` / `gh release upload`.
- Reusable workflows only build and `actions/upload-artifact`; all publishing (crates.io, PyPI, npm, release assets) is in the repository's own workflow, in the `release` environment, with `id-token: write` (trusted publishing, no registry tokens).
- Linux release builds: `cross build` (binaries, napi addons); wheels: `maturin build --zig` on Linux, except ppc64le. No WebAssembly builds.
- Binary archives contain the binary plus `LICENSE-APACHE` and `LICENSE-MIT`: `<package>-<target>.zip` on Windows, `<package>-<target>.tar.gz` elsewhere.
- Default targets (all three build workflows; the list napi already has): `x86_64-pc-windows-msvc`, `aarch64-pc-windows-msvc`, `x86_64-apple-darwin`, `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-musl`.
- `publish = false` only on: `lsdocs-gen`, `lsdocs-plugin-sdk-bindings`, `lsdocs-plugin-python`, `lsdocs-plugin-node`, `lsdocs-rst-python`, `lsdocs-rst-node`. Every other crate is published.
- Releasing repositories (18): doctree, protocol, plugin-sdk, rst, markdown, render-html, extras, sphinx-addons, transform-highlight, transform-links, transform-nav, transform-toc, apidoc, apidoc-clang, apidoc-python, apidoc-rust, apidoc-typescript, lsdocs. bench and lsdocs.github.io get none (lsdocs.github.io changes only its `schemas` task).
- `GH_TOKEN` for the GitHub App: secrets `RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY` (organization secrets, created by the maintainer).
- Nothing in this plan publishes anything or pushes a tag. The first release is Task 9's runbook, run by the maintainer after their setup.

## Review Focus

- A push to `main` that is not a release-PR merge: `release-plz release` must publish nothing and push no tag (`release_always = false`).
- A repository with several crates where one changed (plugin-sdk: only `lsdocs-rpc`): only it, its dependents in the repository, and the bindings of a bumped wrapped crate get bumped; `lsdocs-gen` and other unchanged crates keep their version and get no tag.
- A tag for a crate that has no artifacts (for example `lsdocs-host/v0.1.1`): `tag.yml` creates the release (`--latest=false`) and runs no build or publish job.
- A Windows target: the archive is a `.zip`, contains `lsdocs.exe`, and its name matches the binstall `pkg-url` override.
- The site's `schemas` task while no `lsdocs-protocol/v*` release exists: it fails with a message naming the missing release, as today's message does.

---

### Task 1: Find out how release-plz behaves (spike, no commits)

Settle the spec's "left to the builder" questions about release-plz on a scratch copy before writing config.

**Files:** a scratch copy of `C:\dev\lsdocs-plugin-sdk` in the scratchpad (not committed).

**Interfaces:**
- Produces: rulings in the ledger, read by Tasks 3 and 5. Each is one of: whether release-plz reads `.config/release-plz.toml` (else `release-plz.toml` at the root); whether it tags/changelogs `publish = false` crates and which per-package keys do it (`publish = false` + `release = true`, or `git_only`); whether a bump of `lsdocs-plugin-sdk` bumps the path-dependent binding crates on its own; the exact key for `git_tag_name` and `release_always`.

- [ ] **Step 1:** Copy the repository to the scratchpad, give each crate its own `version = "0.1.0"` (as Task 3 will), add a `release-plz.toml` with `git_tag_name = "{{ package }}/v{{ version }}"`, commit locally.
- [ ] **Step 2:** Add a `feat:` commit touching only `crates/plugin-sdk/src`, then run `mise exec release-plz@0.4.3 -- release-plz update --allow-dirty` (local; no registry writes). Expected to learn: which manifests' versions changed. Record what happened to the binding crates.
- [ ] **Step 3:** Move the config to `.config/release-plz.toml`, run again; record whether it was read (the tag template shows in `release-plz release --dry-run` output, or the config's changelog setting takes effect).
- [ ] **Step 4:** Read release-plz's docs (release-plz.dev, "Configuration") for `release_always`, `publish`, `release`, `git_only`, `git_release_enable`; record the keys. Delete the scratch copy.

### Task 2: Reusable workflows in lsdocs/.github

**Files:**
- Create: `C:\dev\lsdocs-org\.github\workflows\release-pr.yml`, `build-bin.yml`, `build-wheels.yml`, `build-npm.yml`.

**Interfaces:**
- Produces `release-pr.yml` (`workflow_call`, secrets `app-id`, `app-private-key`): checks out with the App token (`actions/create-github-app-token`, scoped to the calling repository), runs `release-plz/action` with `command: release-pr`.
- Produces `build-bin.yml` (inputs: `package` string; `targets` string, a JSON list, default the Global Constraints list). Per target: `ubuntu-latest` for `*-linux-*` (`cross build --release --locked -p <package> --target <t>`, cross installed with `mise exec cargo:cross@0.2.5`), `windows-latest` for `*-windows-*`, `macos-latest` for `*-apple-*` (`cargo build ...`). Archives per Global Constraints. Artifact name `bin-<target>`, containing one archive.
- Produces `build-wheels.yml` (inputs: `working-directory`; `targets`, same default). `PyO3/maturin-action` with `args: --release --locked --out dist` plus `--zig` on Linux targets except `powerpc64le-*`; one job builds the sdist (`command: sdist`). Artifact names `wheels-<target>`, `sdist`.
- Produces `build-npm.yml` (inputs: `working-directory`; `targets`, same default; `version` string). Per target builds the addon (`napi build --release --platform --target <t>`, with napi's cross option on Linux targets), artifact `napi-<target>` (the `.node` file). A final job runs `napi create-npm-dirs`, `napi artifacts` (moves `.node` files into `npm/<platform>/`), `npm version <version> --no-git-tag-version` in the main package and every `npm/*` package, `npm pack` each; artifact `npm-packages` (all `.tgz`).
- All four: `permissions: {}`, jobs `contents: read`, `setup-repo@main` for checkout and tools.

- [ ] **Step 1:** Write the four workflows to the interfaces above.
- [ ] **Step 2:** Run zizmor on `.github` (Global Constraints). Expected: `No findings to report.` Fix or inline-ignore (with a reason) anything at `medium` or above.
- [ ] **Step 3:** Commit `feat(ci): reusable release-pr and build workflows`, push.

### Task 3: Per-crate versions, publish flags and release-plz config (every releasing repository)

**Files (each of the 18):**
- Modify: every crate's `Cargo.toml`: `version.workspace = true` becomes `version = "0.1.0"`; drop `publish = false` except on the Global Constraints list (add it there if missing). Root `Cargo.toml`: remove `version` from `[workspace.package]`, and remove a workspace-level `publish = false` if present.
- Create: `release-plz.toml` (or `.config/release-plz.toml`, per Task 1): `[workspace]` with `git_tag_name = "{{ package }}/v{{ version }}"`, `git_release_enable = false`, `release_always = false`, `changelog_update = true`; `[[package]]` entries for the binding crates per Task 1's ruling (released and tagged, not published).
- plugin-sdk, rst: make each binding crate bump with its wrapped crate, using the mechanism Task 1 found.

- [ ] **Step 1:** In plugin-sdk, run `cargo metadata --no-deps --format-version 1` and check with a one-off script that each package's `publish` is `[]` exactly for the Global Constraints list and `null` otherwise. Expected before the change: every package `[]` (fails).
- [ ] **Step 2:** Make the changes in plugin-sdk. Re-run the check: expected pass. Run `nur ci`: expected pass.
- [ ] **Step 3:** In a scratch clone of plugin-sdk, add a `feat:` commit to `crates/plugin-sdk`, run `release-plz update`. Expected: `lsdocs-plugin-sdk`, `lsdocs-plugin-python`, `lsdocs-plugin-node` bumped to 0.1.1 (and any in-repo dependents); `lsdocs-rpc` unchanged.
- [ ] **Step 4:** Apply to the other 17 repositories. In each: the publish check passes, and `nur ci` passes.
- [ ] **Step 5:** Commit `build: per-crate versions; release-plz config` in each, push.

### Task 4: Organization Renovate preset

**Files:**
- Create: `C:\dev\lsdocs-org\default.json` (the preset).
- Create: `renovate.json` in each of the 19 lsdocs repositories plus lsdocs.github.io: `{"$schema": "https://docs.renovatebot.com/renovate-schema.json", "extends": ["local>lsdocs/.github"]}`.

**Interfaces:**
- Produces the preset: `config:recommended`, `helpers:pinGitHubActionDigests` (keeps `# vX.Y.Z` comments); `packageRules`: `lsdocs-*` crates grouped by source repository (`groupName` from the crate's repository); the mise manager enabled for `.config/mise*.toml`.

- [ ] **Step 1:** Run `npx --yes --package renovate@latest -- renovate-config-validator default.json` in `lsdocs-org`. Expected before the file exists: error; after: `Config validated successfully`.
- [ ] **Step 2:** Same validator on one repository's `renovate.json`. Expected: validated.
- [ ] **Step 3:** Commit `chore: organization Renovate preset` in lsdocs-org and `chore: Renovate from the organization preset` in each repository, push.

### Task 5: release.yml in each releasing repository

**Files:**
- Create: `.github/workflows/release.yml` in each of the 18.

**Interfaces:**
- Consumes: `release-pr.yml` (Task 2), the release-plz config (Task 3).
- Produces: on `push` to `main`, job `release-pr` calls `lsdocs/.github/.github/workflows/release-pr.yml@main` with the App secrets; job `release` (`environment: release`, `permissions: contents: write, id-token: write`) mints the App token, gets the crates.io token from `rust-lang/crates-io-auth-action`, runs `release-plz/action` with `command: release` and `CARGO_REGISTRY_TOKEN` from it. `concurrency: release-${{ github.ref }}`, `cancel-in-progress: false`.

- [ ] **Step 1:** Write it in transform-toc, run zizmor on its `.github`. Expected: no findings.
- [ ] **Step 2:** Copy to the other 17, run zizmor on each. Expected: no findings.
- [ ] **Step 3:** Commit `ci: release-plz release workflow` in each, push.

### Task 6: tag.yml, binaries and the schema release

**Files:**
- Create: `.github/workflows/tag.yml` in each of the 18.
- Modify: `C:\dev\lsdocs\crates\cli\Cargo.toml`: `[package.metadata.binstall]` with `pkg-url = "{ repo }/releases/download/{ name }/v{ version }/{ name }-{ target }{ archive-suffix }"`, `pkg-fmt = "tgz"`, `bin-dir = "{ bin }{ binary-ext }"`, and `[package.metadata.binstall.overrides.x86_64-pc-windows-msvc]` / `aarch64-pc-windows-msvc` with `pkg-fmt = "zip"`.
- Delete: `C:\dev\lsdocs-protocol\.github\workflows\release.yml`.
- Modify: `C:\dev\lsdocs.github.io\nurfile`, `def schemas`: the archive URL is the newest release whose tag starts with `lsdocs-protocol/v` (`gh api repos/lsdocs/lsdocs-protocol/releases` or `http get` on the REST API, sorted by `created_at`); with none, the error is `no lsdocs-protocol release yet: release lsdocs-protocol there (or pass --no-schema)`.

**Interfaces:**
- Consumes: `build-bin.yml` (Task 2).
- Produces `tag.yml`: on `push: tags: ["*/v*"]`. Job `release` (`contents: write`): `gh release create "$GITHUB_REF_NAME" --title "$GITHUB_REF_NAME" --notes "<the crate's CHANGELOG.md section for the version>"` with `--latest=false` unless the tag is `lsdocs/v*` in the lsdocs repository. Protocol, for `lsdocs-protocol/v*`: `tar -czf schema.tar.gz schema` and `gh release upload`. lsdocs, for `lsdocs/v*`: calls `build-bin.yml` (`package: lsdocs`), then a job downloads all `bin-*` artifacts and `gh release upload`s the archives. Tags to apply the tag filter as job `if:` conditions on `github.ref_name`, passed to shell through `env:`.

- [ ] **Step 1:** Write `tag.yml` for a single-crate repository (transform-toc), protocol and lsdocs; copy the single-crate form to the other 15. zizmor on each: expected no findings.
- [ ] **Step 2:** In lsdocs, run `cargo metadata --no-deps --format-version 1` and check `packages[name=lsdocs].metadata.binstall.pkg-url` equals the value above. Expected: equal.
- [ ] **Step 3:** In lsdocs.github.io, run `nur docs` (schemas on). Expected (no `lsdocs-protocol/v*` release exists yet): fails with the message above. `nur ci` (no schemas): passes.
- [ ] **Step 4:** Commit `ci: tag workflow creates releases and uploads artifacts` (each), `build(cli): cargo-binstall metadata` (lsdocs), `ci: schemas on lsdocs-protocol/v* releases` (protocol), `fix(docs): schemas from the newest lsdocs-protocol release` (lsdocs.github.io); push.

### Task 7: Python bindings: version from Cargo, wheels on tags

**Files:**
- Modify: `bindings/python/pyproject.toml` in plugin-sdk and rst: remove `version = "0.1.0"`, add `dynamic = ["version"]` under `[project]`.
- Modify: `tag.yml` in plugin-sdk and rst: for `lsdocs-plugin-python/v*` / `lsdocs-rst-python/v*`, call `build-wheels.yml` (`working-directory: bindings/python`), then job `publish-pypi` (`environment: release`, `id-token: write`) downloads `wheels-*` and `sdist` into `dist/` and runs `uv publish --trusted-publishing always dist/*`.

- [ ] **Step 1:** In plugin-sdk, `mise exec uv -- uvx maturin build --manifest-path bindings/python/Cargo.toml --out target/wheel-check` before the change: the wheel name has `0.1.0` from pyproject. Change the version in that crate's `Cargo.toml` to `0.1.1` temporarily, rebuild: expected still `0.1.0` (pyproject wins; RED). Revert.
- [ ] **Step 2:** Make the pyproject change. Repeat with the temporary `0.1.1`: expected wheel `lsdocs_plugin-0.1.1-*`. Revert the temporary bump. `nur test python`: expected pass.
- [ ] **Step 3:** Same in rst. zizmor on both `.github`: expected no findings.
- [ ] **Step 4:** Commit `build(python): version from Cargo.toml; wheels on release tags` in each, push.

### Task 8: Node.js bindings: napi per-platform packages on tags

**Files:**
- Modify: `bindings/node/package.json` in plugin-sdk and rst: `optionalDependencies` for each target's package (`@lsdocs/plugin-<napi platform>`, `@lsdocs/rst-<napi platform>`) at the package's version; `napi.packageName` if napi needs it for the scoped names; `files` keeps the JS sources but no longer `*.node`.
- Create: `bindings/node/npm/<platform>/package.json` for each target (`napi create-npm-dirs`; committed, versions set at release time).
- Modify: `tag.yml` in both: for `lsdocs-plugin-node/v*` / `lsdocs-rst-node/v*`, call `build-npm.yml` (`working-directory: bindings/node`, `version` from the tag), then job `publish-npm` (`environment: release`, `id-token: write`, Node from `setup-repo`) downloads `npm-packages` and runs `npm publish --provenance --access public` for each platform `.tgz`, then the main package's.

- [ ] **Step 1:** In plugin-sdk, `nur test node` before the change: expected pass (baseline).
- [ ] **Step 2:** Make the changes. `nur test node`: expected pass (local builds still load the addon from the package directory). `npm pack --dry-run` in `bindings/node`: expected no `.node` file listed; each `npm/<platform>` `npm pack --dry-run`: expected its `.node` only (after copying a locally built one in for the check).
- [ ] **Step 3:** Same in rst. zizmor on both `.github`: expected no findings.
- [ ] **Step 4:** Commit `build(node): napi per-platform packages; npm on release tags` in each, push.

### Task 9: Maintainer setup and first-release runbook

**Files:**
- Create: `C:\dev\lsdocs-org\docs\releasing.md`.

**Interfaces:**
- Consumes: everything above.
- Produces: the runbook, with these sections (content from the spec, "Maintainer setup" and "First release"):
  1. **Setup:** the GitHub App (`contents: write`, `pull-requests: write`), its installation, `RELEASE_APP_ID` / `RELEASE_APP_PRIVATE_KEY`; the `release` environment in the 18 repositories; the Renovate app.
  2. **Trusted publishers:** per registry, with the exact repository / workflow / environment for each crate and package. How the first version of a package that has to exist first is published (Task 1's or the registry docs' answer).
  3. **First release, in order** (doctree; protocol; plugin-sdk; markdown, rst, render-html, transform-*; apidoc, extras, sphinx-addons; apidoc-*; lsdocs). Per repository: switch its `lsdocs-*` dependencies from git to `version = "0.1"`, move `scripts/org.nu`'s patch entries to `[patch.crates-io]`, change `nur check-git-deps` to fail on any `lsdocs-*` git dependency, `nur ci`, merge; then merge the release PR.
  4. **Every later release:** merge the release PR; Renovate PRs follow in dependents.

- [ ] **Step 1:** Write the runbook. Check every repository, workflow, secret and environment name in it against Tasks 2-8 (`grep` each name in the repositories). Expected: every name found.
- [ ] **Step 2:** Commit `docs: release setup and first-release runbook`, push. Ask the user before opening PRs.
