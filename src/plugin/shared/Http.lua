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

-- A distinct sentinel the assist path returns when NO decision was made on a photo — the
-- user closed the Chrome window, or the (long) wait timed out. Unlike a Skip, this stops the
-- WHOLE run: the rule is that the next identification page is shown only after a Tag or Skip.
M.LENS_ABORTED = '__lens_aborted__'

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
-- to the bundled lens helper — a single static Go binary (helper/ in the repo) —
-- which drives the user's installed Chrome to render the results and prints one
-- JSON line { ok, name } (or { ok = false, cancelled|error }).
-- Everything below is cross-platform: the command is built for the POSIX shell on
-- macOS/Linux and for cmd.exe on Windows (WIN_ENV). The helper ships with the
-- plugin (per-OS binary under <plugin>/helper/); the user supplies only Chrome.

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

-- Candidate paths for the lens helper BUNDLED inside the plugin, most-preferred
-- first. The build puts it at <plugin>/helper/<key>/lens-helper[.exe] so
-- recognition works with only Chrome installed. Pure (no I/O) for testability.
-- Lightroom's sandboxed Lua has no os.getenv / uname, so we can't read the CPU
-- arch here; resolveHelper takes the first candidate that's actually present.
-- ORDER IS LOAD-BEARING on Windows: win-x64 first, because x64 runs everywhere
-- (natively on x64, emulated on Windows-on-ARM) while arm64 runs ONLY on ARM —
-- a bundle carrying both arches must never pick arm64 on an x64 machine. The
-- NSIS installer installs just the native arch, so ARM installs still go
-- native (no win-x64 on disk, the loop falls through to win-arm64).
local function bundledHelperCandidates( isWin, pluginPath )
	if not pluginPath or pluginPath == '' then return {} end
	local sep = isWin and '\\' or '/'
	local keys = isWin and { 'win-x64', 'win-arm64' }
		or { 'darwin-universal', 'darwin-arm64', 'darwin-x64' }
	local binName = isWin and 'lens-helper.exe' or 'lens-helper'
	local out = {}
	for _, key in ipairs( keys ) do
		out[ #out + 1 ] = table.concat( { pluginPath, 'helper', key, binName }, sep )
	end
	return out
end

-- Resolve the bundled helper to a real path. NO system fallback: the helper is
-- the whole program, not a runtime — if it isn't in the bundle the install is
-- broken, and runHelper turns the missing file into a "reinstall" message.
-- Returns the preferred candidate even when absent so that message can name
-- the path it looked for; nil only when there's no plugin path at all.
local function resolveHelper( isWin, pluginPath )
	local candidates = bundledHelperCandidates( isWin, pluginPath )
	for _, p in ipairs( candidates ) do
		if fileExists( p ) then return p end
	end
	return candidates[ 1 ]
end

-- Run the bundled helper with `argv` (a list of already-decided string arguments)
-- and `env` (ordered { name, value } pairs), capturing its single JSON stdout line.
-- Returns the decoded table, or (nil, errString). Cross-platform (see above).
local function runHelper( helper, argv, env, errFile )
	local LrTasks = import 'LrTasks'
	local LrPathUtils = import 'LrPathUtils'
	local LrFileUtils = import 'LrFileUtils'
	local json = require 'dkjson'
	local Log = require 'Log'
	local isWin = isWindows()
	local q = function( s ) return shQuote( s, isWin ) end
	if not helper or not fileExists( helper ) then
		return nil, 'Lens helper missing — reinstall Species Tagger (looked for ' ..
			tostring( helper ) .. ')'
	end

	local tmpDir = LrPathUtils.getStandardFilePath( 'temp' )
	local out = LrPathUtils.child( tmpDir, string.format( 'speciestagger-lens-%d.json', os.time() ) )
	-- Always capture the helper's stderr (to the caller's file, or our own temp) so a launch
	-- failure — node/Chrome/puppeteer missing, or a JS throw — surfaces in the error below
	-- instead of a bare "no output". Ignored on the happy path.
	local ownErr = errFile == nil
	local errPath = errFile or LrPathUtils.child( tmpDir, string.format( 'speciestagger-lens-%d.err', os.time() ) )
	local args = { q( helper ) }
	for _, a in ipairs( argv ) do args[ #args + 1 ] = a.raw and tostring( a.value ) or q( a.value ) end
	local invocation = table.concat( args, ' ' ) .. ' > ' .. q( out ) .. ' 2> ' .. q( errPath )

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
	local ef = io.open( errPath, 'rb' )
	local errText = ef and ef:read( '*a' )
	if ef then ef:close() end
	LrFileUtils.delete( out )
	if ownErr then LrFileUtils.delete( errPath ) end
	if batPath then LrFileUtils.delete( batPath ) end
	-- A short, redacted one-line snippet of the helper's stderr to append to failure messages.
	local function errHint()
		if not errText or errText:match( '^%s*$' ) then return '' end
		local oneLine = errText:gsub( '%s+', ' ' )
		oneLine = oneLine:gsub( '^ ', '' )
		return ' — helper stderr: ' .. Log.redact( oneLine ):sub( 1, 300 )
	end
	if not body or body == '' then
		return nil, 'Google Lens helper produced no output — is Google Chrome installed?' .. errHint()
	end
	-- The helper prints ONE line of JSON on stdout. If that comes back truncated or
	-- garbled, surface a diagnosable message (with the first chunk of what we got)
	-- instead of a bare nil from json.decode — this is the tool's most critical boundary.
	local decoded, _, derr = json.decode( body )
	if type( decoded ) ~= 'table' then
		local snippet = body:sub( 1, 200 ):gsub( '%s+', ' ' )
		return nil, 'Google Lens helper returned unreadable output' ..
			( derr and ( ' (' .. tostring( derr ) .. ')' ) or '' ) .. ': ' .. snippet .. errHint()
	end
	return decoded
end

-- Interpret the helper's decoded stdout (`d`) — or a runHelper error (`err`) — into the
-- tag() contract (name | nil,errString). Pure: no I/O, so it's unit-testable via _test.
--   * runHelper failed          -> (nil, err)
--   * { aborted = true }         -> (nil, LENS_ABORTED)    [window closed / timed out; stop the run]
--   * { cancelled = true }       -> (nil, LENS_CANCELLED)  [user pressed Skip; not an error]
--   * { ok = true, name = 's' }  -> (s)
--   * anything else              -> (nil, 'Google Lens assist: <error|nothing was tagged>')
local function interpretTagResult( d, err )
	if not d then return nil, err end
	if type( d ) == 'table' and d.aborted then return nil, M.LENS_ABORTED end
	if type( d ) == 'table' and d.cancelled then return nil, M.LENS_CANCELLED end
	if type( d ) ~= 'table' or not d.ok or type( d.name ) ~= 'string' or d.name == '' then
		return nil, 'Google Lens assist: ' .. ( d and tostring( d.error ) or 'nothing was tagged' )
	end
	return d.name
end

-- Interpret hash mode's decoded stdout into (hashes|nil, err). `n` is the number
-- of entries the caller listed; dkjson decodes JSON null to nil, so the returned
-- array is rebuilt index-by-index to keep holes addressable. Pure (unit-tested).
local function interpretHashResult( d, err, n )
	if not d then return nil, err end
	if type( d ) ~= 'table' or not d.ok then
		return nil, 'Lens helper hash mode: ' .. ( ( type( d ) == 'table' and d.error )
			and tostring( d.error ) or 'unusable output' )
	end
	local out = {}
	local hashes = type( d.hashes ) == 'table' and d.hashes or {}
	for i = 1, n do
		local h = hashes[ i ]
		out[ i ] = ( type( h ) == 'string' and h ~= '' ) and h or false -- false = no hash
	end
	return out
end

-- lensAssistAdapter(opts) -> { tag(imageFile, pos) -> name|nil,err ; close() }
-- Assistive mode. tag() opens Google Lens in a VISIBLE window (reusing one window across
-- photos, a fresh tab each), shows an "m of n" counter (pos), and blocks until the user
-- highlights a species and presses Tag — returning ONLY that string. The plugin never
-- scrapes the page. close() shuts the reused window down cleanly at the end of a run (so
-- Chrome shows no "didn't shut down correctly" prompt). See helper/ (the Go lens helper).
function M.lensAssistAdapter( opts )
	opts = opts or {}
	local helper = resolveHelper( isWindows(), opts.pluginPath )
	-- No port is passed: the helper owns the assist window's debug port (Chrome
	-- picks a free one; the profile's DevToolsActivePort file is the rendezvous
	-- every invocation shares). A fixed port could be squatted or spoofed.

	return {
		tag = function( imageFile, pos )
			local env = {}
			if pos and pos ~= '' then env[ #env + 1 ] = { 'LENS_ASSIST_POS', pos } end
			local d, err = runHelper( helper, { { value = imageFile } }, env )
			return interpretTagResult( d, err )
		end,
		-- hash( listFile, n ) -> array 1..n of dHash-hex|false, or (nil, err).
		-- Burst detection's pixel step: LENS_HASH mode never opens Chrome — it
		-- only fingerprints the plugin's own rendered JPEGs listed in listFile.
		hash = function( listFile, n )
			local env = { { 'LENS_HASH', '1' }, { 'LENS_HASH_LIST', listFile } }
			local d, err = runHelper( helper, { { value = 'hash', raw = true } }, env )
			return interpretHashResult( d, err, n )
		end,
		-- Best-effort clean shutdown of the reused window; ignores errors (nothing to close).
		close = function()
			runHelper( helper, { { value = 'close', raw = true } }, { { 'LENS_ASSIST_CLOSE', '1' } } )
		end,
	}
end

-- Pure helpers exposed for white-box tests (no LrHttp/LrTasks needed to reach them).
M._test = {
	toLrHeaders = toLrHeaders,
	shQuote = shQuote,
	resolveHelper = resolveHelper,
	bundledHelperCandidates = bundledHelperCandidates,
	interpretTagResult = interpretTagResult,
	interpretHashResult = interpretHashResult,
}

return M
