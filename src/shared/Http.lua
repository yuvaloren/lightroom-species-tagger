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
-- to the bundled Node helper (scripts/lens/lens-search.js), which drives the
-- user's installed Chrome to render the results and prints JSON { ok, strings }.
-- This returns a `lensSearch( imageFile ) -> strings[]|nil, err` function for the
-- provider. macOS/Linux only for now (POSIX quoting); needs Node + Google Chrome.
--   opts.helperPath : absolute path to lens-search.js (bundled in the .lrplugin)
--   opts.nodePath   : optional absolute path to `node`
function M.lensSearchAdapter( opts )
	local LrTasks = import 'LrTasks'
	local LrPathUtils = import 'LrPathUtils'
	local LrFileUtils = import 'LrFileUtils'
	local json = require 'dkjson'
	opts = opts or {}
	local helper = opts.helperPath

	local function sh( s ) return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'" end
	local function exists( p ) local f = p and io.open( p, 'rb' ); if f then f:close(); return true end return false end
	-- GUI apps get a minimal PATH, so resolve `node` to a real path.
	local candidates = { '/opt/homebrew/bin/node', '/usr/local/bin/node', '/usr/bin/node' }
	if opts.nodePath and opts.nodePath ~= '' then table.insert( candidates, 1, opts.nodePath ) end
	local node = 'node'
	for _, p in ipairs( candidates ) do
		if exists( p ) then node = p; break end
	end

	return function( imageFile, lat, lng )
		if not exists( helper ) then return nil, 'Lens helper not found at ' .. tostring( helper ) end
		local out = LrPathUtils.child( LrPathUtils.getStandardFilePath( 'temp' ),
			string.format( 'speciestagger-lens-%d.json', os.time() ) )
		-- pass the photo's location so Lens favours species that occur there
		local geo = ( lat and lng ) and ( ' ' .. tostring( lat ) .. ' ' .. tostring( lng ) ) or ''
		local cmd = node .. ' ' .. sh( helper ) .. ' ' .. sh( imageFile ) .. geo .. ' > ' .. sh( out ) .. ' 2>/dev/null'
		LrTasks.execute( cmd )
		local f = io.open( out, 'rb' )
		local body = f and f:read( '*a' )
		if f then f:close() end
		LrFileUtils.delete( out )
		if not body or body == '' then
			return nil, 'Google Lens helper produced no output — is Node and Google Chrome installed? ' ..
				'(see scripts/lens/README), or use the Pl@ntNet / Vision backend.'
		end
		local d = json.decode( body )
		if type( d ) ~= 'table' or not d.ok then
			return nil, 'Google Lens: ' .. ( d and tostring( d.error ) or 'helper error' )
		end
		return { overview = d.overview, strings = d.strings }
	end
end

return M
