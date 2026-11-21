# Release automation for the lsdocs repositories

## Intent

lsdocs is 19 repositories with 31 crates, several repositories holding more
than one crate, and two of them (plugin-sdk, rst) holding Python and Node.js
bindings that deploy to PyPI and npm. Releasing by hand (bumping versions,
pushing a tag per crate, publishing in dependency order) is too tedious at
this size. The maintainer wants to *authorize* a release and have CI do the
rest.

## Goals

- In each repository, a release PR proposes the next versions and
  changelogs (from Conventional Commits). Merging it is the authorization:
  the crates whose version changed are published to crates.io and tagged;
  crates whose version did not change are left alone.
- Tags are `<crate>/v<version>`, for every released crate, bindings included
  (the binding crate's own name, for example `lsdocs-plugin-python/v0.1.0`
  and `lsdocs-plugin-node/v0.1.0`; Claude's reading of "prefixed with the
  rust crate name").
- Released binaries (today only `lsdocs`, the CLI) are attached to the
  GitHub release as archives cargo-binstall can install: `.zip` on Windows,
  `.tar.gz` elsewhere, each with a copy of the LICENSE files.
- Binding releases build wheels and npm packages and publish them to PyPI
  and npm.
- Repositories depend on each other through crates.io versions. A
  dependent stays on the version it has until a Renovate PR moves it
  (maintainer's decision: "stay on 0.1 until a Renovate PR moves it").
- All publishing uses trusted publishing (OIDC); no registry tokens in
  secrets.

## Non-goals

- The exact target platforms and architectures (decided along the way; the
  build workflows take them as inputs).
- Docs-site or Pages deployment changes.

## Anti-goals

- The maintainer pushing tags or bumping versions by hand for a normal
  release.
- A long-lived personal access token doing the tagging.
- Actions from owners other than GitHub (`actions`, `github`), `lsdocs`, or
  the authors of the tool used (for example `PyO3/maturin-action`,
  `jdx/mise-action`, `release-plz/action`, `rust-lang/crates-io-auth-action`).

## Constraints (maintainer's rules)

- Workflows are checked with zizmor (not actionlint), using
  `lsdocs/.github`'s `.github/zizmor.yml`.
- Every action is pinned to the commit SHA of a release, with a
  `# vX.Y.Z` comment.
- GitHub releases are created, and assets uploaded, with the `gh` CLI.
- Reusable workflows (in `lsdocs/.github`) only **build** release artifacts
  and upload them as CI artifacts. Publishing happens in each repository's
  own workflow, because trusted publishers are bound to the calling
  repository's workflow file (PyPI does not accept a reusable workflow as
  the publisher).
- maturin builds Linux wheels with `--zig`, except on ppc64le.
- Other release builds for Linux targets (the `lsdocs` binaries and the
  napi addons) use cross (cross-rs), for older-glibc compatibility. cross
  is installed as a tool (mise or cargo-binstall), not through a
  third-party action.
- No WebAssembly build of the Node.js bindings (for now).
- Who may publish: `publish = false` stays only on the binding crates and
  dev tooling; every other crate drops it. Crate names were checked on
  crates.io (none taken).

## Approaches considered

1. **release-plz per repository, reusable build workflows in
   `lsdocs/.github`, an organization Renovate preset.** Chosen: release-plz
   publishes only the crates whose version is not yet on crates.io, handles
   multi-crate workspaces and their internal dependencies, and names tags
   from a template.
2. release-please: bumps `package.json`/`pyproject.toml` itself, but does
   not publish to crates.io or check what is already published, and is
   weaker with Cargo workspaces.
3. cargo-release from a manual workflow: no release PR, and someone has to
   start each release.

## Design

### Which crates publish

| Repository | crates.io | `publish = false` |
|---|---|---|
| doctree | lsdocs-doctree | |
| protocol | lsdocs-config, lsdocs-protocol | lsdocs-gen (dev tooling) |
| plugin-sdk | lsdocs-plugin-sdk, lsdocs-rpc | lsdocs-plugin-sdk-bindings, lsdocs-plugin-python, lsdocs-plugin-node |
| rst | lsdocs-rst, lsdocs-parser-rst | lsdocs-rst-python, lsdocs-rst-node |
| markdown, render-html, extras, sphinx-addons, transform-highlight, transform-links, transform-nav, transform-toc | their one crate | |
| apidoc | lsdocs-apidoc, lsdocs-apidoc-plugin | |
| apidoc-clang, apidoc-python, apidoc-rust, apidoc-typescript | their one crate | |
| lsdocs | lsdocs, lsdocs-host | |

`lsdocs-plugin-sdk-bindings` stays unpublished: only the (unpublished)
binding crates use it (Claude's call). bench and lsdocs.github.io have no
crates and get no release workflow.

### Versions

Each crate has its own version (the maintainer's "the binding crates that
have their own versions"): every crate manifest replaces
`version.workspace = true` with its own `version = "0.1.0"`, and
`[workspace.package]` drops `version`. release-plz then bumps only the
crates that changed. A binding crate is bumped whenever the crate it
wraps is bumped (maintainer's decision): `lsdocs-plugin-python` and
`lsdocs-plugin-node` with `lsdocs-plugin-sdk`, `lsdocs-rst-python` and
`lsdocs-rst-node` with `lsdocs-rst`. If release-plz does not bump them on
its own (they depend on the wrapped crate by path), its configuration or
the binding crates' dependency requirements must make it.

### Dependencies between repositories

Every `lsdocs-*` dependency changes from `{ git = ..., branch = "main",
version = "0.1.0" }` to a crates.io requirement (`version = "0.1"`), once
the crate it names is published. Local development against sibling clones
(`LSDOCS_ORG_DIR`, `org org-env` / `patch-entries` in `scripts/org.nu`)
moves its `[patch]` table to `[patch.crates-io]`. `nur check-git-deps`
becomes a check that no `lsdocs-*` dependency is a git dependency.

### release-plz in each repository

`release-plz.toml` at the root (or `.config/`, if release-plz reads it
there):

- `git_tag_name = "{{ package }}/v{{ version }}"`, per-package changelogs
  (`CHANGELOG.md` beside each crate).
- `git_release_enable = false`: releases are created with `gh` by the tag
  workflow (below).
- `release_always = false`: `release-plz release` publishes and tags only
  when the pushed commit is a merged release PR, so merging the release PR
  is the one authorization; the `release` environment needs no required
  reviewer (Claude's call). The first release goes the same way: the first
  release PR proposes the crates at 0.1.0 with their changelogs.
- The binding crates: released (bumped, changelog, tagged) but not
  published to crates.io.

`.github/workflows/release.yml` in each releasing repository, on `push` to
`main`:

- **release-pr** job: mints a GitHub App token
  (`actions/create-github-app-token`), runs `release-plz release-pr`. This
  job may be a reusable workflow in `lsdocs/.github` (it publishes
  nothing).
- **release** job, in the `release` environment, `id-token: write`: mints
  the App token and a crates.io token (`rust-lang/crates-io-auth-action`),
  runs `release-plz release` (publishes the crates whose version is not on
  crates.io, pushes their tags).

### Tags trigger the artifacts

Tags pushed with the App token trigger workflows (tags pushed with
`GITHUB_TOKEN` would not). In the releasing repository,
`.github/workflows/tag.yml`, on `push: tags: ["*/v*"]`:

- Creates the GitHub release for the tag with `gh release create`, notes
  from the crate's changelog section, `--latest=false` except for
  `lsdocs/v*` in the lsdocs repository (so "latest" there is the CLI;
  Claude's call).
- For `lsdocs-protocol/v*` (protocol repository): attaches
  `schema.tar.gz`, replacing today's `release.yml` (removed).
  lsdocs.github.io's `schemas` task looks up the newest
  `lsdocs-protocol/v*` release through the GitHub API instead of
  `releases/latest` (Claude's call).
- For `lsdocs/v*` (lsdocs repository): calls `lsdocs/.github`'s
  `build-bin.yml`, downloads its artifacts, `gh release upload`s them.
- For a binding crate's tag (plugin-sdk, rst): calls `build-wheels.yml` or
  `build-npm.yml`, downloads the artifacts, publishes in the `release`
  environment: `uv publish` (trusted publishing) for wheels and the sdist,
  `npm publish --provenance` (trusted publishing) for the npm packages.

### Reusable build workflows (`lsdocs/.github/.github/workflows/`)

All `workflow_call`, `permissions: {}` with `contents: read` per job, using
`setup-repo`; each uploads with `actions/upload-artifact`.

- `build-bin.yml`, inputs `package` and `targets` (JSON list of
  `{target, os}`). Builds `cargo build --release --locked -p <package>
  --target <target>` (`cross build` for Linux targets), then archives the binary with `LICENSE-APACHE` and
  `LICENSE-MIT`: `<package>-<target>.zip` on Windows,
  `<package>-<target>.tar.gz` elsewhere.
- `build-wheels.yml`, inputs `working-directory` (the Python package) and
  `targets`. `PyO3/maturin-action` builds wheels (`--zig` on Linux except
  ppc64le) and an sdist. The version comes from `Cargo.toml` (the Python
  package's `pyproject.toml` declares `dynamic = ["version"]`).
- `build-npm.yml`, inputs `working-directory` (the Node package) and
  `targets`. Uses napi-rs' usual layout (maintainer's decision): the main
  package (`@lsdocs/plugin`, `@lsdocs/rst`) plus one package per platform
  (for example `@lsdocs/plugin-win32-x64-msvc`) under `npm/`, which the
  main package lists as `optionalDependencies` (napi's `create-npm-dirs`
  and `prepublish` conventions). Builds the addon per target (cross for
  Linux targets), sets every package's version from the binding crate's
  `Cargo.toml` (`npm version <v> --no-git-tag-version`), and packs each
  package (`npm pack`). The publishing job publishes the platform packages
  first, then the main package.

### cargo-binstall

`lsdocs`' `Cargo.toml` gets `[package.metadata.binstall]` with a `pkg-url`
matching the tag and archive names
(`{ repo }/releases/download/{ name }/v{ version }/{ name }-{ target }{ archive-suffix }`),
`pkg-fmt = "tgz"` and an override for Windows targets to `zip`.

### Renovate

An organization preset in `lsdocs/.github` (`default.json`), which each
repository's `renovate.json` extends (`"extends": ["local>lsdocs/.github"]`):

- Cargo: one PR per upstream release of `lsdocs-*` crates, grouped by
  upstream repository.
- GitHub Actions: keeps SHA pins with their `# vX.Y.Z` comments.
- mise: the tool versions in `.config/mise*.toml`.

The Renovate GitHub App is installed on the organization by the maintainer.

### Maintainer setup (when the time comes)

- A GitHub App for releases (`contents: write`, `pull-requests: write`),
  installed on the releasing repositories; its ID and private key as
  organization secrets.
- A `release` environment in the 18 releasing repositories: doctree,
  protocol, plugin-sdk, rst, markdown, render-html, extras, sphinx-addons,
  transform-highlight, transform-links, transform-nav, transform-toc,
  apidoc, apidoc-clang, apidoc-python, apidoc-rust, apidoc-typescript,
  lsdocs.
- Trusted publishers: crates.io for every published crate (repository,
  `release.yml`, environment `release`); PyPI for `lsdocs-plugin` and
  `lsdocs-rst`; npm for `@lsdocs/plugin`, `@lsdocs/rst` and each of their
  per-platform packages (`tag.yml`, environment `release`). The maintainer
  owns the `@lsdocs` npm scope; the PyPI names and the npm package names
  are free (checked 2026-11-21).
- The Renovate app on the organization.

### First release (bootstrap)

In dependency order, the order the CI PRs were merged in: doctree;
protocol; plugin-sdk; markdown, rst, render-html, transform-*; apidoc,
extras, sphinx-addons; apidoc-*; lsdocs. Each repository switches its
`lsdocs-*` dependencies to crates.io versions once those are published,
then releases.

## Left to the builder

- Whether crates.io and npm trusted publishing can be set up before a
  package exists (PyPI has "pending publishers"); if not, how the first
  version of each package is published.
- Whether release-plz tags and changelogs `publish = false` crates, and the
  config that makes it do so for the binding crates only.
- Whether release-plz reads its config from `.config/`.
- Whether GitHub release download URLs work with `/` in the tag name, and
  the binstall `pkg-url` that matches.
- napi's flag for building with cross (and that it works for each target).
- The default `targets` lists.
