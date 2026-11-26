# luarocks-build-lsdocs-prebuilt

A LuaRocks build backend (`build.type = "lsdocs-prebuilt"`) for Lua modules
written in Rust with [mlua]. It installs the prebuilt module that this
repository's `build-rocks.yml` made for the user's Lua and platform,
attached to the binding's GitHub release, and builds from source with
[luarocks-build-rust-mlua] otherwise. One rockspec on luarocks.org serves
Lua 5.4, LuaJIT and every platform. (Binary rocks would not: they are
named by platform only, so a 5.4 and a LuaJIT build would collide.)

Used by the Lua bindings of lsdocs-plugin-sdk (`lsdocs-plugin`) and
lsdocs-rst (`lsdocs-rst`).

## What it does

At `luarocks install`:

1. Asks the target interpreter (LuaRocks' `variables.LUA`) what it is:
   `lua54` (Lua 5.4), `luajit` (`jit` is set), or anything else (no
   prebuilt module).
2. Maps LuaRocks' platform and CPU to a Rust target: `x86_64` or `aarch64`
   with `-unknown-linux-gnu`, `-apple-darwin` or `-pc-windows-msvc`.
3. Downloads `<module>-<version>-<lua>-<target>.tar.gz` from `build.url`
   (LuaRocks' own downloader) and checks its SHA-256 against
   `build.sha256["<lua>-<target>"]` with `sha256sum`, `shasum`, `openssl`
   or `certutil`. **A mismatch fails the install.**
4. Loads the module in the target interpreter. One that does not load (an
   older glibc, musl, a Windows Lua whose DLL is not `lua54.dll` or
   `lua51.dll`) is not installed.
5. Installs it as `<module>.so` (`.dll` on Windows) in the rock's lib
   directory.

With no matching archive, no checksum, a failed download or a module that
does not load, it builds from source with luarocks-build-rust-mlua
(`cargo` needed) and installs the library itself.
`LSDOCS_PREBUILT=0` always builds from source.

## The rockspec

```lua
build_dependencies = { "luarocks-build-lsdocs-prebuilt" }
build = {
  type = "lsdocs-prebuilt",
  url = "https://github.com/lsdocs/lsdocs-rst/releases/download/lsdocs-rst-lua%2Fv0.1.0",
  sha256 = {
    ["lua54-x86_64-unknown-linux-gnu"] = "...",
    -- one per archive; build-rocks.yml writes them for @SHA256@
  },
  -- As for rust-mlua (used for the source build): exactly one module.
  modules = { ["lsdocs_rst"] = "lsdocs_rst_lua" },
  default_features = false,
  features = { "module" },
}
```

## Releasing

Push a `luarocks-build-lsdocs-prebuilt/v<version>` tag:
`luarocks-backend.yml` uploads the rockspec written from
`luarocks-build-lsdocs-prebuilt.rockspec.in` to luarocks.org with the
`release` environment's `LUAROCKS_API_KEY`. Release it before a binding
whose rockspec needs it (or a newer version of it).

## Trying it

From the repository root: `luarocks make
luarocks-build-lsdocs-prebuilt/luarocks-build-lsdocs-prebuilt-dev-1.rockspec`
(with luarocks-build-rust-mlua installed). LuaRocks loads build backends
from its `rocks_trees` only: with `--tree`, list that tree there too.

[mlua]: https://github.com/mlua-rs/mlua
[luarocks-build-rust-mlua]: https://github.com/mlua-rs/luarocks-build-rust-mlua
