# Reusable CI workflows for the lsdocs repositories

## Intent

The lsdocs repositories (the 18 `lsdocs-*` repositories and `lsdocs`) each
carry a near-identical `ci.yml`, and every job installs every tool in the
repository's mise config, whether the job uses it or not (the `deny` job
installs nushell, uv and Node.js; apidoc-rust's `postinstall` hook installs
a nightly toolchain in every job). This work:

1. moves the shared CI jobs into reusable workflows in this repository
   (`lsdocs/.github`), which each repository's `ci.yml` calls, and
2. trims each repository's mise config to what every job needs, with
   each nur task fetching its own extra tools through mise.

The Python, Node.js and Rust-binary build workflows come next and should
fit the same pattern; they are not part of this work.

## Goals

- A repository's `ci.yml` is a short list of calls to reusable workflows,
  plus any job of its own (lsdocs' `core`).
- A plain `mise install` in any repository installs nur, plus uv in the
  repositories that build Python bindings, plus Node.js/Python where a
  version file asks for them. Nothing else.
- Each CI job installs only what it runs.
- Tool versions live in mise files, so automated upgrades (Renovate's
  mise manager, `mise upgrade`) can find them.

## Non-goals

- Python, Node.js and binary build/release workflows (next task).
- Coverage (`nur test cov`, later; it will set `MISE_ENV=cov` itself).
- Setting up Renovate or Dependabot.
- `pages.yml` and `release.yml` in the repositories: unchanged.

## Anti-goals

- A developer having to set `MISE_ENV` for everyday work: tasks set it.
- A shared workflow that grows an input for every repository's quirk.

## Approaches considered

1. **One reusable workflow per job** (`ci.yml`, `msrv.yml`, `deny.yml`);
   each repository calls the ones it wants. Small inputs per workflow;
   callers about 15 lines. **Chosen**: each workflow stays obvious,
   repositories that differ call fewer of them, and the build workflows
   can be added beside them the same way.
2. One workflow with all three jobs and `msrv`/`deny` switches. Shorter
   callers, but every difference becomes another input on one file.
3. A generic "run a nur task" workflow. Most flexible, but every caller
   repeats its matrix; barely shorter than today.

## Design

### Tooling in each repository

- `.config/mise.toml`:
  - `[tools]`: `"cargo:nur"`. nushell is dropped (nur bundles it). `uv`
    only in **lsdocs-plugin-sdk** and **lsdocs-rst** (the two that build
    Python bindings).
  - In repositories with a `.node-version` or `.python-version`:
    `[settings] idiomatic_version_file_enable_tools = ["node", "python"]`
    (only the tools that have a file).
- `.node-version` at the root of plugin-sdk, rst (both bindings) and
  render-html (the theme's TypeScript). Node.js 26, as mise has today.
- `.python-version` at the root of plugin-sdk and rst: `3.15`, what their
  local venvs use today.
- `.config/mise.deny.toml`: `[tools] "cargo:cargo-deny" = "0.21.0"`.
  `nur deny` runs cargo-deny with `MISE_ENV=deny`; `mise exec` installs it
  on first use (checked with mise 2026.11.9).
- `nur msrv` already installs its toolchains with rustup; unchanged.
- apidoc-rust: the nightly moves out of mise's `postinstall` hook into
  the nur tasks that need it (`rustup toolchain install nightly-... --profile
  minimal`, as `nur msrv` does); the CI step that installs it goes away.
  lsdocs does the same (its docs site and tests run apidoc-rust), so its
  `ci` job needs no extra step either (Claude's call). The `pages.yml`
  workflows that install the nightly stay as they are.
- uv is removed from lsdocs, lsdocs-apidoc and lsdocs-apidoc-rust, whose
  nurfiles do not call it, unless a test there turns out to run Python
  through it (check before removing).
- Node tasks (`node-env` in render-html, `bindings` in plugin-sdk and rst)
  stop looking for fnm and use the Node.js mise provides.

### `setup-repo` (this repository, `.github/setup-repo/action.yml`)

Keeps what it does (checkout, Rust from `rust-toolchain.toml`, cargo
cache, cargo-binstall, mise). New input:

- `mise-install-args` (default empty: install everything mise's config
  names), passed to `jdx/mise-action`'s `install_args`. `msrv` and `deny`
  pass `cargo:nur`, so they skip Node.js, Python and uv.

### Reusable workflows (this repository, `.github/workflows/`)

All `on: workflow_call`, `CARGO_TERM_COLOR: always`, jobs with
`permissions: contents: read`, each using `setup-repo` and running one nur
task.

| Workflow | Job | Inputs | Runs |
|---|---|---|---|
| `ci.yml` | matrix over `os` | `os` (JSON list, default the three: ubuntu, windows, macos), `apt-packages` (string, installed on Linux before setup; default empty) | `nur ci` |
| `msrv.yml` | ubuntu | none | `nur msrv` |
| `deny.yml` | ubuntu | none | `nur deny` |

### Callers

Each repository's `.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
permissions: {}
jobs:
  ci:
    uses: lsdocs/.github/.github/workflows/ci.yml@main
    permissions:
      contents: read
  msrv:
    uses: lsdocs/.github/.github/workflows/msrv.yml@main
    permissions:
      contents: read
  deny:
    uses: lsdocs/.github/.github/workflows/deny.yml@main
    permissions:
      contents: read
```

- apidoc-clang and lsdocs pass `apt-packages: libclang-dev`.
- bench calls only `ci.yml`.
- lsdocs keeps its own `core` job, using `setup-repo` directly.
- While the workflows are on the `setup-reusable-ci` branch, callers use
  that ref (as lsdocs does now); they switch to `@main` once it merges.

## Where the work lands

- This repository: branch `setup-reusable-ci` (already in progress).
- `lsdocs`: branch `update-ci`; the `lsdocs-*` repositories: branch
  `chore/tooling-configs`. Conventional Commits titles.

## Left to the builder

- Whether mise in CI needs the repository's config trusted for the
  `[settings]` entry (`MISE_TRUSTED_CONFIG_PATHS` or `mise trust` in
  `setup-repo`).
- How `nur deny` hands cargo-deny to `cargo-org` (an external `mise exec`
  cannot run a nu `def`; for example `mise which` under `MISE_ENV=deny`,
  or adding mise's bin path to `PATH` inside the task).
- Linting the workflows (actionlint, zizmor) where those tools are
  available.
- How to see the workflows run before merging (CI triggers only on
  `main` and pull requests to it; a draft PR or a temporary
  `workflow_dispatch` works).
