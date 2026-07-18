#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
build/build.lua
Composes the installable SpeciesTagger.lrplugin bundle in output/dist/ from src/,
stamps the version into Info.lua, zips it, writes checksums, and (optionally,
--install) copies a full standalone plugin into ~/Documents/Lightroom Plugins
(override with LR_PLUGIN_DIR) to Add/Reload in Plug-in Manager for development.

Only dependency is luafilesystem (`luarocks install luafilesystem`). The plugin's
single third-party runtime dependency (dkjson) is pulled via LuaRocks at build
time and bundled into the .lrplugin — it is never committed to this repo.

Usage:
  lua build/build.lua [options]

Options:
  --version=X.Y.Z[-pre]  Version label to stamp + name artifacts. Default:
                         resolved from $GITHUB_REF_NAME (when it looks like a
                         tag) else the repo-root VERSION file.
  --install              After building, copy a full standalone bundle into a
                         Lightroom Plugins folder (~/Documents/Lightroom Plugins,
                         or $LR_PLUGIN_DIR) to Add/Reload in Plug-in Manager.
  --uninstall            Remove that installed copy and exit.
  --fetch-deps           Ensure the pinned dkjson is cached, then stop (used
                         before running the test suite).
  --no-zip               Compose the bundle only; skip zip + checksums.
  --help                 Show this help.

Environment:
  GITHUB_REF_NAME   On a tag push (vX.Y.Z) this becomes the version label.
  GITHUB_RUN_NUMBER Stamped into the Info.lua numeric `build` field (else 0).
------------------------------------------------------------------------------]]

local lfs = require 'lfs'

local PLUGINS = { 'SpeciesTagger' }

-- The plugin's only third-party runtime dependency. Pinned here (single source
-- of truth); pulled via LuaRocks at build time and bundled into the .lrplugin.
local DKJSON_VERSION = '2.10'

-- The Go lens helper. This build cross-compiles it (see build_helper) into
-- src/helper/dist/ and copies it into the bundle at <plugin>/helper/<key>/
-- lens-helper[.exe] — one static binary per platform; the user supplies only
-- Google Chrome. The Go toolchain pin lives in src/helper/go.mod, guarded
-- weekly by build/check-go-eol.sh (a custom pin Dependabot cannot see).
-- A bundle may carry BOTH Windows arches: resolveHelper (src/plugin/shared/
-- Http.lua) prefers win-x64, which runs everywhere (natively on x64, emulated
-- on Windows-on-ARM), and the NSIS installer installs only the machine's
-- native one so ARM installs get the arm64 build.
local HELPER_PLATFORMS = {
	[ 'darwin-universal' ] = { src = 'darwin-universal/lens-helper',  bin = 'lens-helper' },
	[ 'darwin-arm64' ]     = { src = 'darwin/arm64/lens-helper',      bin = 'lens-helper' },
	[ 'darwin-x64' ]       = { src = 'darwin/amd64/lens-helper',      bin = 'lens-helper' },
	[ 'win-x64' ]          = { src = 'windows/amd64/lens-helper.exe', bin = 'lens-helper.exe' },
	[ 'win-arm64' ]        = { src = 'windows/arm64/lens-helper.exe', bin = 'lens-helper.exe' },
}

--------------------------------------------------------------------------------
-- paths

local function abspath( p )
	if p:sub( 1, 1 ) == '/' then return p end
	return ( lfs.currentdir() .. '/' .. p )
end

local function dirname( p )
	return ( p:match( '^(.*)/[^/]*$' ) ) or '.'
end

local SCRIPT = abspath( arg[ 0 ] )
local ROOT = dirname( dirname( SCRIPT ) ) -- build/build.lua -> repo root
local SRC = ROOT .. '/src'
local HELPER_DIR = SRC .. '/helper' -- the Go lens helper module
-- Everything this build generates lives under one gitignored top-level tree,
-- `output/` (removed by `just clean`): the composed bundle + zips in output/dist,
-- and the pulled Lua dependency (dkjson) cached in output/deps.
local OUTPUT = ROOT .. '/output'
local DIST = OUTPUT .. '/dist'
local DEPS = OUTPUT .. '/deps'

--------------------------------------------------------------------------------
-- small helpers

local function die( msg )
	io.stderr:write( 'build: ' .. msg .. '\n' )
	os.exit( 1 )
end

local function log( msg )
	io.write( msg .. '\n' )
end

-- os.execute returns differ across Lua 5.1 (number) and 5.2+ (ok, how, code).
local function run( cmd )
	local a, b, c = os.execute( cmd )
	local ok = ( a == true ) or ( a == 0 ) or ( b == 'exit' and c == 0 )
	if not ok then
		die( 'command failed (' .. tostring( a ) .. '): ' .. cmd )
	end
end

local function exists( path )
	return lfs.attributes( path, 'mode' ) ~= nil
end

local function have_tool( name )
	local h = io.popen( 'command -v ' .. name .. ' 2>/dev/null' )
	local out = h:read( '*a' )
	h:close()
	return out ~= nil and out:gsub( '%s+', '' ) ~= ''
end

local function read_file( path )
	local f = assert( io.open( path, 'rb' ) )
	local data = f:read( '*a' )
	f:close()
	return data
end

local function write_file( path, data )
	local f = assert( io.open( path, 'wb' ) )
	f:write( data )
	f:close()
end

local function copy_file( from, to )
	write_file( to, read_file( from ) ) -- binary-safe (covers .png)
	-- Preserve the source's executable bit. write_file creates the copy with the
	-- default 0644, which silently breaks any binary in the tree — the lens
	-- helper installed by `--install` (copytree) landed non-executable, so the
	-- plugin could not run it at all (no hash, every Tag failed instantly). lfs
	-- can't chmod, so shell out, but only when the source is actually +x.
	local perms = lfs.attributes( from, 'permissions' ) -- e.g. 'rwxr-xr-x'
	if perms and perms:sub( 3, 3 ) == 'x' then
		run( string.format( 'chmod +x %q', to ) )
	end
end

local function mkdirp( path )
	local acc = ''
	for part in ( path .. '/' ):gmatch( '([^/]*)/' ) do
		acc = ( acc == '' and ( path:sub( 1, 1 ) == '/' and '/' or '' ) or acc .. '/' ) .. part
		if part ~= '' and not exists( acc ) then
			assert( lfs.mkdir( acc ) )
		end
	end
end

local function rmtree( path )
	local mode = lfs.attributes( path, 'mode' )
	if mode == nil then return end
	if mode == 'directory' then
		for entry in lfs.dir( path ) do
			if entry ~= '.' and entry ~= '..' then
				rmtree( path .. '/' .. entry )
			end
		end
		lfs.rmdir( path )
	else
		os.remove( path )
	end
end

--------------------------------------------------------------------------------
-- dependency pull (dkjson, via LuaRocks, cached + bundled — never committed)

local function ensure_dkjson( force )
	local cached = DEPS .. '/dkjson.lua'
	if not force and exists( cached ) then
		return cached
	end
	if not have_tool( 'luarocks' ) then
		die( 'luarocks is required to fetch dkjson — run `just setup`' )
	end
	mkdirp( DEPS )
	local tree = DEPS .. '/_rocks'
	log( 'fetching dkjson ' .. DKJSON_VERSION .. ' via luarocks…' )
	run( string.format( 'luarocks install --tree %q dkjson %s', tree, DKJSON_VERSION ) )

	local base = tree .. '/share/lua'
	local found
	if exists( base ) then
		for ver in lfs.dir( base ) do
			if ver ~= '.' and ver ~= '..' then
				local cand = base .. '/' .. ver .. '/dkjson.lua'
				if exists( cand ) then found = cand break end
			end
		end
	end
	if not found then
		die( 'luarocks reported success but dkjson.lua was not found under ' .. base )
	end
	copy_file( found, cached )
	log( 'cached dkjson -> ' .. cached )
	return cached
end

--------------------------------------------------------------------------------
-- bundled Go lens helper (built locally by helper/Makefile — never fetched)

-- Which platform keys this build bundles. Default: the release shape (one
-- universal mac binary + both Windows arches). Override for quick dev
-- composes with ST_HELPER_PLATFORMS=darwin-arm64 (comma-separated).
local function helper_platforms()
	local env = os.getenv( 'ST_HELPER_PLATFORMS' )
	if env and env:gsub( '%s', '' ) ~= '' then
		local list = {}
		for entry in env:gmatch( '[^,]+' ) do
			local key = ( entry:gsub( '%s', '' ) )
			if not HELPER_PLATFORMS[ key ] then die( 'unknown ST_HELPER_PLATFORMS entry: ' .. key ) end
			list[ #list + 1 ] = key
		end
		return list
	end
	return { 'darwin-universal', 'win-x64', 'win-arm64' }
end

--------------------------------------------------------------------------------
-- args

local opts = { install = false, uninstall = false, zip = true, version = nil, fetch = false }
for _, a in ipairs( arg ) do
	if a == '--install' then opts.install = true
	elseif a == '--uninstall' then opts.uninstall = true
	elseif a == '--no-zip' then opts.zip = false
	elseif a == '--fetch-deps' then opts.fetch = true
	elseif a:match( '^--version=' ) then opts.version = a:match( '^--version=(.+)$' )
	elseif a == '--help' or a == '-h' then
		log( 'Usage: lua build/build.lua [--version=X.Y.Z] [--install] [--uninstall] [--no-zip] [--fetch-deps]' )
		os.exit( 0 )
	else
		die( 'unknown option: ' .. a )
	end
end

--------------------------------------------------------------------------------
-- version resolution + parsing

local function resolve_version()
	if opts.version and opts.version ~= '' then
		return ( opts.version:gsub( '^v', '' ) )
	end
	local ref = os.getenv( 'GITHUB_REF_NAME' )
	if ref and ref:match( '^v?%d+%.%d+%.%d+' ) then
		return ( ref:gsub( '^v', '' ) )
	end
	local vf = ROOT .. '/VERSION'
	if exists( vf ) then
		return ( read_file( vf ):gsub( '%s+$', '' ) )
	end
	return 'dev'
end

local function parse_numeric( label )
	local major, minor, patch = label:match( '^(%d+)%.(%d+)%.(%d+)' )
	if not major then
		return 0, 0, 0
	end
	return tonumber( major ), tonumber( minor ), tonumber( patch )
end

--------------------------------------------------------------------------------
-- install / uninstall: copy a FULL plugin bundle into a stable, user-managed folder
-- that Lightroom's Plug-in Manager can Add + Reload + Remove. (Deliberately NOT the
-- auto-load Modules folder, whose plugins can't be removed from Plug-in Manager.)
-- Override the location with LR_PLUGIN_DIR.

local function install_dir()
	local env = os.getenv( 'LR_PLUGIN_DIR' )
	if env and env ~= '' then return env end
	if package.config:sub( 1, 1 ) == '\\' then
		return ( os.getenv( 'USERPROFILE' ) or '' ) .. '\\Documents\\Lightroom Plugins'
	end
	return ( os.getenv( 'HOME' ) or '' ) .. '/Documents/Lightroom Plugins'
end

-- Recursively copy a directory tree (binary-safe via copy_file). Used to install a
-- full standalone copy of the built .lrplugin — no symlink back into the repo.
local function copytree( src, dst )
	local mode = lfs.attributes( src, 'mode' )
	if mode == 'directory' then
		mkdirp( dst )
		for entry in lfs.dir( src ) do
			if entry ~= '.' and entry ~= '..' then
				copytree( src .. '/' .. entry, dst .. '/' .. entry )
			end
		end
	elseif mode == 'file' then
		copy_file( src, dst )
	end
end

-- Remove whatever is already at `path`: a symlink (possibly DANGLING — e.g. a prior
-- install that pointed at the old dist/ location), a file, or a real directory.
-- lfs.attributes follows symlinks, so a dangling link reads as absent and would be
-- left in place (then lfs.link fails "File exists"); symlinkattributes inspects the
-- link itself, which is what we need. Returns true if the path is now clear.
local function remove_existing( path )
	local mode = lfs.symlinkattributes( path, 'mode' )
	if mode == nil then return true end
	if mode == 'directory' then rmtree( path ) else os.remove( path ) end
	return lfs.symlinkattributes( path, 'mode' ) == nil
end

local function do_install()
	local dir = install_dir()
	mkdirp( dir )
	local installed = {}
	for _, plugin in ipairs( PLUGINS ) do
		local target = DIST .. '/' .. plugin .. '.lrplugin'
		local dest = dir .. '/' .. plugin .. '.lrplugin'
		if not exists( target ) then
			die( 'nothing to install: ' .. target .. ' (run a build first)' )
		end
		-- clear any prior install (a real copy, or a stale symlink from older installs)
		if not remove_existing( dest ) then
			die( 'could not replace existing ' .. dest .. ' — remove it by hand and retry' )
		end
		copytree( target, dest ) -- a full standalone copy — no symlink back into the repo
		installed[ #installed + 1 ] = dest
		log( 'installed (copy) ' .. dest )
	end
	log( '' )
	log( 'In Lightroom Classic — File \226\150\184 Plug-in Manager:' )
	log( '  \226\128\162 First time:  click "Add" and select the folder' )
	for _, p in ipairs( installed ) do log( '        ' .. p ) end
	log( '  \226\128\162 After re-running `just install` to update: select "Species Tagger"' )
	log( '        and click "Reload Plug-in" (or just relaunch Lightroom Classic).' )
	log( '' )
	log( 'Then run it from  Library \226\150\184 Plug-in Extras \226\150\184 Identify and Tag Species.' )
end

local function do_uninstall()
	local dir = install_dir()
	for _, plugin in ipairs( PLUGINS ) do
		local dest = dir .. '/' .. plugin .. '.lrplugin'
		if lfs.symlinkattributes( dest, 'mode' ) ~= nil then
			remove_existing( dest )
			log( 'removed ' .. dest .. ' (also remove it from Plug-in Manager if it was Added)' )
		end
	end
end

--------------------------------------------------------------------------------
-- Go lens helper: cross-compile every shipped target + the universal mac
-- binary, into src/helper/dist/. Folded in from the old helper/Makefile so the
-- whole build is ONE command (`just build`) — no separate `make` step to
-- remember or forget. No UPX (it can't pack Mach-O or win-arm64, and trips AV
-- on the one exe it could): stripped Go is already ~6 MB vs the ~200 MB Node
-- runtime this replaced. `lipo` on macOS, `llvm-lipo` elsewhere (CI installs
-- llvm). CGO off so every target is a static cross-compile with no C toolchain.

local function build_helper()
	local targets = { 'darwin/arm64', 'darwin/amd64', 'windows/amd64', 'windows/arm64' }
	if not have_tool( 'go' ) then
		die( 'go is required to build the lens helper — install Go (brew install go), then re-run' )
	end
	for _, t in ipairs( targets ) do
		local goos, goarch = t:match( '^(%w+)/(%w+)$' )
		local ext = ( goos == 'windows' ) and '.exe' or ''
		local out = HELPER_DIR .. '/dist/' .. t .. '/lens-helper' .. ext
		mkdirp( dirname( out ) )
		run( string.format(
			'cd %q && GOOS=%s GOARCH=%s CGO_ENABLED=0 go build -trimpath -ldflags=%q -o %q .',
			HELPER_DIR, goos, goarch, '-s -w', out ) )
		log( 'built helper ' .. t )
	end
	-- universal2 mac binary via lipo / llvm-lipo (llvm-lipo-NN on Debian/CI).
	local lipo
	for _, cand in ipairs( { 'lipo', 'llvm-lipo' } ) do
		if have_tool( cand ) then lipo = cand break end
	end
	if not lipo then
		local h = io.popen( 'ls /usr/bin/llvm-lipo-* 2>/dev/null | head -1' )
		local found = h:read( '*a' ):gsub( '%s+', '' )
		h:close()
		if found ~= '' then lipo = found end
	end
	if not lipo then
		die( 'need lipo or llvm-lipo to build the universal mac helper (apt install llvm)' )
	end
	local uni = HELPER_DIR .. '/dist/darwin-universal/lens-helper'
	mkdirp( dirname( uni ) )
	run( string.format( '%s -create %q %q -output %q',
		lipo,
		HELPER_DIR .. '/dist/darwin/arm64/lens-helper',
		HELPER_DIR .. '/dist/darwin/amd64/lens-helper',
		uni ) )
	run( string.format( 'chmod +x %q', uni ) )
	log( 'built helper darwin-universal (arm64 + x86_64)' )
end

--------------------------------------------------------------------------------
-- compose + stamp + package

local function stamp_info( info_path, major, minor, revision, build, label )
	local src = read_file( info_path )
	-- `display` carries the full label (incl. any -pre suffix). Lightroom's numeric
	-- version field can only show major.minor.revision.build (so "0.1.0-dev" -> "0.1.0.0");
	-- newer Lightroom honours `display` for the shown string, and older versions ignore
	-- the extra key harmlessly. The settings panel also shows the label via Version.lua.
	local replacement = string.format(
		'VERSION = { major = %d, minor = %d, revision = %d, build = %d, display = %q }',
		major, minor, revision, build, label )
	local out, n = src:gsub( 'VERSION%s*=%s*{[^}]*}', replacement )
	if n == 0 then
		die( 'no VERSION table found to stamp in ' .. info_path )
	end
	write_file( info_path, out )
end

local function compose( label )
	local major, minor, patch = parse_numeric( label )
	local build = tonumber( os.getenv( 'GITHUB_RUN_NUMBER' ) ) or 0
	local dkjson = ensure_dkjson()

	-- Cross-compile the Go lens helper first so the bundle is self-contained
	-- from a clean checkout with no separate step (one-command build).
	build_helper()

	rmtree( DIST )
	mkdirp( DIST )

	for _, plugin in ipairs( PLUGINS ) do
		-- Source lives in src/plugin/ (LR-SDK files) + src/plugin/shared/ (pure
		-- modules, flattened in); the shipped bundle is always <plugin>.lrplugin.
		local srcdir = SRC .. '/plugin'
		local outdir = DIST .. '/' .. plugin .. '.lrplugin'
		mkdirp( outdir )

		-- plugin-specific files (allowlist: files only, skip dotfiles + subdirs)
		for entry in lfs.dir( srcdir ) do
			if entry:sub( 1, 1 ) ~= '.'
				and lfs.attributes( srcdir .. '/' .. entry, 'mode' ) == 'file' then
				copy_file( srcdir .. '/' .. entry, outdir .. '/' .. entry )
			end
		end

		-- shared modules, copied flat into the bundle
		local shared = srcdir .. '/shared'
		for entry in lfs.dir( shared ) do
			if entry:match( '%.lua$' ) then
				copy_file( shared .. '/' .. entry, outdir .. '/' .. entry )
			end
		end

		-- the pulled dependency, bundled flat
		copy_file( dkjson, outdir .. '/dkjson.lua' )

		-- The Go lens helper, so recognition needs nothing but Chrome installed.
		-- Copied to <plugin>/helper/<key>/lens-helper[.exe]; resolveHelper
		-- (src/plugin/shared/Http.lua) picks the bundled binary by existence.
		for _, key in ipairs( helper_platforms() ) do
			local spec = HELPER_PLATFORMS[ key ]
			local src = HELPER_DIR .. '/dist/' .. spec.src
			if not exists( src ) then
				die( 'helper binary missing after build: ' .. src )
			end
			local helperDir = outdir .. '/helper/' .. key
			mkdirp( helperDir )
			run( string.format( 'cp %q %q', src, helperDir .. '/' .. spec.bin ) )
			if not spec.bin:match( '%.exe$' ) then
				run( string.format( 'chmod +x %q', helperDir .. '/' .. spec.bin ) )
			end
			log( 'bundled lens helper (' .. key .. ') -> ' .. helperDir .. '/' .. spec.bin )
		end

		stamp_info( outdir .. '/Info.lua', major, minor, patch, build, label )
		-- Stamp the full label as a module the settings panel can show verbatim (the
		-- Plug-in Manager's own version field is numeric-only). Overwrites the src copy.
		write_file( outdir .. '/Version.lua', string.format( 'return %q\n', label ) )
		log( string.format( 'built %s  (%d.%d.%d build %d)', outdir, major, minor, patch, build ) )
	end
end

local function package_zips( label )
	-- ALL zip packaging (the three per-platform zips — SpeciesTagger-<ver>-mac/-win/
	-- -all.zip — plus checksums.txt) lives in ONE place, build/package-zips.sh,
	-- shared with the signed-release path (build/sign-macos.sh) so the dev/CI zips
	-- and the release zips can never drift.
	run( string.format( 'bash %q %q', ROOT .. '/build/package-zips.sh', label ) )
end

--------------------------------------------------------------------------------
-- main

if opts.uninstall then
	do_uninstall()
	os.exit( 0 )
end

if opts.fetch then
	ensure_dkjson( false )
	log( 'deps ready' )
	os.exit( 0 )
end

local label = resolve_version()
log( 'version label: ' .. label )
compose( label )
-- Record the resolved label next to the bundle so downstream steps (the signed
-- release path, build/sign-macos.sh) don't re-implement this resolution and
-- risk drifting from it. Sits beside the bundle, so it's never zipped into it.
write_file( DIST .. '/version.txt', label .. '\n' )
if opts.zip then
	package_zips( label )
end
if opts.install then
	do_install()
end
log( 'done: ' .. DIST )
