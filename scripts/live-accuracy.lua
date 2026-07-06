#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
scripts/live-accuracy.lua
Measure (and tune against) REAL Google Lens accuracy — capture once, replay offline.

Google Lens is slow AND non-deterministic (different visual matches each call), so
hitting it repeatedly to tune parsing/scoring is wasteful and noisy. Instead:

  --capture : run the live browser helper for each ground-truth image and SAVE
              Google's output ({ overview, strings }) to a per-image cache. Run
              once (residential network; needs scripts/lens deps + Chrome).
  (replay)  : default. Replay the CACHED Lens output through the real parser ->
              GBIF -> scorer and score it. No Google, deterministic, instant — so
              you can edit the parser/scorer and re-run to see the effect.
  --sweep   : CALIBRATION. Replay the cache and print precision / recall / false+ at
              every auto-apply threshold, using the plugin's exact confidence gate
              (Identify.confidentAt). This is how you ground the threshold in real
              data rather than guessing — see docs/SCORING.md.

GBIF responses are cached too (deterministic; fetched live on a cache miss, e.g.
when a parser change surfaces a new candidate), so replay needs no network at all
once warm. Accuracy is judged on the accepted Latin (scientific) name + genus +
family ONLY — common names are ignored (a species has many acceptable ones).

Usage:
  lua scripts/live-accuracy.lua --groundtruth fixtures.groundtruth.monterey --capture
  lua scripts/live-accuracy.lua --groundtruth fixtures.groundtruth.monterey   # replay+tune
  lua scripts/live-accuracy.lua --groundtruth fixtures.groundtruth.monterey --sweep
Options: --groundtruth <module>  --images <dir>  --cache <dir>  --limit N  --throttle S  --sweep
------------------------------------------------------------------------------]]

package.path = table.concat( { 'src/shared/?.lua', 'output/deps/?.lua', 'spec/?.lua', package.path }, ';' )

local json = require 'dkjson'
local Identify = require 'Identify'
local Taxonomy = require 'Taxonomy'
local Lens = require 'ProviderGoogleLens'
local harness = require 'support.harness'

local opts = { images = 'spec/fixtures/images', cache = nil, limit = nil, throttle = 0,
	capture = false, sweep = false, groundtruth = 'fixtures.groundtruth.monterey' }
do
	local i = 1
	while arg[ i ] do
		local a = arg[ i ]
		if a == '--capture' then opts.capture = true
		elseif a == '--sweep' then opts.sweep = true
		elseif a == '--images' then i = i + 1; opts.images = arg[ i ]
		elseif a == '--cache' then i = i + 1; opts.cache = arg[ i ]
		elseif a == '--groundtruth' then i = i + 1; opts.groundtruth = arg[ i ]
		elseif a == '--limit' then i = i + 1; opts.limit = tonumber( arg[ i ] )
		elseif a == '--throttle' then i = i + 1; opts.throttle = tonumber( arg[ i ] ) or 0
		elseif a:match( '^%-%-images=' ) then opts.images = a:match( '=(.+)$' )
		elseif a:match( '^%-%-cache=' ) then opts.cache = a:match( '=(.+)$' )
		elseif a:match( '^%-%-groundtruth=' ) then opts.groundtruth = a:match( '=(.+)$' )
		elseif a:match( '^%-%-limit=' ) then opts.limit = tonumber( a:match( '=(.+)$' ) )
		elseif a:match( '^%-%-throttle=' ) then opts.throttle = tonumber( a:match( '=(.+)$' ) ) or 0
		end
		i = i + 1
	end
end
local groundtruth = require( opts.groundtruth )
opts.cache = opts.cache or ( 'spec/fixtures/live/' .. ( opts.groundtruth:match( '([^.]+)$' ) or 'corpus' ) )

local function shquote( s ) return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'" end
local function run( cmd ) local h = io.popen( cmd ); local o = h:read( '*a' ); h:close(); return o end
local function exists( p ) local f = io.open( p, 'rb' ); if f then f:close(); return true end return false end
local function readFile( p ) local f = io.open( p, 'rb' ); if not f then return nil end local b = f:read( '*a' ); f:close(); return b end
local function writeFile( p, s ) local f = assert( io.open( p, 'wb' ) ); f:write( s ); f:close() end
os.execute( 'mkdir -p ' .. shquote( opts.cache .. '/gbif' ) )

local function slug( s )
	return ( ( s or '' ):lower():gsub( '%%20', ' ' ):gsub( '+', ' ' ):gsub( '[^%w]+', '_' ):gsub( '^_+', '' ):gsub( '_+$', '' ) )
end
local function param( url, key )
	local v = url:match( '[?&]' .. key .. '=([^&]*)' )
	if not v then return nil end
	return ( v:gsub( '+', ' ' ):gsub( '%%(%x%x)', function( h ) return string.char( tonumber( h, 16 ) ) end ) )
end
local function gbifRel( url )
	if url:find( '/species/match', 1, true ) then return 'gbif/match_' .. slug( param( url, 'name' ) ) .. '.json'
	elseif url:find( '/vernacularNames', 1, true ) then local k = url:match( '/species/(%d+)/vernacularNames' ); return k and ( 'gbif/vern_' .. k .. '.json' )
	elseif url:find( '/species/search', 1, true ) then return 'gbif/search_' .. slug( param( url, 'q' ) ) .. '.json' end
end

-- GBIF: serve from the cache; on a miss fetch live and cache (deterministic).
local gbifHttp = { get = function( url )
	local rel = gbifRel( url )
	if rel and exists( opts.cache .. '/' .. rel ) then return readFile( opts.cache .. '/' .. rel ) end
	local body = run( 'curl -fsS ' .. shquote( url ) .. ' 2>/dev/null' )
	if rel and body and body ~= '' then writeFile( opts.cache .. '/' .. rel, body ) end
	return body
end }

-- Lens: --capture runs the live helper and saves Google's output; otherwise read
-- the cached capture (never re-hit Google).
local function lensFor( image, path, lat, lng )
	local cacheFile = opts.cache .. '/' .. image .. '.lens.json'
	if not opts.capture then
		local body = readFile( cacheFile )
		if not body then return nil, 'no capture (run --capture first)' end
		local d = json.decode( body )
		return d and { overview = d.overview, strings = d.strings }
	end
	local cmd = 'node ' .. shquote( 'scripts/lens/lens-search.js' ) .. ' ' .. shquote( path )
	if lat and lng then cmd = cmd .. ' ' .. tostring( lat ) .. ' ' .. tostring( lng ) end
	local raw = run( cmd .. ' 2>/dev/null' )
	local d = raw and raw ~= '' and json.decode( raw )
	if type( d ) ~= 'table' or not d.ok then return nil, 'helper: ' .. ( d and tostring( d.error ) or 'no/!bad output' ) end
	writeFile( cacheFile, json.encode( { overview = d.overview, strings = d.strings }, { indent = true } ) )
	return { overview = d.overview, strings = d.strings }
end

local byImage, geo, order = {}, {}, {}
for _, r in ipairs( groundtruth ) do
	if not byImage[ r.image ] then byImage[ r.image ] = {}; order[ #order + 1 ] = r.image end
	local e = byImage[ r.image ]
	e[ #e + 1 ] = { common = r.common, scientific = r.scientific, genus = r.genus, family = r.family }
	if r.lat and r.lng then geo[ r.image ] = { r.lat, r.lng } end
end

print( ( '%s Google Lens accuracy — %s (cache: %s)' ):format(
	opts.capture and 'CAPTURE+score' or 'REPLAY', opts.groundtruth, opts.cache ) )
print( 'recall / top-1 / false+ judged on the accepted Latin name + genus + family only.' )
print( ('='):rep( 84 ) )
print( string.format( '%-22s %-7s %-7s %-7s %-7s %-7s %s', 'image', 'recall', 'top-1', 'genus', 'family', 'false+', 'note' ) )
print( ('-'):rep( 84 ) )

local totFound, totExp, totFP, tested, top1, missing = 0, 0, 0, 0, 0, 0
local collected = {} -- { result, expected } per tested image, for the --sweep calibration
for _, image in ipairs( order ) do
	if opts.limit and tested >= opts.limit then break end
	local path = opts.images .. '/' .. image
	local expected = byImage[ image ]
	if opts.capture and not exists( path ) then
		missing = missing + 1
		print( ( '%-22s  (image not in %s)' ):format( image:sub( 1, 22 ), opts.images ) )
	else
		if opts.capture and tested > 0 and opts.throttle > 0 then os.execute( 'sleep ' .. tonumber( opts.throttle ) ) end
		local g = geo[ image ]
		local strings, err = lensFor( image, path, g and g[ 1 ], g and g[ 2 ] )
		if not strings then
			print( ( '%-22s %-7s %-7s %-7s %-7s %-7s %s' ):format( image:sub( 1, 22 ), '-', '-', '-', '-', '-', err ) )
		else
			tested = tested + 1
			local result = Identify.run( Lens.parse( strings ), {
				resolve = function( c ) return Taxonomy.resolve( c, { http = gbifHttp, cache = {} } ) end,
			} )
			collected[ #collected + 1 ] = { result = result, expected = expected }
			local m = harness.metrics( { expected = expected }, result )
			totFound = totFound + m.found; totExp = totExp + m.total; totFP = totFP + m.falsePositives
			if m.top1 then top1 = top1 + 1 end
			print( ( '%-22s %d/%-5d %-7s %d/%-5d %d/%-5d %-7d %s' ):format(
				image:sub( 1, 22 ), m.found, m.total, m.top1 and 'yes' or 'no',
				m.genus, m.total, m.family, m.total, m.falsePositives, m.decision == 'apply' and '' or '(review)' ) )
		end
	end
end

print( ('-'):rep( 84 ) )
print( ( 'TESTED %d   recall %d/%d (%.0f%%)   top-1 %d/%d   false+ %d%s' ):format(
	tested, totFound, totExp, 100 * totFound / math.max( 1, totExp ), top1, tested, totFP,
	missing > 0 and ( '   missing-image ' .. missing ) or '' ) )
if not opts.capture and tested == 0 then
	print( '\nNothing cached yet — run with --capture once (residential network) to fetch + save Lens output.' )
end

--------------------------------------------------------------------------------
-- --sweep: threshold calibration. For each candidate auto-apply threshold, report
-- precision / recall / false-positives over the tested images, using the plugin's
-- exact confidence gate (Identify.confidentAt). Precision = correct auto-tags /
-- all auto-tags; recall = expected species recovered / all expected. Pick the
-- threshold that gives the precision you want — that's what to set in the plugin.
if opts.sweep and tested > 0 then
	local function normSci( s ) return ( tostring( s or '' ):gsub( '%s+', ' ' ):gsub( '^%s+', '' ):gsub( '%s+$', '' ):lower() ) end
	print( '\n' .. ('='):rep( 60 ) )
	print( 'THRESHOLD CALIBRATION (Identify.confidentAt over the cache)' )
	print( 'precision = correct auto-tags / all auto-tags; recall = expected found / all expected' )
	print( ('-'):rep( 60 ) )
	print( string.format( '%-11s %-9s %-9s %-7s %-7s %s', 'threshold', 'precision', 'recall', 'tags', 'correct', 'false+' ) )
	print( ('-'):rep( 60 ) )
	local t = 0.30
	while t <= 0.951 do
		local tags, correct, expTotal, expFound = 0, 0, 0, 0
		for _, c in ipairs( collected ) do
			local exp = {}
			for _, e in ipairs( c.expected ) do exp[ normSci( e.scientific ) ] = true; expTotal = expTotal + 1 end
			local found = {}
			for _, a in ipairs( c.result.results ) do
				if Identify.confidentAt( a, t, nil, c.result.hasAuthoritative ) then
					tags = tags + 1
					local key = normSci( a.taxon.scientificName )
					if exp[ key ] then correct = correct + 1; found[ key ] = true end
				end
			end
			for k in pairs( found ) do if exp[ k ] then expFound = expFound + 1 end end
		end
		local precision = tags > 0 and ( correct / tags ) or 1.0
		local recall = expTotal > 0 and ( expFound / expTotal ) or 0
		print( string.format( '%-11.2f %-9.2f %-9.2f %-7d %-7d %d',
			t, precision, recall, tags, correct, tags - correct ) )
		t = t + 0.05
	end
	print( ('-'):rep( 60 ) )
	print( 'Set "Auto-tag confidence" in the plugin to the threshold whose precision/recall you prefer.' )
end
