#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
scripts/capture-corpus.lua
Capture REAL Google Lens output for the ground-truth corpus and save it as
CHECKED-IN regression fixtures under spec/fixtures/captures/<variant>/.

Unlike scripts/live-accuracy.lua (whose captures land in the gitignored
spec/fixtures/live/ for private tuning), this writes a committed, self-contained
fixture per image — {expected taxonomy, the exact query used, Google's AI overview
+ visible match strings} — so the parser/scorer has a durable, public regression
set. The corpus is open iNaturalist data (see scripts/build-inat-corpus.lua), so
the captured page text is fine to check in.

Each run captures ONE variant — a specific way of adding the location/keyword hint
to the visual search (or none). Run it once per variant you want in the suite:

  # baseline: pure image search, no text hint  (the first thing to check in)
  lua scripts/capture-corpus.lua --groundtruth fixtures.groundtruth.worldwide \
      --variant baseline --limit 40

  # location hint, framed as "in <place>" (the current default framing)
  lua scripts/capture-corpus.lua --groundtruth fixtures.groundtruth.worldwide \
      --variant loc-in --use-place --strategy in --limit 40

  # an operator-style framing to compare against  ("location: <place>")
  lua scripts/capture-corpus.lua --groundtruth fixtures.groundtruth.worldwide \
      --variant loc-label --use-place --strategy location --limit 40

REQUIREMENTS: a RESIDENTIAL network + Google Chrome + `cd scripts/lens && npm ci`
(Google blocks datacenter IPs, and the helper drives a visible Chrome window). It
opens a Chrome window/tab per image — use --keep-tabs for one shared window, and a
sane --limit + --throttle so Google doesn't rate-limit ("unusual traffic"). Already-
captured images are SKIPPED (resume-friendly); pass --refresh to recapture.

Options:
  --groundtruth <module>  fixtures.groundtruth.<name>  (required)
  --variant <name>        output subdir under spec/fixtures/captures/ (required)
  --use-place             add the corpus place as the location hint
  --strategy <id>         location framing: in|photographed|seen|bare|location|
                          location-info|none  (see src/shared/LensQuery.lua)
  --other <text>          extra identifying info added to every query (optional)
  --limit N               capture at most N images (default: all)
  --taxa-none             (no taxon filter; the corpus is already balanced)
  --throttle S            seconds between captures (default 4)
  --keep-tabs             reuse one Chrome window (a new tab per image)
  --images <dir>          image dir (default spec/fixtures/images)
  --out <dir>             captures root (default spec/fixtures/captures)
  --refresh               recapture even if a fixture already exists
------------------------------------------------------------------------------]]

package.path = table.concat( { 'src/shared/?.lua', 'output/deps/?.lua', 'spec/?.lua', package.path }, ';' )

local json = require 'dkjson'
local LensQuery = require 'LensQuery'

local opts = {
	groundtruth = nil, variant = nil, usePlace = false, strategy = LensQuery.DEFAULT_STRATEGY,
	other = nil, limit = nil, throttle = 4, keepTabs = false, noGeo = false, geoPlace = false,
	images = 'spec/fixtures/images', out = 'spec/fixtures/captures', refresh = false,
}
do
	local i = 1
	while arg[ i ] do
		local a = arg[ i ]
		if a == '--groundtruth' then i = i + 1; opts.groundtruth = arg[ i ]
		elseif a == '--variant' then i = i + 1; opts.variant = arg[ i ]
		elseif a == '--use-place' then opts.usePlace = true
		elseif a == '--strategy' then i = i + 1; opts.strategy = arg[ i ]
		elseif a == '--other' then i = i + 1; opts.other = arg[ i ]
		-- Location CHANNEL (how the place reaches Lens), independent of --use-place text:
		--   default    : pass the corpus lat/lng as browser geolocation (GPS-like).
		--   --no-geo    : pass NO location at all (simulates a GPS-less photo, no hint).
		--   --geo-place : pass the corpus PLACE NAME so the helper geocodes it -> geolocation
		--                 (this is how a user-typed location would be delivered).
		elseif a == '--no-geo' then opts.noGeo = true
		elseif a == '--geo-place' then opts.geoPlace = true
		elseif a == '--limit' then i = i + 1; opts.limit = tonumber( arg[ i ] )
		elseif a == '--throttle' then i = i + 1; opts.throttle = tonumber( arg[ i ] ) or opts.throttle
		elseif a == '--keep-tabs' then opts.keepTabs = true
		elseif a == '--images' then i = i + 1; opts.images = arg[ i ]
		elseif a == '--out' then i = i + 1; opts.out = arg[ i ]
		elseif a == '--refresh' then opts.refresh = true
		end
		i = i + 1
	end
end
if not opts.groundtruth or not opts.variant then
	io.stderr:write( 'usage: --groundtruth fixtures.groundtruth.<name> --variant <name> [--use-place --strategy <id>] [--limit N]\n' )
	os.exit( 1 )
end

local groundtruth = require( opts.groundtruth )
local outDir = opts.out .. '/' .. opts.variant

local function shquote( s ) return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'" end
local function run( cmd ) local h = io.popen( cmd ); local o = h:read( '*a' ); h:close(); return o end
local function exists( p ) local f = io.open( p, 'rb' ); if f then f:close(); return true end return false end
local function writeFile( p, s ) local f = assert( io.open( p, 'wb' ) ); f:write( s ); f:close() end
os.execute( 'mkdir -p ' .. shquote( outDir ) )

-- Run the Lens helper for one image with an optional text query + a location channel.
-- geo is nil | { lat=, lng= } (browser geolocation) | { place='…' } (helper geocodes it).
-- Returns Google's decoded { ok, overview, strings } (or nil, error).
local function captureOne( image, geo, query )
	local path = opts.images .. '/' .. image
	if not exists( path ) then return nil, 'image missing (run build-inat-corpus --fetch)' end
	local env = {}
	if query and query ~= '' then env[ #env + 1 ] = 'LENS_QUERY=' .. shquote( query ) end
	if opts.keepTabs then env[ #env + 1 ] = 'LENS_KEEP_TABS=1' end
	local cmd = table.concat( env, ' ' ) .. ( #env > 0 and ' ' or '' ) ..
		'node ' .. shquote( 'scripts/lens/lens-search.js' ) .. ' ' .. shquote( path )
	if geo and geo.lat and geo.lng then
		cmd = cmd .. ' ' .. tostring( geo.lat ) .. ' ' .. tostring( geo.lng )
	elseif geo and geo.place and geo.place ~= '' then
		cmd = cmd .. ' ' .. shquote( geo.place ) -- helper geocodes this to coords + geolocation
	end
	local raw = run( cmd .. ' 2>/dev/null' )
	local d = raw and raw ~= '' and json.decode( raw )
	if type( d ) ~= 'table' then return nil, 'helper: no/!bad output' end
	if not d.ok then return nil, 'helper: ' .. tostring( d.error or ( d.challenged and 'Google challenge' ) or 'not ok' ), d end
	return d
end

local geoChannel = opts.geoPlace and 'geocoded place name -> geolocation'
	or opts.noGeo and 'none (GPS-less photo)' or 'corpus lat/lng -> geolocation'
print( ( 'CAPTURE variant "%s" -> %s' ):format( opts.variant, outDir ) )
print( ( 'location channel: %s   text framing: %s%s   other: %s' ):format(
	geoChannel, opts.strategy, opts.usePlace and '' or ' (unused — no --use-place)', opts.other or '-' ) )
print( ('-'):rep( 78 ) )

local done, skipped, failed, challenged = 0, 0, 0, false
for _, r in ipairs( groundtruth ) do
	if opts.limit and done >= opts.limit then break end
	local dest = outDir .. '/' .. r.image .. '.json'
	if exists( dest ) and not opts.refresh then
		skipped = skipped + 1
	else
		local query = opts.usePlace
			and LensQuery.compose { location = r.place, other = opts.other, strategy = opts.strategy }
			or LensQuery.compose { other = opts.other, strategy = opts.strategy }
		local geo = opts.geoPlace and { place = r.place }
			or opts.noGeo and nil
			or { lat = r.lat, lng = r.lng }
		local d, err, meta = captureOne( r.image, geo, query )
		if not d then
			failed = failed + 1
			print( ( '  ✗ %-22s %s' ):format( r.image, err ) )
			if meta and meta.challenged then
				challenged = true
				print( '\nGoogle issued a challenge (IP rate-limited). Stopping — wait a while and resume ' ..
					'(already-captured images are skipped).' )
				break
			end
		else
			local fixture = {
				image = r.image, common = r.common, scientific = r.scientific,
				genus = r.genus, family = r.family, place = r.place,
				variant = opts.variant, strategy = opts.usePlace and opts.strategy or 'none',
				geo_channel = geoChannel, query = query or '',
				overview = d.overview or '', strings = d.strings or {},
				source = r.source, observation = r.observation,
			}
			writeFile( dest, json.encode( fixture, { indent = true } ) )
			done = done + 1
			print( ( '  ✓ %-22s %-24s q=%s' ):format(
				r.image, ( r.scientific or '' ):sub( 1, 24 ), query and ( '"' .. query .. '"' ) or '(none)' ) )
		end
		if opts.throttle > 0 and not challenged then run( 'sleep ' .. tostring( opts.throttle ) ) end
	end
end

print( ('-'):rep( 78 ) )
print( ( 'captured %d, skipped %d (already present), failed %d%s' ):format(
	done, skipped, failed, challenged and ' — STOPPED on Google challenge' or '' ) )
print( ( 'fixtures in %s/  — commit these to grow the regression suite.' ):format( outDir ) )
