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

-- A distinct non-error sentinel the assist path returns (in place of a message) when the
-- user pressed Skip, so the caller leaves the photo untouched without treating it as an error.
M.LENS_CANCELLED = '__lens_cancelled__'

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

-- Resolve `node` to a real path. Lightroom's GUI gets a minimal PATH, so probe the
-- usual per-platform install locations before falling back to a bare "node" (found via
-- PATH). No user setting: Node discovery is automatic.
local function resolveNode( isWin )
	local candidates = isWin
		and { ( os.getenv( 'ProgramFiles' ) or 'C:\\Program Files' ) .. '\\nodejs\\node.exe',
			( os.getenv( 'ProgramW6432' ) or 'C:\\Program Files' ) .. '\\nodejs\\node.exe' }
		or { '/opt/homebrew/bin/node', '/usr/local/bin/node', '/usr/bin/node' }
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
			'(see scripts/lens/README).'
	end
	-- The helper prints ONE line of JSON on stdout. If that comes back truncated or
	-- garbled, surface a diagnosable message (with the first chunk of what we got)
	-- instead of a bare nil from json.decode — this is the tool's most critical boundary.
	local decoded, _, derr = json.decode( body )
	if type( decoded ) ~= 'table' then
		local snippet = body:sub( 1, 200 ):gsub( '%s+', ' ' )
		return nil, 'Google Lens helper returned unreadable output' ..
			( derr and ( ' (' .. tostring( derr ) .. ')' ) or '' ) .. ': ' .. snippet
	end
	return decoded
end

-- lensAssistAdapter(opts) -> { tag(imageFile, pos) -> name|nil,err ; close() }
-- Assistive mode. tag() opens Google Lens in a VISIBLE window (reusing one window across
-- photos, a fresh tab each), shows an "m of n" counter (pos), and blocks until the user
-- highlights a species and presses Tag — returning ONLY that string. The plugin never
-- scrapes the page. close() shuts the reused window down cleanly at the end of a run (so
-- Chrome shows no "didn't shut down correctly" prompt). See scripts/lens/lens-search.js.
function M.lensAssistAdapter( opts )
	opts = opts or {}
	local helper = opts.helperPath
	local node = resolveNode( isWindows() )
	local port = opts.tabsPort and tostring( opts.tabsPort ) or nil

	return {
		tag = function( imageFile, pos )
			local env = {}
			if pos and pos ~= '' then env[ #env + 1 ] = { 'LENS_ASSIST_POS', pos } end
			if port then env[ #env + 1 ] = { 'LENS_TABS_PORT', port } end
			local d, err = runHelper( node, helper, { { value = imageFile } }, env )
			if not d then return nil, err end
			if type( d ) == 'table' and d.cancelled then return nil, M.LENS_CANCELLED end
			if type( d ) ~= 'table' or not d.ok or type( d.name ) ~= 'string' or d.name == '' then
				return nil, 'Google Lens assist: ' .. ( d and tostring( d.error ) or 'nothing was tagged' )
			end
			return d.name
		end,
		-- Best-effort clean shutdown of the reused window; ignores errors (nothing to close).
		close = function()
			local env = { { 'LENS_ASSIST_CLOSE', '1' } }
			if port then env[ #env + 1 ] = { 'LENS_TABS_PORT', port } end
			runHelper( node, helper, { { value = 'close', raw = true } }, env )
		end,
	}
end


return M
