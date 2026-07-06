#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
scripts/record-fixture.lua
Capture a REAL fixture from a live image so the offline corpus reflects what
Google Lens actually returns. Saves the Lens response and every GBIF response the
pipeline touches, then prints a manifest stub to paste into
spec/fixtures/manifest.lua (fill in the `expected` ground truth yourself).

Usage:
  lua scripts/record-fixture.lua <image> [--id <slug>]

Google Lens needs no key, BUT Google blocks automated requests from datacenter /
shared IPs — record fixtures from a normal residential connection. Requirements:
`node` + Google Chrome (for the Lens helper) and `curl` on PATH (used here only —
the plugin itself uses LrHttp). Run from the repo root after
`lua build/build.lua --fetch-deps` (for dkjson).
------------------------------------------------------------------------------]]

package.path = table.concat( {
	'src/shared/?.lua', 'output/deps/?.lua', package.path,
}, ';' )

local json = require 'dkjson'
local Providers = require 'Providers'
local SpeciesParser = require 'SpeciesParser'
local Taxonomy = require 'Taxonomy'

--------------------------------------------------------------------------------
-- args

local image, id
do
	local i = 1
	while arg[ i ] do
		local a = arg[ i ]
		if a == '--id' then i = i + 1; id = arg[ i ]
		elseif a:match( '^%-%-id=' ) then id = a:match( '=(.+)$' )
		elseif a == '--provider' then i = i + 1 -- accepted + ignored (Lens is the only backend)
		elseif a:match( '^%-%-provider=' ) then -- ditto
		elseif not image then image = a end
		i = i + 1
	end
end

local function die( m ) io.stderr:write( 'record-fixture: ' .. m .. '\n' ); os.exit( 1 ) end
if not image then die( 'need an image path (see header for usage)' ) end
id = id or ( image:match( '([^/\\]+)%.%w+$' ) or 'fixture' )

--------------------------------------------------------------------------------
-- a curl-backed GBIF getter (the plugin itself uses LrHttp; this is dev-only)

local function shquote( s ) return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'" end

local function run( cmd )
	local h = io.popen( cmd )
	local out = h:read( '*a' )
	h:close()
	return out
end

local function curlGet( url )
	return run( 'curl -fsS ' .. shquote( url ) .. ' 2>/dev/null' )
end

local FIX = 'spec/fixtures'
local function save( relpath, body )
	local path = FIX .. '/' .. relpath
	local f = assert( io.open( path, 'wb' ), 'cannot write ' .. path )
	f:write( body )
	f:close()
	print( '  saved ' .. relpath )
end

local function slug( s )
	return ( ( s or '' ):lower():gsub( '[^%w]+', '_' ):gsub( '^_+', '' ):gsub( '_+$', '' ) )
end

--------------------------------------------------------------------------------
-- 1) Lens response (saved as the JSON the offline parser will replay)

print( 'Recording Google Lens fixture for ' .. image )

-- Lens has no API + JS-rendered results, so capture via the browser helper
-- (scripts/lens): it returns JSON { ok, overview, strings } — the strings + AI
-- overview are what the offline parser harvests, so save them as the fixture.
-- Needs node + Chrome.
local raw = run( 'node ' .. shquote( 'scripts/lens/lens-search.js' ) .. ' ' .. shquote( image ) .. ' 2>/dev/null' )
local d = raw and raw ~= '' and json.decode( raw )
if type( d ) ~= 'table' then die( 'lens helper produced no/!bad output (run `cd scripts/lens && npm i`?)' ) end
if not d.ok then die( 'lens helper: ' .. tostring( d.error ) ) end
local decoded = { overview = d.overview, strings = d.strings }
local providerRel = 'lens/' .. id .. '.json'
save( providerRel, json.encode( decoded, { indent = true } ) )

--------------------------------------------------------------------------------
-- 2) GBIF responses for each candidate the pipeline would resolve

local Lens = Providers.get( 'lens' )
local cands = SpeciesParser.candidates( Lens.parse( decoded ), { max = 12 } )

local function recordVern( key )
	if not key then return end
	save( 'gbif/vern_' .. key .. '.json', curlGet( Taxonomy.vernacularUrl( key ) ) )
end

print( 'recording GBIF responses for ' .. #cands .. ' candidates…' )
for _, c in ipairs( cands ) do
	if c.kind == 'scientific' then
		local body = curlGet( Taxonomy.matchUrl( c.name ) )
		save( 'gbif/match_' .. slug( c.name ) .. '.json', body )
		local m = json.decode( body )
		if m and m.usageKey and m.matchType ~= 'NONE' then recordVern( m.usageKey ) end
	else
		local body = curlGet( Taxonomy.searchUrl( c.name ) )
		save( 'gbif/search_' .. slug( c.name ) .. '.json', body )
		local r = Taxonomy._test.pickSearchResult( json.decode( body ), c.name )
		if r and r.canonicalName then
			save( 'gbif/match_' .. slug( r.canonicalName ) .. '.json',
				curlGet( Taxonomy.matchUrl( r.canonicalName ) ) )
			recordVern( r.usageKey )
		end
	end
end

--------------------------------------------------------------------------------
-- 3) manifest stub

print( '\nAdd this case to spec/fixtures/manifest.lua and fill in `expected`:\n' )
print( string.format( [[	{
		id = %q,
		image = %q,
		provider = 'lens',
		response = %q,
		expected = {
			{ common = '?', scientific = '?', genus = '?', family = '?' },
		},
	},]], id .. '_lens', ( image:match( '([^/\\]+)$' ) or image ), providerRel ) )
