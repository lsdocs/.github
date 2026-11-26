# Releasing

How the lsdocs repositories release, what the maintainer sets up once,
and how the first release goes. Design:
`docs/superpowers/specs/2026-11-21-release-automation-design.md`.

## How a release happens

1. Every push to `main` of a releasing repository runs its `release.yml`.
   The `release-pr` job (`lsdocs/.github`'s `release-pr.yml`) opens or
   updates the **release PR**: release-plz's version bumps and changelogs
   for the crates changed since their last release (Conventional Commits).
   It opens as a draft (`pr_draft`), so its CI is the usual checks only.
2. **Mark it ready for review when you want to release.** That runs a
   dry run of the release, the repository's `release-check.yml` (not part
   of `ci.yml`, whose path filter skips a release PR that changes only
   changelogs; it runs again on each update of the PR):
   `check-crates.yml` packages and verify-builds the crates as crates.io
   would get them, which fails until the upstream crates they need are
   published. In lsdocs, lsdocs-plugin-sdk and lsdocs-rst, it also runs
   `tag.yml`'s builds, every target, with their checks (`twine check`,
   publint and attw, the binaries' `--version`, each Lua module loaded in
   its Lua and `luarocks lint` on the rockspec). A draft cannot be merged.
3. **Merging the release PR is the authorization.** On that merge, the
   `release` job publishes the bumped crates to crates.io and pushes their
   `<crate>/v<version>` tags. On any other push it does nothing
   (`release_always = false` in `.config/release-plz.toml`).
4. Each tag runs the repository's `tag.yml`: the GitHub release (with the
   crate's changelog section; `lsdocs/.github`'s `create-release` action),
   plus, by tag:
   - `lsdocs/v*` (lsdocs): the `lsdocs` binaries for cargo-binstall
     (`build-bin.yml`), attached to the release.
   - `lsdocs-protocol/v*` (protocol): `schema.tar.gz`, which
     lsdocs.github.io's `nur docs` downloads.
   - `lsdocs-plugin-python/v*`, `lsdocs-rst-python/v*`: wheels and sdist
     (`build-wheels.yml`), published to PyPI.
   - `lsdocs-plugin-node/v*`, `lsdocs-rst-node/v*`: the napi packages
     (`build-npm.yml`), published to npm, platform packages first.
   - `lsdocs-plugin-lua/v*`, `lsdocs-rst-lua/v*`: the Lua modules, per
     target and Lua version, and the rockspec (`build-rocks.yml`),
     attached to the release like lsdocs' binaries; then the rockspec is
     uploaded to luarocks.org (it builds from the tag with cargo until
     #18's backend installs the prebuilt modules).
4. Renovate (the organization preset, `default.json` here) opens PRs in the
   repositories that depend on the released crates.

The binding crates share their wrapped crate's version (release-plz
`version_group`): `lsdocs-plugin-python`, `lsdocs-plugin-node` and
`lsdocs-plugin-lua` with `lsdocs-plugin-sdk`; `lsdocs-rst-python`,
`lsdocs-rst-node` and `lsdocs-rst-lua` with `lsdocs-rst`.

## One-time setup

### The release GitHub App

- Create a GitHub App owned by the organization. Repository permissions:
  **Contents: read and write**, **Pull requests: read and write**
  (Metadata: read is implied). No webhook.
- Install it on the 18 releasing repositories (below).
- Organization secrets, available to those repositories:
  `RELEASE_APP_CLIENT_ID` (the App's client ID, on its settings page; not
  the App ID, which `actions/create-github-app-token` deprecates) and
  `RELEASE_APP_PRIVATE_KEY` (a private key generated for it).

The workflows mint a token from it per run
(`actions/create-github-app-token`); tags and PRs made with it start other
workflows, which `GITHUB_TOKEN`'s would not.

### The `release` environment

In each releasing repository, an environment named **`release`**. Its
deployment rules: the `main` branch and tags matching `*/v*`. No required
reviewers (merging the release PR is the authorization).

Releasing repositories (18): lsdocs-doctree, lsdocs-protocol,
lsdocs-plugin-sdk, lsdocs-rst, lsdocs-markdown, lsdocs-render-html,
lsdocs-extras, lsdocs-sphinx-addons, lsdocs-transform-highlight,
lsdocs-transform-links, lsdocs-transform-nav, lsdocs-transform-toc,
lsdocs-apidoc, lsdocs-apidoc-clang, lsdocs-apidoc-python,
lsdocs-apidoc-rust, lsdocs-apidoc-typescript, lsdocs.

### Renovate

Install the Renovate GitHub App on the organization. Each repository's
`renovate.json` extends `local>lsdocs/.github` (this repository's
included). The preset groups updates: the organization's own crates and
packages in one PR (`lsdocs packages`), and third-party dependencies in
one PR per ecosystem (Rust, npm, Python), GitHub Actions and mise tools;
major updates get a group PR of their own.

### Trusted publishers

Each takes the repository (owner `lsdocs`), a workflow file name and the
environment `release`.

| Registry | Packages | Workflow |
|---|---|---|
| crates.io | every published crate of the repository (below) | `release.yml` |
| PyPI | `lsdocs-plugin` (lsdocs-plugin-sdk), `lsdocs-rst` (lsdocs-rst) | `tag.yml` |
| npm | `@lsdocs/plugin` and its seven platform packages (lsdocs-plugin-sdk); `@lsdocs/rst` and its seven (lsdocs-rst) | `tag.yml` |

Published crates: lsdocs-doctree; lsdocs-config, lsdocs-protocol;
lsdocs-plugin-sdk, lsdocs-rpc; lsdocs-rst, lsdocs-parser-rst;
lsdocs-parser-markdown; lsdocs-render-html; lsdocs-extras-plugin;
lsdocs-sphinx-addons; lsdocs-transform-highlight, -links, -nav, -toc;
lsdocs-apidoc, lsdocs-apidoc-plugin; lsdocs-apidoc-clang, -python, -rust,
-typescript; lsdocs, lsdocs-host.

npm platform packages: `-darwin-arm64`, `-darwin-x64`, `-linux-arm64-gnu`,
`-linux-x64-gnu`, `-linux-x64-musl`, `-win32-arm64-msvc`,
`-win32-x64-msvc` after `@lsdocs/plugin` and `@lsdocs/rst`
(napi's per-platform packages, one per target in `napi.targets` of
`bindings/node/package.json`; `build-npm.yml` generates them).

luarocks.org (`lsdocs-plugin`, `lsdocs-rst`) has no trusted publishing:
`tag.yml` uploads with an API key, the `release` environment's
`LUAROCKS_API_KEY` secret (kept, not deleted after the first release).
The luarocks.org account must not require 2FA for uploads.

**crates.io and npm can only add a trusted publisher to a package that
exists** ("initial publish requires an API token", crates.io's docs).
PyPI accepts a *pending* publisher for a new project. So the first release
uses a token once (next section), and the trusted publishers for crates.io
and npm are added after it.

## The first release

In dependency order (each repository depends only on earlier ones):

1. lsdocs-doctree
2. lsdocs-protocol
3. lsdocs-plugin-sdk
4. lsdocs-markdown, lsdocs-rst, lsdocs-render-html, lsdocs-transform-highlight, lsdocs-transform-links, lsdocs-transform-nav, lsdocs-transform-toc
5. lsdocs-apidoc, lsdocs-extras, lsdocs-sphinx-addons
6. lsdocs-apidoc-clang, lsdocs-apidoc-python, lsdocs-apidoc-rust, lsdocs-apidoc-typescript
7. lsdocs

For each repository, in that order:

1. **Depend on crates.io.** Every `lsdocs-*` git dependency
   (`{ git = "...", branch = "main", version = "0.1.0" }`) becomes
   `version = "0.1"` (its upstream is published by now). In
   `scripts/org.nu`: `check-git-deps` reports an `lsdocs-*` *git*
   dependency instead of requiring one; `nur link` writes
   `[patch.crates-io]` instead of `[patch."<ORG_URL>/<repo>"]`; and
   `org-env`'s `LSDOCS_ORG_DIR` switch (git `insteadOf`) is replaced by
   the same `[patch.crates-io]` entries. `nur ci` passes; merge.
   (lsdocs-doctree has no `lsdocs-*` dependencies: nothing to switch.)
2. **A token for the first publish.** In the repository's `release`
   environment, a secret `CARGO_REGISTRY_TOKEN`: a crates.io API token with
   the `publish-new` and `publish-update` scopes (crate pattern `lsdocs*`).
   For lsdocs-plugin-sdk and lsdocs-rst, also `NPM_TOKEN`: an npm granular
   token, read and write for the `@lsdocs` scope, *without* bypass-2FA
   (npm is ending direct publishing with bypass-2FA tokens, targeting
   January 2027; any token can still stage). With it, `tag.yml` stages
   each npm package (`npm stage publish`, no provenance) instead of
   publishing it. For those two, add the PyPI pending publisher now.
3. **Mark the release PR ready for review, then merge it** (it proposes the crates at 0.1.0 with their
   first changelogs). The crates are published, tagged, and `tag.yml`
   makes the releases and publishes the bindings (the npm ones staged).
   For lsdocs-plugin-sdk and lsdocs-rst, **approve the eight staged npm
   packages**: npmjs.com's Staged Packages tab, or `npm stage list` and
   `npm stage approve <id>` (both ask for 2FA). A new package name shows
   a placeholder `0.0.0-stage` version until then.
4. **Switch to trusted publishing.** Add the crates.io trusted publisher
   for each crate just published (and the npm ones), then delete
   `CARGO_REGISTRY_TOKEN` (and `NPM_TOKEN`). Without the secret, the
   workflows use trusted publishing (npm: `npm publish --provenance`).
   For npm, one command per package (npm 11.15 or later, asks for 2FA);
   for lsdocs-rst, `@lsdocs/rst` and the repository `lsdocs-rst`:
   ```nu
   [plugin plugin-darwin-arm64 plugin-darwin-x64 plugin-linux-arm64-gnu
    plugin-linux-x64-gnu plugin-linux-x64-musl plugin-win32-arm64-msvc
    plugin-win32-x64-msvc] | each {|p|
     npm trust github $"@lsdocs/($p)" --file tag.yml --repo lsdocs/lsdocs-plugin-sdk --env release --allow-publish -y
   }
   ```
   A new trusted publisher expires unless a publish uses it within two
   days; the next release's publish does, so set them up close to it, or
   check with `npm trust list <package>` after it.

## Every later release

Merge the release PR. Renovate then opens PRs in the dependent
repositories; merge those as their CI passes, and their release PRs
follow.
