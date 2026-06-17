#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
scripts/live-accuracy.lua
Measure the REAL Google Lens accuracy — the online counterpart to
scripts/accuracy.lua (which replays the offline representative corpus).

For each ground-truth image present in spec/fixtures/images/ it runs the live
browser helper (scripts/lens), then the real parser -> GBIF (live) -> scorer
pipeline, and scores recall / top-1 / genus / family / false-positives against
spec/fixtures/groundtruth/yuvalsaw.lua. It WRITES NOTHING (no fixtures, no GBIF
captures) — purely a measurement, so it never touches the deterministic offline
corpus or its 100% regression gate.

Setup: `cd scripts/lens && npm i` (puppeteer-core) + Google Chrome installed +
curl; run from the repo root on a RESIDENTIAL network.
Usage:  lua scripts/live-accuracy.lua [--limit N] [--throttle SECS] [--images DIR]
------------------------------------------------------------------------------]]

package.path = table.concat( {
	'src/shared/?.lua', 'build/.deps/?.lua', 'spec/?.lua', package.path,
}, ';' )

local json = require 'dkjson'
local Identify = require 'Identify'
local Taxonomy = require 'Taxonomy'
local Lens = require 'ProviderGoogleLens'
local harness = require 'support.harness'
local groundtruth = require 'fixtures.groundtruth.yuvalsaw'

local opts = { images = 'spec/fixtures/images', limit = nil, throttle = 0 }
do
	local i = 1
	while arg[ i ] do
		local a = arg[ i ]
		if a == '--images' then i = i + 1; opts.images = arg[ i ]
		elseif a == '--limit' then i = i + 1; opts.limit = tonumber( arg[ i ] )
		elseif a == '--throttle' then i = i + 1; opts.throttle = tonumber( arg[ i ] ) or 0
		elseif a:match( '^%-%-images=' ) then opts.images = a:match( '=(.+)$' )
		elseif a:match( '^%-%-limit=' ) then opts.limit = tonumber( a:match( '=(.+)$' ) )
		elseif a:match( '^%-%-throttle=' ) then opts.throttle = tonumber( a:match( '=(.+)$' ) ) or 0
		end
		i = i + 1
	end
end

local function shquote( s ) return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'" end
local function run( cmd ) local h = io.popen( cmd ); local o = h:read( '*a' ); h:close(); return o end
local function fileExists( p ) local f = io.open( p, 'rb' ); if f then f:close(); return true end return false end

-- live GBIF over curl (no recording — pure measurement)
local http = { get = function( url ) return run( 'curl -fsS ' .. shquote( url ) .. ' 2>/dev/null' ) end }

-- the browser helper -> match strings
local function lensSearch( imageFile )
	local raw = run( 'node ' .. shquote( 'scripts/lens/lens-search.js' ) .. ' ' .. shquote( imageFile ) .. ' 2>/dev/null' )
	local d = raw and raw ~= '' and json.decode( raw )
	if type( d ) ~= 'table' then return nil, 'helper: no/!bad output (run `cd scripts/lens && npm i`?)' end
	if not d.ok then return nil, 'helper: ' .. tostring( d.error ) end
	return { overview = d.overview, strings = d.strings }
end

-- group ground truth by image
local byImage, order = {}, {}
for _, r in ipairs( groundtruth ) do
	if not byImage[ r.image ] then byImage[ r.image ] = {}; order[ #order + 1 ] = r.image end
	local e = byImage[ r.image ]
	e[ #e + 1 ] = { common = r.common, scientific = r.scientific, genus = r.genus, family = r.family }
end

print( 'LIVE Google Lens accuracy (real captures; nothing is written)' )
print( ('='):rep( 84 ) )
print( string.format( '%-22s %-7s %-7s %-7s %-7s %-7s %s', 'image', 'recall', 'top-1', 'genus', 'family', 'false+', 'note' ) )
print( ('-'):rep( 84 ) )

local totFound, totExp, totFP, tested, top1, missing = 0, 0, 0, 0, 0, 0
for _, image in ipairs( order ) do
	if opts.limit and tested >= opts.limit then break end
	local path = opts.images .. '/' .. image
	local expected = byImage[ image ]
	if not fileExists( path ) then
		missing = missing + 1
		print( string.format( '%-22s  (not in %s)', image:sub( 1, 22 ), opts.images ) )
	else
		if tested > 0 and opts.throttle > 0 then os.execute( 'sleep ' .. tonumber( opts.throttle ) ) end
		local strings, err = lensSearch( path )
		tested = tested + 1
		if not strings then
			print( string.format( '%-22s %-7s %-7s %-7s %-7s %-7s %s', image:sub( 1, 22 ), '-', '-', '-', '-', '-', err ) )
		else
			local result = Identify.run( Lens.parse( strings ), {
				resolve = function( c ) return Taxonomy.resolve( c, { http = http, cache = {} } ) end,
			} )
			local m = harness.metrics( { expected = expected }, result )
			totFound = totFound + m.found; totExp = totExp + m.total; totFP = totFP + m.falsePositives
			if m.top1 then top1 = top1 + 1 end
			print( string.format( '%-22s %d/%-5d %-7s %d/%-5d %d/%-5d %-7d %s',
				image:sub( 1, 22 ), m.found, m.total, m.top1 and 'yes' or 'no',
				m.genus, m.total, m.family, m.total, m.falsePositives, m.decision == 'apply' and '' or '(review)' ) )
		end
	end
end

print( ('-'):rep( 84 ) )
print( string.format( 'TESTED %d   recall %d/%d (%.0f%%)   top-1 %d/%d   false+ %d   missing-image %d',
	tested, totFound, totExp, 100 * totFound / math.max( 1, totExp ), top1, tested, totFP, missing ) )
