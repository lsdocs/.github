-- The development rockspec (main): luarocks make it from the repository root
-- to try the backend from a checkout.
rockspec_format = "3.0"
package = "luarocks-build-lsdocs-prebuilt"
version = "dev-1"

source = {
  url = "git+https://github.com/lsdocs/.github",
  branch = "main",
}

description = {
  summary = "A LuaRocks build backend installing prebuilt mlua modules from GitHub releases.",
  detailed = [[
Installs the prebuilt Lua module (Rust, mlua) attached to a GitHub release
for this Lua (5.4 or LuaJIT) and platform, checked against the rockspec's
SHA-256; builds from source with luarocks-build-rust-mlua otherwise.
]],
  homepage = "https://github.com/lsdocs/.github/tree/main/luarocks-build-lsdocs-prebuilt",
  license = "Apache-2.0 OR MIT",
}

dependencies = {
  "lua >= 5.1",
  -- The source fallback.
  "luarocks-build-rust-mlua",
}

build = {
  type = "builtin",
  modules = {
    ["luarocks.build.lsdocs-prebuilt"] = "luarocks-build-lsdocs-prebuilt/src/luarocks/build/lsdocs-prebuilt.lua",
  },
}
