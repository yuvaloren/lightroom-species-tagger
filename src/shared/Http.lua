--[[----------------------------------------------------------------------------
Http.lua
An adapter that turns Lightroom's LrHttp into the small, injectable `http`
interface the providers and the taxonomy resolver expect:

  http.get( url [, headers] )                 -> body|nil, resHeaders
  http.post( url, body [, headers] )          -> body|nil, resHeaders
  http.postMultipart( url, parts [, headers]) -> body|nil, resHeaders

`headers` is a plain { ['Header-Name'] = 'value' } map (converted to LrHttp's
array-of-{field,value} form here). `parts` is LrHttp.postMultipart's content
array. The pure modules never import this directly — the Lightroom glue builds
one of these and passes it in as a dependency, while tests pass a fake.
------------------------------------------------------------------------------]]

local M = {}

local function toLrHeaders( headers )
	if not headers then return nil end
	local arr = {}
	for k, v in pairs( headers ) do
		arr[ #arr + 1 ] = { field = k, value = v }
	end
	return arr
end

-- Build an adapter backed by the real LrHttp. Only callable inside Lightroom.
function M.lrAdapter()
	local LrHttp = import 'LrHttp'
	local TIMEOUT = 30
	return {
		get = function( url, headers )
			return LrHttp.get( url, toLrHeaders( headers ), TIMEOUT )
		end,
		post = function( url, body, headers )
			local h = toLrHeaders( headers ) or {}
			return LrHttp.post( url, body, h, 'POST', TIMEOUT )
		end,
		postMultipart = function( url, parts, headers )
			return LrHttp.postMultipart( url, parts, toLrHeaders( headers ), TIMEOUT )
		end,
	}
end

-- Google Lens has no anonymous API and its results are rendered by JavaScript,
-- which LrHttp can't execute. So the Lens backend shells out (via LrTasks.execute)
-- to the bundled Node helper (scripts/lens/lens-search.js), which drives the user's
-- installed Chrome to render the results and prints JSON { ok, overview, strings }.
-- Everything below is cross-platform: the command is built for the POSIX shell on
-- macOS/Linux and for cmd.exe on Windows (WIN_ENV). Needs Node + Google Chrome.

-- rawget so these load headless (tests) where the Lightroom globals are absent.
local function isWindows() return rawget( _G, 'WIN_ENV' ) == true end

-- Shell-quote one argument for the target shell.
local function shQuote( s, isWin )
	if isWin then
		-- cmd.exe: wrap in double quotes; strip embedded quotes (our args are paths /
		-- numbers / a short query text, which never legitimately contain a ").
		return '"' .. tostring( s ):gsub( '"', '' ) .. '"'
	end
	return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'"
end

local function fileExists( p ) local f = p and io.open( p, 'rb' ); if f then f:close(); return true end return false end

-- Resolve `node` to a real path (GUI apps get a minimal PATH). nodePath (from
-- settings) wins; otherwise probe the usual per-platform locations, else "node".
local function resolveNode( nodePath, isWin )
	local candidates = isWin
		and { ( os.getenv( 'ProgramFiles' ) or 'C:\\Program Files' ) .. '\\nodejs\\node.exe',
			( os.getenv( 'ProgramW6432' ) or 'C:\\Program Files' ) .. '\\nodejs\\node.exe' }
		or { '/opt/homebrew/bin/node', '/usr/local/bin/node', '/usr/bin/node' }
	if nodePath and nodePath ~= '' then table.insert( candidates, 1, nodePath ) end
	for _, p in ipairs( candidates ) do if fileExists( p ) then return p end end
	return 'node'
end

-- Run the bundled helper with `argv` (a list of already-decided string arguments)
-- and `env` (ordered { name, value } pairs), capturing its single JSON stdout line.
-- Returns the decoded table, or (nil, errString). Cross-platform (see above).
local function runHelper( node, helper, argv, env, errFile )
	local LrTasks = import 'LrTasks'
	local LrPathUtils = import 'LrPathUtils'
	local LrFileUtils = import 'LrFileUtils'
	local json = require 'dkjson'
	local isWin = isWindows()
	local q = function( s ) return shQuote( s, isWin ) end
	if not fileExists( helper ) then return nil, 'Lens helper not found at ' .. tostring( helper ) end

	local tmpDir = LrPathUtils.getStandardFilePath( 'temp' )
	local out = LrPathUtils.child( tmpDir, string.format( 'speciestagger-lens-%d.json', os.time() ) )
	local args = { q( node ), q( helper ) }
	for _, a in ipairs( argv ) do args[ #args + 1 ] = a.raw and tostring( a.value ) or q( a.value ) end
	local errRedir = '2> ' .. ( errFile and q( errFile ) or ( isWin and 'NUL' or '/dev/null' ) )
	local invocation = table.concat( args, ' ' ) .. ' > ' .. q( out ) .. ' ' .. errRedir

	local batPath
	if isWin then
		-- cmd.exe quoting + `VAR=val cmd` prefixes are unreliable, so on Windows write a
		-- tiny .bat (env via `set`, then the invocation) and run that — robust and
		-- readable. `%` is doubled so paths/queries containing it survive `set`.
		local lines = { '@echo off' }
		for _, kv in ipairs( env ) do
			lines[ #lines + 1 ] = 'set ' .. q( kv[ 1 ] .. '=' .. ( kv[ 2 ]:gsub( '%%', '%%%%' ) ) )
		end
		lines[ #lines + 1 ] = invocation
		batPath = LrPathUtils.child( tmpDir, string.format( 'speciestagger-lens-%d.bat', os.time() ) )
		local bf = io.open( batPath, 'wb' )
		if bf then bf:write( table.concat( lines, '\r\n' ) .. '\r\n' ); bf:close() end
		LrTasks.execute( q( batPath ) )
	else
		-- POSIX: `NAME='v' ... node helper … > out 2>/dev/null` in one shell line.
		local prefix = {}
		for _, kv in ipairs( env ) do prefix[ #prefix + 1 ] = kv[ 1 ] .. '=' .. q( kv[ 2 ] ) .. ' ' end
		LrTasks.execute( table.concat( prefix ) .. invocation )
	end

	local f = io.open( out, 'rb' )
	local body = f and f:read( '*a' )
	if f then f:close() end
	LrFileUtils.delete( out )
	if batPath then LrFileUtils.delete( batPath ) end
	if not body or body == '' then
		return nil, 'Google Lens helper produced no output — is Node and Google Chrome installed? ' ..
			'(see scripts/lens/README, and set the node path in the plugin settings if needed).'
	end
	return json.decode( body )
end

-- lensSearchAdapter(opts) -> lensSearch( imageFile, lat, lng, place, query )
--   opts.helperPath : absolute path to lens-search.js (bundled in the .lrplugin)
--   opts.nodePath   : optional absolute path to `node` (blank = auto-detect)
--   opts.debugDir   : when set, run a VISIBLE Chrome + keep artifacts here (Debug Lens)
--   opts.interactive/interactiveState : escalate to a visible window on a challenge
--   opts.keepOpen   : keep one window open across the batch (a new tab per photo)
function M.lensSearchAdapter( opts )
	opts = opts or {}
	local helper = opts.helperPath
	local node = resolveNode( opts.nodePath, isWindows() )

	return function( imageFile, lat, lng, place, query, photoPath, photoName )
		local argv = { { value = imageFile } }
		-- pass the photo's location so Lens favours species that occur there: exact GPS
		-- coords if we have them, else a place name (the helper geocodes it).
		if lat and lng then
			argv[ #argv + 1 ] = { value = lat, raw = true }
			argv[ #argv + 1 ] = { value = lng, raw = true }
		elseif place and place ~= '' then
			argv[ #argv + 1 ] = { value = place }
		end

		local env, errFile = {}, nil
		if opts.debugDir and opts.debugDir ~= '' then
			import( 'LrFileUtils' ).createAllDirectories( opts.debugDir )
			-- headed + keep-open so a Chrome window stays open for inspection (the helper
			-- launches it detached + exits, so this call still returns and nothing hangs).
			env[ #env + 1 ] = { 'LENS_HEADED', '1' }
			env[ #env + 1 ] = { 'LENS_DEBUG', '1' }
			env[ #env + 1 ] = { 'LENS_KEEP_OPEN', '1' }
			env[ #env + 1 ] = { 'LENS_DEBUG_DIR', opts.debugDir }
			errFile = import( 'LrPathUtils' ).child( opts.debugDir, 'helper-stderr.log' )
		end
		if opts.interactive and ( not opts.interactiveState or opts.interactiveState.allow ) then
			env[ #env + 1 ] = { 'LENS_INTERACTIVE', '1' }
		end
		if opts.keepOpen then env[ #env + 1 ] = { 'LENS_KEEP_TABS', '1' } end
		-- extra keywords + place name as a text refinement on the visual search
		-- (LENS_QUERY; see scripts/lens/lens-search.js). Best-effort.
		if query and query ~= '' then env[ #env + 1 ] = { 'LENS_QUERY', query } end
		-- stamp the keep-open tab with the photo it's for, so --reparse can re-tag it.
		if photoPath and photoPath ~= '' then env[ #env + 1 ] = { 'LENS_PHOTO_PATH', photoPath } end
		if photoName and photoName ~= '' then env[ #env + 1 ] = { 'LENS_PHOTO_NAME', photoName } end

		local d, err = runHelper( node, helper, argv, env, errFile )
		if not d then return nil, err end
		-- User cancelled the interactive challenge: a distinct sentinel (not an error)
		-- so the caller can skip the photo and stop prompting for the rest of the run.
		if type( d ) == 'table' and d.cancelled then
			if opts.interactiveState then opts.interactiveState.allow = false end
			return nil, '__lens_cancelled__'
		end
		-- Google challenged this request ("unusual traffic"). A distinct sentinel so the
		-- caller can back off the rest of the batch instead of hammering the endpoint
		-- (each further request deepens the IP's reputation hit).
		if type( d ) == 'table' and d.challenged then return nil, '__lens_challenged__' end
		if type( d ) ~= 'table' or not d.ok then
			return nil, 'Google Lens: ' .. ( d and tostring( d.error ) or 'helper error' )
		end
		return { overview = d.overview, strings = d.strings }
	end
end

-- lensReparseAdapter(opts) -> reparse() : re-scrape EVERY tab still on Google Lens in
-- the kept-open window (no upload), so each photo's corrected search can be re-tagged.
-- Returns a list of tabs { { photoPath, photoName, overview, strings, count }, … }
-- (possibly empty) | nil, err. See lens-search.js --reparse.
function M.lensReparseAdapter( opts )
	opts = opts or {}
	local helper = opts.helperPath
	local node = resolveNode( opts.nodePath, isWindows() )
	return function()
		local d, err = runHelper( node, helper, { { value = '--reparse', raw = true } }, {} )
		if not d then return nil, err end
		if type( d ) ~= 'table' or not d.ok then
			return nil, 'Google Lens re-parse: ' .. ( d and tostring( d.error ) or 'no open window' )
		end
		return d.tabs or {}
	end
end

return M
