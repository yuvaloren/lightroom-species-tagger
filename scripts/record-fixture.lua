#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
scripts/record-fixture.lua
Capture a REAL fixture from a live image so the offline corpus reflects what the
backends actually return. Saves the provider response and every GBIF response the
pipeline touches, then prints a manifest stub to paste into
spec/fixtures/manifest.lua (fill in the `expected` ground truth yourself).

Usage:
  lua scripts/record-fixture.lua <image> --provider lens
  PLANTNET_KEY=...      lua scripts/record-fixture.lua <image> --provider plantnet
  GOOGLE_VISION_KEY=... lua scripts/record-fixture.lua <image> --provider vision

The `lens` backend talks to Google directly and needs no key, BUT Google blocks
automated requests from datacenter / shared IPs — record Lens fixtures from a
normal residential connection or it will just 403. Requirements: `curl` on PATH
(used here only — the plugin itself uses LrHttp). Run from the repo root after
`lua build/build.lua --fetch-deps` (for dkjson).
------------------------------------------------------------------------------]]

package.path = table.concat( {
	'src/shared/?.lua', 'build/.deps/?.lua', package.path,
}, ';' )

local json = require 'dkjson'
local Providers = require 'Providers'
local SpeciesParser = require 'SpeciesParser'
local Taxonomy = require 'Taxonomy'
local Base64 = require 'Base64'

--------------------------------------------------------------------------------
-- args

local image, provider, id
do
	local i = 1
	while arg[ i ] do
		local a = arg[ i ]
		if a == '--provider' then i = i + 1; provider = arg[ i ]
		elseif a == '--id' then i = i + 1; id = arg[ i ]
		elseif a:match( '^%-%-provider=' ) then provider = a:match( '=(.+)$' )
		elseif a:match( '^%-%-id=' ) then id = a:match( '=(.+)$' )
		elseif not image then image = a end
		i = i + 1
	end
end
provider = provider or 'lens'

local function die( m ) io.stderr:write( 'record-fixture: ' .. m .. '\n' ); os.exit( 1 ) end
if not image then die( 'need an image path (see header for usage)' ) end
id = id or ( image:match( '([^/\\]+)%.%w+$' ) or 'fixture' )

--------------------------------------------------------------------------------
-- a curl-backed http adapter (mirrors Http.lua's get/post/postMultipart shape)

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

local http = {
	get = curlGet,
	post = function( url, body, headers )
		local tmp = os.tmpname()
		local f = io.open( tmp, 'wb' ); f:write( body ); f:close()
		local hs = ''
		for k, v in pairs( headers or {} ) do hs = hs .. ' -H ' .. shquote( k .. ': ' .. v ) end
		local out = run( 'curl -fsS -X POST' .. hs .. ' --data-binary @' .. shquote( tmp ) ..
			' ' .. shquote( url ) .. ' 2>/dev/null' )
		os.remove( tmp )
		return out
	end,
	-- -L so we follow Google Lens's upload->results redirect like LrHttp does.
	postMultipart = function( url, parts, headers )
		local fs = ''
		for _, p in ipairs( parts ) do
			if p.filePath then
				fs = fs .. ' -F ' .. shquote( p.name .. '=@' .. p.filePath ..
					( p.contentType and ( ';type=' .. p.contentType ) or '' ) )
			else
				fs = fs .. ' -F ' .. shquote( p.name .. '=' .. p.value )
			end
		end
		local hs = ''
		for k, v in pairs( headers or {} ) do hs = hs .. ' -H ' .. shquote( k .. ': ' .. v ) end
		return run( 'curl -fsSL' .. hs .. fs .. ' ' .. shquote( url ) .. ' 2>/dev/null' )
	end,
}

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

local function readBytes( path )
	local f = assert( io.open( path, 'rb' ), 'cannot read ' .. path )
	local b = f:read( '*a' ); f:close(); return b
end

--------------------------------------------------------------------------------
-- 1) provider response (saved as the JSON the offline parser will replay)

print( 'Recording ' .. provider .. ' fixture for ' .. image )
local decoded, providerRel

if provider == 'lens' then
	local Lens = Providers.get( 'lens' )
	-- Reuse the real provider flow: upload bytes, follow the redirect, extract the
	-- embedded results JSON. Save THAT (not the multi-MB HTML page).
	local d, err = Lens.fetch( { imageFile = image, hl = 'en', country = 'us' }, { http = http } )
	if not d then die( 'lens fetch failed: ' .. tostring( err ) ) end
	decoded = d
	providerRel = 'lens/' .. id .. '.json'
	save( providerRel, json.encode( decoded, { indent = true } ) )
elseif provider == 'plantnet' then
	local PlantNet = Providers.get( 'plantnet' )
	local key = os.getenv( 'PLANTNET_KEY' ) or die( 'set PLANTNET_KEY' )
	local body = http.postMultipart(
		PlantNet.buildUrl { apiKey = key, project = 'all' },
		PlantNet.buildParts { imageFile = image } )
	if not body or body == '' then die( 'no response from Pl@ntNet' ) end
	providerRel = 'plantnet/' .. id .. '.json'
	save( providerRel, body )
	decoded = json.decode( body )
elseif provider == 'vision' then
	local Vision = Providers.get( 'vision' )
	local key = os.getenv( 'GOOGLE_VISION_KEY' ) or die( 'set GOOGLE_VISION_KEY' )
	local body = http.post( Vision.endpointWithKey( key ),
		Vision.buildBody( Base64.encode( readBytes( image ) ), 15 ),
		{ [ 'Content-Type' ] = 'application/json' } )
	if not body or body == '' then die( 'no response from Google Vision' ) end
	providerRel = 'vision/' .. id .. '.json'
	save( providerRel, body )
	decoded = json.decode( body )
else
	die( 'unknown provider: ' .. provider .. ' (lens | plantnet | vision)' )
end

if not decoded then die( 'could not decode the provider response' ) end

--------------------------------------------------------------------------------
-- 2) GBIF responses for each candidate the pipeline would resolve

local prov = Providers.get( provider )
local cands = SpeciesParser.candidates( prov.parse( decoded ), { max = 12 } )

local function recordVern( key )
	if not key then return end
	save( 'gbif/vern_' .. key .. '.json', curlGet( Taxonomy.vernacularUrl( key ) ) )
end

print( 'recording GBIF responses for ' .. #cands .. ' candidates…' )
for _, c in ipairs( cands ) do
	if c.kind == 'scientific' then
		local body = curlGet( Taxonomy.matchUrl( c.name ) )
		save( 'gbif/match_' .. slug( c.name ) .. '.json', body )
		local d = json.decode( body )
		if d and d.usageKey and d.matchType ~= 'NONE' then recordVern( d.usageKey ) end
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
		provider = %q,
		response = %q,
		expected = {
			{ common = '?', scientific = '?', genus = '?', family = '?' },
		},
	},]], id .. '_' .. provider, ( image:match( '([^/\\]+)$' ) or image ), provider, providerRel ) )
