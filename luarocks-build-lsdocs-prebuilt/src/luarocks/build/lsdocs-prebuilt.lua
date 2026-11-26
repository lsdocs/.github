-- A LuaRocks build backend (`build.type = "lsdocs-prebuilt"`) for Lua
-- modules written in Rust with mlua: it installs the prebuilt module that
-- lsdocs/.github's build-rocks.yml made for this Lua and platform, attached
-- to a GitHub release, and builds from source with luarocks-build-rust-mlua
-- when there is none (or it does not load).
--
-- The rockspec's build table:
--
--   build = {
--     type = "lsdocs-prebuilt",
--     -- The release's download URL (the archives are under it).
--     url = "https://github.com/<owner>/<repo>/releases/download/<tag>",
--     -- One per archive, "<lua>-<target>" = SHA-256 (build-rocks.yml
--     -- writes them); a missing entry means no prebuilt module.
--     sha256 = { ["lua54-x86_64-unknown-linux-gnu"] = "...", ... },
--     -- As for rust-mlua: one module, `require` name = library name.
--     modules = { ["<module>"] = "<library>" },
--     default_features = false,
--     features = { "module" },
--   }
--
-- The archive for a module is <module>-<version>-<lua>-<target>.tar.gz
-- (<version> without the rockspec revision), holding lib/<module>.so
-- (lib/<module>.dll on Windows). <lua> is lua54 or luajit.
--
-- LSDOCS_PREBUILT=0 in the environment skips the prebuilt module (always
-- build from source).

local cfg = require("luarocks.core.cfg")
local dir = require("luarocks.dir")
local fetch = require("luarocks.fetch")
local fs = require("luarocks.fs")
local path = require("luarocks.path")
local util = require("luarocks.util")

local prebuilt = {}

-- LuaRocks' target_cpu -> Rust's.
local cpus = {
  x86_64 = "x86_64",
  aarch64 = "aarch64",
  arm64 = "aarch64",
}

-- The Rust target triple build-rocks.yml names its archives with, or nil.
local function target_triple()
  local cpu = cpus[cfg.target_cpu or ""]
  if not cpu then
    return nil
  end
  if cfg.is_platform("windows") then
    return cpu .. "-pc-windows-msvc"
  elseif cfg.is_platform("macosx") then
    return cpu .. "-apple-darwin"
  elseif cfg.is_platform("linux") then
    return cpu .. "-unknown-linux-gnu"
  end
  return nil
end

-- Runs the target interpreter (variables.LUA) on a script file with
-- arguments; returns its output, or nil.
local function run_lua(script, ...)
  local lua = cfg.variables.LUA
  if not lua then
    return nil
  end
  local cmd = { fs.Q(lua), fs.Q(script) }
  for _, arg in ipairs({ ... }) do
    table.insert(cmd, fs.Q(arg))
  end
  -- 2>&1 works in sh and cmd.
  local pipe = io.popen(table.concat(cmd, " ") .. " 2>&1")
  if not pipe then
    return nil
  end
  local out = pipe:read("*a")
  local ok = pipe:close()
  -- Lua 5.1's close returns true whatever the exit status: the scripts
  -- print a marker on success.
  return out, ok
end

local function write_file(name, text)
  local f, err = io.open(name, "wb")
  if not f then
    return nil, err
  end
  f:write(text)
  f:close()
  return true
end

-- "lua54" or "luajit": the target interpreter, asked (`jit` is set in
-- LuaJIT); nil for any other Lua.
local function lua_kind(tmp)
  local script = dir.path(tmp, "kind.lua")
  if not write_file(script, 'io.write("kind=", jit and "luajit" or _VERSION)') then
    return nil
  end
  local out = run_lua(script) or ""
  if out:match("kind=luajit") and cfg.lua_version == "5.1" then
    return "luajit"
  elseif out:match("kind=Lua 5%.4") and cfg.lua_version == "5.4" then
    return "lua54"
  end
  return nil
end

-- The file's SHA-256 (lowercase hex), with whatever tool the system has.
local function sha256(file)
  local q = fs.Q(file)
  local cmds = {
    "sha256sum " .. q,
    "shasum -a 256 " .. q,
    "openssl dgst -sha256 -r " .. q,
    "certutil -hashfile " .. q .. " SHA256",
  }
  for _, cmd in ipairs(cmds) do
    local pipe = io.popen(cmd .. " 2>&1")
    if pipe then
      local out = pipe:read("*a") or ""
      pipe:close()
      -- certutil prints the hash on its second line, maybe spaced.
      for line in out:gmatch("[^\r\n]+") do
        local compact = line:gsub(" ", "")
        local hex = compact:match("^(%x+)") or ""
        if #hex == 64 then
          return hex:lower()
        end
      end
    end
  end
  return nil
end

-- The rockspec's one module: its `require` name and its library name.
local function the_module(rockspec)
  local modules = rockspec.build.modules
  if type(modules) ~= "table" then
    return nil, "build.modules is missing"
  end
  local name, library
  for k, v in pairs(modules) do
    if name then
      return nil, "build.modules must hold exactly one module"
    end
    name, library = (type(k) == "number") and v or k, v
  end
  if not name then
    return nil, "build.modules is empty"
  end
  return name, library
end

local function install_file(rockspec, src, name)
  local libdir = path.lib_dir(rockspec.name, rockspec.version)
  fs.make_dir(libdir)
  local dst = dir.path(libdir, name .. "." .. cfg.lib_extension)
  local ok, err = fs.copy(src, dst, "exec")
  if not ok then
    return nil, "Failed installing " .. src .. " in " .. dst .. ": " .. tostring(err)
  end
  return true
end

-- Tries the prebuilt module. Returns true when installed; nil and a reason
-- to build from source instead; or false and an error that must stop the
-- install (a checksum mismatch).
local function try_prebuilt(rockspec, module, no_install, tmp, kind)
  local build = rockspec.build
  if os.getenv("LSDOCS_PREBUILT") == "0" then
    return nil, "LSDOCS_PREBUILT=0"
  end
  if type(build.url) ~= "string" or type(build.sha256) ~= "table" then
    return nil, "no build.url or build.sha256"
  end
  local target = target_triple()
  if not target then
    return nil, "no prebuilt modules for " .. tostring(cfg.arch)
  end
  if not kind then
    return nil, "no prebuilt modules for this Lua (Lua 5.4 and LuaJIT only)"
  end
  local key = kind .. "-" .. target
  local expected = build.sha256[key]
  if type(expected) ~= "string" then
    return nil, "no prebuilt module for " .. key
  end

  local version = rockspec.version:gsub("%-%d+$", "")
  local archive = ("%s-%s-%s-%s.tar.gz"):format(module, version, kind, target)
  local url = build.url:gsub("/$", "") .. "/" .. archive

  local ok, err = fs.change_dir(tmp)
  if not ok then
    return nil, err
  end
  local file
  file, err = fetch.fetch_url(url, archive, nil, "no_mirror")
  if not file then
    fs.pop_dir()
    return nil, err
  end
  local actual = sha256(file)
  if not actual then
    fs.pop_dir()
    return nil, "no SHA-256 tool (sha256sum, shasum, openssl or certutil)"
  end
  if actual ~= expected:lower() then
    fs.pop_dir()
    return false, "Checksum mismatch for " .. url .. ": expected " .. expected .. ", got " .. actual
  end
  ok, err = fs.unpack_archive(file)
  fs.pop_dir()
  if not ok then
    return nil, "Failed unpacking " .. archive .. ": " .. tostring(err)
  end

  -- Load it in the target interpreter: a module that cannot (an older glibc,
  -- musl, another Lua DLL name on Windows) is built from source instead.
  local libdir = dir.path(tmp, "lib")
  local lib = dir.path(libdir, module .. "." .. cfg.lib_extension)
  if not fs.exists(lib) then
    return nil, archive .. " has no lib/" .. module .. "." .. cfg.lib_extension
  end
  local script = dir.path(tmp, "load.lua")
  write_file(script, table.concat({
    "local libdir, module, ext = ...",
    'package.cpath = libdir .. "/?." .. ext',
    "local ok, err = pcall(require, module)",
    'if ok then io.write("loaded=yes") else io.write(tostring(err)) end',
  }, "\n"))
  local out = run_lua(script, libdir, module, cfg.lib_extension) or ""
  if not out:match("loaded=yes") then
    return nil, "the prebuilt module does not load here: " .. out
  end

  if no_install then
    return true
  end
  return install_file(rockspec, lib, module)
end

-- Builds from source with luarocks-build-rust-mlua, then installs the
-- library itself (rust-mlua expects the Windows DLL named after the module,
-- not the library).
local function from_source(rockspec, module, library, no_install, kind)
  local ok, rust_mlua = pcall(require, "luarocks.build.rust-mlua")
  if not ok then
    return nil, "luarocks-build-rust-mlua is not installed"
  end
  -- rust-mlua picks the luajit feature from util.get_luajit_version()
  -- (LuaRocks 3.9 and later) or cfg.luajit_version, which older LuaRocks
  -- leaves unset when the interpreter is configured by path: say what the
  -- interpreter said.
  if kind == "luajit" and not cfg.luajit_version then
    cfg.luajit_version = "2.1"
  end
  local built, err = rust_mlua.run(rockspec, true)
  if not built then
    return nil, err
  end
  if no_install then
    return true
  end
  local target_path = rockspec.build.target_path or "target"
  local name
  if cfg.is_platform("windows") then
    name = library .. ".dll"
  else
    name = "lib" .. library .. "." .. cfg.external_lib_extension
  end
  return install_file(rockspec, dir.path(target_path, "release", name), module)
end

function prebuilt.run(rockspec, no_install)
  local module, library = the_module(rockspec)
  if not module then
    return nil, library
  end
  local tmp, err = fs.make_temp_dir("lsdocs-prebuilt")
  if not tmp then
    return nil, "Failed creating a temporary directory: " .. tostring(err)
  end
  local kind = lua_kind(tmp)
  local ok, why = try_prebuilt(rockspec, module, no_install, tmp, kind)
  fs.delete(tmp)
  if ok then
    util.printout("Installed the prebuilt " .. module .. " module.")
    return true
  elseif ok == false then
    return nil, why
  end
  util.printout("Building " .. module .. " from source: " .. tostring(why))
  return from_source(rockspec, module, library, no_install, kind)
end

return prebuilt
