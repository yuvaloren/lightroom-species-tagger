#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
build/build.lua
Composes the installable SpeciesTagger.lrplugin bundle in output/dist/ from src/,
stamps the version into Info.lua, zips it, writes checksums, and (optionally)
installs it into the local Lightroom Modules folder for development.

Only dependency is luafilesystem (`luarocks install luafilesystem`). The plugin's
single third-party runtime dependency (dkjson) is pulled via LuaRocks at build
time and bundled into the .lrplugin — it is never committed to this repo.

Usage:
  lua build/build.lua [options]

Options:
  --version=X.Y.Z[-pre]  Version label to stamp + name artifacts. Default:
                         resolved from $GITHUB_REF_NAME (when it looks like a
                         tag) else the repo-root VERSION file.
  --install              After building, symlink the bundle into the local
                         Lightroom Modules folder (build once, then Reload in
                         Plug-in Manager).
  --uninstall            Remove that symlink and exit.
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
		die( 'luarocks is required to fetch dkjson — run ./dev-setup.sh (or `just setup`)' )
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
-- install / uninstall into the Lightroom Modules folder

local function modules_dir()
	local is_windows = package.config:sub( 1, 1 ) == '\\'
	if is_windows then
		local appdata = os.getenv( 'APPDATA' ) or ''
		return appdata .. '\\Adobe\\Lightroom\\Modules'
	end
	local home = os.getenv( 'HOME' ) or ''
	return home .. '/Library/Application Support/Adobe/Lightroom/Modules'
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
	local mods = modules_dir()
	mkdirp( mods )
	for _, plugin in ipairs( PLUGINS ) do
		local target = DIST .. '/' .. plugin .. '.lrplugin'
		local link = mods .. '/' .. plugin .. '.lrplugin'
		if not exists( target ) then
			die( 'nothing to install: ' .. target .. ' (run a build first)' )
		end
		-- clear any prior install (incl. a stale/dangling symlink) before re-linking
		if not remove_existing( link ) then
			die( 'could not replace existing ' .. link .. ' — remove it by hand and retry' )
		end
		local ok, err = lfs.link( target, link, true ) -- symbolic
		if not ok then
			die( 'could not symlink ' .. link .. ': ' .. tostring( err ) )
		end
		log( 'installed (symlink) ' .. link .. ' -> ' .. target )
	end
	log( '' )
	log( 'In Lightroom Classic: Plug-in Manager will pick this up on next launch,' )
	log( 'or use "Reload" after a rebuild. NOTE: editing a src/shared/ module needs a' )
	log( 'rebuild (lua build/build.lua) before Reload — the bundle holds a copy.' )
end

local function do_uninstall()
	local mods = modules_dir()
	for _, plugin in ipairs( PLUGINS ) do
		local link = mods .. '/' .. plugin .. '.lrplugin'
		if lfs.symlinkattributes( link, 'mode' ) ~= nil then
			remove_existing( link )
			log( 'removed ' .. link )
		end
	end
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

	rmtree( DIST )
	mkdirp( DIST )

	for _, plugin in ipairs( PLUGINS ) do
		local srcdir = SRC .. '/' .. plugin .. '.lrplugin'
		local outdir = DIST .. '/' .. plugin .. '.lrplugin'
		mkdirp( outdir )

		-- plugin-specific files (allowlist: skip dotfiles like .DS_Store)
		for entry in lfs.dir( srcdir ) do
			if entry:sub( 1, 1 ) ~= '.'
				and lfs.attributes( srcdir .. '/' .. entry, 'mode' ) == 'file' then
				copy_file( srcdir .. '/' .. entry, outdir .. '/' .. entry )
			end
		end

		-- shared modules, copied flat into the bundle
		local shared = SRC .. '/shared'
		for entry in lfs.dir( shared ) do
			if entry:match( '%.lua$' ) then
				copy_file( shared .. '/' .. entry, outdir .. '/' .. entry )
			end
		end

		-- the pulled dependency, bundled flat
		copy_file( dkjson, outdir .. '/dkjson.lua' )

		-- the Google Lens browser helper (Node + Chrome) — bundled so the Lens
		-- backend can shell out to it at <plugin>/lens/lens-search.js. node_modules
		-- (puppeteer-core) must be present: run `cd scripts/lens && npm i` first.
		local lensSrc = ROOT .. '/scripts/lens'
		if exists( lensSrc .. '/lens-search.js' ) then
			if not exists( lensSrc .. '/node_modules' ) then
				log( 'WARNING: scripts/lens/node_modules missing — run `cd scripts/lens && npm i` ' ..
					'so the Google Lens backend works in the bundle' )
			end
			run( string.format( 'cp -R %q %q', lensSrc, outdir .. '/lens' ) )
			log( 'bundled Google Lens helper -> ' .. outdir .. '/lens' )
		end

		stamp_info( outdir .. '/Info.lua', major, minor, patch, build, label )
		-- Stamp the full label as a module the settings panel can show verbatim (the
		-- Plug-in Manager's own version field is numeric-only). Overwrites the src copy.
		write_file( outdir .. '/Version.lua', string.format( 'return %q\n', label ) )
		log( string.format( 'built %s  (%d.%d.%d build %d)', outdir, major, minor, patch, build ) )
	end
end

local function package_zips( label )
	if not have_tool( 'zip' ) then
		die( 'zip is required to package artifacts (install it, or pass --no-zip)' )
	end
	local names = {}
	for _, plugin in ipairs( PLUGINS ) do
		local zipname = plugin .. '.lrplugin-' .. label .. '.zip'
		run( string.format( 'cd %q && zip -qr %q %q', DIST, zipname, plugin .. '.lrplugin' ) )
		names[ #names + 1 ] = zipname
		log( 'zipped ' .. zipname )
	end

	local sha = have_tool( 'shasum' ) and 'shasum -a 256'
		or ( have_tool( 'sha256sum' ) and 'sha256sum' or nil )
	if sha then
		local list = {}
		for _, n in ipairs( names ) do list[ #list + 1 ] = string.format( '%q', n ) end
		run( string.format( 'cd %q && %s %s > checksums.txt',
			DIST, sha, table.concat( list, ' ' ) ) )
		log( 'wrote checksums.txt' )
	else
		log( 'note: no shasum/sha256sum found — skipped checksums.txt' )
	end
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
if opts.zip then
	package_zips( label )
end
if opts.install then
	do_install()
end
log( 'done: ' .. DIST )
