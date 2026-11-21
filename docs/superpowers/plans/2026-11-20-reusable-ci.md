# Reusable CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every lsdocs repository's CI calls reusable `ci`/`msrv`/`deny` workflows from `lsdocs/.github`, and each job installs only what it runs.

**Architecture:** `lsdocs/.github` (local clone `C:\dev\lsdocs-org`) holds the composite action `setup-repo` and three `workflow_call` workflows, each running one nur task. Each repository's mise config shrinks to nur (plus uv, Node.js, Python where bindings are built). Each task fetches its own extra tools: `nur deny` through `MISE_ENV=deny`, the nightly through rustup.

**Tech Stack:** GitHub Actions (reusable workflows, composite action), mise 2026.11, nur 0.32.0 (nushell), cargo-deny 0.21.0, rustup.

**Spec:** `docs/superpowers/specs/2026-11-20-reusable-ci-design.md` (this repository).

## Global Constraints

- Repositories: the 18 `C:\dev\lsdocs-*` clones (not `lsdocs-legacy-attempt`, not `lsdocs-org`) and `C:\dev\lsdocs`.
- Branches: `lsdocs-org` on `setup-reusable-ci`; `lsdocs` on `update-ci`; every `lsdocs-*` on `chore/tooling-configs`. Commit and push to those branches; never to `main`.
- Commit titles: Conventional Commits, `type(scope): summary`; end each message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- LF line endings in every written file.
- Actions are pinned by full commit SHA with a `# vX.Y.Z` comment, as `setup-repo` does today.
- Versions: `"cargo:nur" = "0.32.0"`, `"cargo:cargo-deny" = "0.21.0"`, `uv = "0.13.9"`, Node.js `26`, Python `3.15`. The nightly is the `NIGHTLY` constant in `lsdocs-apidoc-rust/crates/apidoc-rust/src/lib.rs` (`nightly-2026-11-14`).
- Callers reference `lsdocs/.github/.github/workflows/<name>.yml@setup-reusable-ci` and `lsdocs/.github/.github/setup-repo@setup-reusable-ci` until that branch merges.
- No nushell entry in any mise config.
- Opening pull requests is outward-facing: ask the user before opening any.

## Review Focus

- Windows and macOS runners: `nur` from mise is on `PATH` for later `run:` steps (default shell `pwsh` on Windows). Expect `nur ci` to run on all three OSes.
- mise in CI loads the repository's `[settings]` entry without an interactive trust prompt. Expect no "config not trusted" error, and Node.js from `.node-version` available in plugin-sdk's `ci` job.
- `msrv` and `deny` in a repository with `.node-version` (plugin-sdk): expect mise to install only nur, with no Node.js or Python in the job log.
- `nur deny` from a plain shell where mise isn't activated (only `mise` on `PATH`): expect cargo-deny to be installed on first use, then `advisories ok, bans ok, licenses ok, sources ok`.
- `nur test` in apidoc-rust or lsdocs on a machine without the nightly: expect the task to install it, then run the tests; on a machine with it, no reinstall.

---

### Task 1: setup-repo input and the three reusable workflows (lsdocs-org)

**Files:**
- Modify: `C:\dev\lsdocs-org\.github\setup-repo\action.yml`
- Create: `C:\dev\lsdocs-org\.github\workflows\ci.yml`, `msrv.yml`, `deny.yml`

**Interfaces:**
- Produces: `setup-repo` input `mise-install-args` (string, default `""`), passed to `jdx/mise-action`'s `install_args`. The step also sets `MISE_TRUSTED_CONFIG_PATHS: ${{ github.workspace }}`.
- Produces: `ci.yml` (`workflow_call` inputs: `os`, a string holding a JSON list, default `'["ubuntu-latest", "windows-latest", "macos-latest"]'`; `apt-packages`, a string, default `""`). Job `ci`, `name: ci (${{ matrix.os }})`, `fail-fast: false`. When `runner.os == 'Linux'` and `apt-packages != ''`, it runs `sudo apt-get update && sudo apt-get install -y <apt-packages>` before setup. It ends with `run: nur ci`.
- Produces: `msrv.yml` and `deny.yml`, both `workflow_call` with no inputs, on `ubuntu-latest`. `setup-repo` gets `mise-install-args: cargo:nur`, then `nur msrv` / `nur deny` runs.
- All three: top-level `permissions: {}`, job-level `permissions: contents: read`, `env: CARGO_TERM_COLOR: always`. Pass `apt-packages` to the shell through `env:`, never by interpolating it into `run:`, so zizmor's template-injection check passes.

- [ ] **Step 1:** Lint the current state, to confirm the tools run: `mise exec actionlint@1.7.12 zizmor@latest -- actionlint .github/setup-repo/action.yml` (from `C:\dev\lsdocs-org`). Expected: it runs (actionlint may report nothing for an action file).
- [ ] **Step 2:** Add the input and env to `setup-repo`, and write the three workflows to the interfaces above.
- [ ] **Step 3:** Run `mise exec actionlint@1.7.12 -- actionlint .github/workflows/*.yml` and `mise exec zizmor@latest -- zizmor .github`. Expected: no errors. zizmor findings at `medium` and above are fixed, or ignored inline with a reason, as `setup-repo` does for cache-poisoning.
- [ ] **Step 4:** Commit `feat(ci): reusable ci, msrv and deny workflows` and push `setup-reusable-ci`.

### Task 2: mise down to nur, `nur deny` through `MISE_ENV=deny` (every repository)

**Files (each repository):**
- Modify: `.config/mise.toml`: `[tools]` keeps `"cargo:nur" = "0.32.0"`. Remove nushell and cargo-deny. Keep `uv` only in plugin-sdk and rst (removed from lsdocs, lsdocs-apidoc and lsdocs-apidoc-rust: their nurfiles and tests do not call uv; `no_sdk_plugin.rs` runs `python3`/`python` directly).
- Create: `.config/mise.deny.toml` with `[tools] "cargo:cargo-deny" = "0.21.0"` and a comment: `# Tools for \`nur deny\` (it sets MISE_ENV=deny).`
- Modify: `nurfile`, `def "nur deny"`: body `with-env ((org org-env) | insert MISE_ENV deny) { ^mise exec -- cargo deny check }`. Keep the repository's existing comment, updated to say that mise installs cargo-deny on first use. If a repository's nurfile has no `org org-env`, use the env its `cargo-org` uses.
- Modify: `AGENTS.md`: `see \`mise.toml\`` becomes `see \`.config/mise.toml\``. The line about nushell scripts stays.

- [ ] **Step 1:** In `C:\dev\lsdocs-transform-toc`, make the three changes. Run `mise ls --current`: expected `cargo:nur` only (plus whatever the user's global config adds). Run `nur deny`: expected `advisories ok, bans ok, licenses ok, sources ok` (a syn duplicate warning is expected until plugin-sdk merges).
- [ ] **Step 2:** Apply the same changes to the other 18 repositories. In each, run `nur deny`: expected all four `ok`. Run `nur --list`: expected no parse error.
- [ ] **Step 3:** Commit in each repository, `chore(dev): mise installs only nur; nur deny brings cargo-deny`, and push.

### Task 3: Node.js and Python from version files (plugin-sdk, rst, render-html)

**Files:**
- Create: `.node-version` (`26`) in plugin-sdk, rst and render-html; `.python-version` (`3.15`) in plugin-sdk and rst.
- Modify: `.config/mise.toml` in those three: `[settings] idiomatic_version_file_enable_tools = ["node", "python"]` in plugin-sdk and rst, `["node"]` in render-html.
- Modify: `lsdocs-render-html/nurfile`, `def node-env`; `lsdocs-plugin-sdk/scripts/bindings.nu` and `lsdocs-rst/scripts/bindings.nu`, their fnm `node-env`. Each becomes: if `node` is on `PATH`, return `{}`; otherwise return the env from `mise env --json`, with its `PATH` joined by `(char esep)` (nur does not convert a list-valued `PATH`, as the current comment says). The error message becomes `Node.js not found: run \`mise install\``.
- Modify: those repositories' `AGENTS.md`, replacing fnm instructions with mise.

- [ ] **Step 1:** In plugin-sdk, run `mise install`, then `mise ls --current`. Expected: node 26.x and python 3.15.x listed, not missing.
- [ ] **Step 2:** Make the `node-env` change. From a shell without mise activated, run `nur test node`: expected pass. Run `nur test python`: expected pass.
- [ ] **Step 3:** Same in rst (`nur test node`, `nur test python`) and render-html (`nur test theme`). Expected: pass.
- [ ] **Step 4:** Commit in each, `chore(dev): Node.js and Python from version files through mise`, and push.

### Task 4: the nightly from the tasks (apidoc-rust, lsdocs)

**Files:**
- Modify: `lsdocs-apidoc-rust/.config/mise.toml`: remove the `[hooks]` table.
- Modify: `lsdocs-apidoc-rust/nurfile` and `lsdocs/nurfile`: add `def nightly []: nothing -> nothing`. It finds `lsdocs-apidoc-rust`'s `manifest_path` in `cargo-org metadata --format-version 1` (in lsdocs that is the git checkout, so the version cannot drift). It reads `src/lib.rs` beside that manifest and parses `pub const NIGHTLY: &str = "..."`, then runs `rustup toolchain install <it> --profile minimal --no-self-update`. `nur test` calls `nightly` first. If `NIGHTLY` is `""`, `nightly` does nothing.
- Modify: `lsdocs-apidoc-rust/.github/workflows/ci.yml` and `lsdocs/.github/workflows/ci.yml`: these are rewritten in Task 5, which leaves out the nightly step.

- [ ] **Step 1:** In apidoc-rust, run `nur test`. Expected: rustup reports that `nightly-2026-11-14` is unchanged or installed, then the tests pass.
- [ ] **Step 2:** Same in lsdocs (`nur test`). Expected: pass.
- [ ] **Step 3:** Commit `chore(dev): nur test installs the nightly apidoc-rust runs` in both, and push.

### Task 5: callers (every repository's `ci.yml`)

**Files:**
- Modify: `.github/workflows/ci.yml` in each repository, to the caller shape in the spec. `ci`, `msrv` and `deny` call the three workflows `@setup-reusable-ci`, each with job-level `permissions: contents: read`, and the file sets top-level `permissions: {}`.
  - apidoc-clang and lsdocs: `ci` passes `with: apt-packages: libclang-dev`.
  - bench: `ci` only.
  - lsdocs: keeps its `core` job as it is, using `setup-repo` directly.
  - The repositories still on `actions/checkout@v4` / `Swatinem/rust-cache@v2` / `jdx/mise-action@v2` lose those steps (setup-repo does them).

- [ ] **Step 1:** Rewrite each `ci.yml`. Run `mise exec actionlint@1.7.12 -- actionlint` in each repository: expected no errors. Run `mise exec zizmor@latest -- zizmor .github`: expected no findings at `medium` and above.
- [ ] **Step 2:** Commit `ci: call the organization's reusable workflows` in each, and push.
- [ ] **Step 3:** Ask the user whether to open a draft PR to `main` for one repository (transform-toc), and for plugin-sdk (Node.js and Python), to see the workflows run. If they agree, check the Review Focus items in those runs' logs. Report each job's result and any failure with its log lines.
