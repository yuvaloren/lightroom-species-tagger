#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
scripts/build-inat-corpus.lua
Build an open, reproducible ground-truth set from iNaturalist research-grade
observations (community-verified, open-licensed). For each distinct species it
records the accepted scientific name / genus / family (resolved through GBIF, like
the pipeline), the observation's location (a human-readable place + lat/lng), and —
so the corpus can be recreated byte-for-byte without re-querying iNaturalist — the
exact photo URL, its licence, and attribution, into
spec/fixtures/groundtruth/<name>.lua. The photo itself is downloaded into
spec/fixtures/images/ (gitignored — we record the link + attribution, we don't
redistribute the image).

That set is used by `scripts/capture-corpus.lua` to record real Google Lens output
(checked-in regression fixtures) and by `scripts/live-accuracy.lua` to measure
accuracy across many species and locations.

Modes:

  (build, default) SINGLE REGION — one lat/lng/radius + a taxa filter. Default:
  Monterey Bay marine life as a worked example.

  --worldwide  A WORLDWIDE sweep: iterate biodiverse anchor regions spanning every
  continent and biome, INTERLEAVED across all major iconic taxa (birds, mammals,
  reptiles, amphibians, fish, insects, arachnids, molluscs, plants, fungi) so the
  corpus stays balanced across the tree of life even at the global cap. Yields a
  large, taxonomically and geographically diverse corpus with realistic per-species
  location strings — exactly what's needed to test the location hint in the query.

  --fetch  RECREATE the images for an existing (committed) groundtruth from its
  recorded image URLs — no iNaturalist/GBIF calls, so anyone can rebuild the corpus
  from the checked-in data. Use with --name <corpus>.

Nothing here is tied to any person: it's public iNaturalist data. Run from any
network (iNat + GBIF are open).

Usage:
  # worldwide, all taxa, ~250 species (the main corpus)
  lua scripts/build-inat-corpus.lua --worldwide [--n 250] [--per-bucket 2] [--throttle 0.6]
  # single region (default Monterey marine)
  lua scripts/build-inat-corpus.lua [--n 24] [--name monterey]
                                    [--lat 36.62 --lng -121.90 --radius 40]
                                    [--taxa Mollusca,Actinopterygii,Animalia]
  # recreate images from the committed corpus (no API calls)
  lua scripts/build-inat-corpus.lua --fetch --name worldwide
------------------------------------------------------------------------------]]

package.path = table.concat( { 'src/shared/?.lua', 'output/deps/?.lua', package.path }, ';' )
local json = require 'dkjson'
local Taxonomy = require 'Taxonomy'

-- Worldwide anchors: biodiverse regions spanning continents + biomes. Each is a
-- point + search radius (km) and a human-readable place used as the location hint.
-- Chosen for taxonomic richness and recognizable place names, not for any person.
local WORLDWIDE_ANCHORS = {
	{ place = 'Monterey Bay, California, USA',       lat =  36.62, lng = -121.90, radius = 40 },
	{ place = 'Sonoran Desert, Arizona, USA',        lat =  32.25, lng = -110.95, radius = 60 },
	{ place = 'Yellowstone, Wyoming, USA',           lat =  44.60, lng = -110.50, radius = 80 },
	{ place = 'Monteverde, Costa Rica',              lat =  10.30, lng =  -84.80, radius = 40 },
	{ place = 'Amazon Rainforest, Brazil',           lat =  -3.10, lng =  -60.02, radius = 100 },
	{ place = 'Galápagos Islands, Ecuador',          lat =  -0.82, lng =  -90.98, radius = 60 },
	{ place = 'Torres del Paine, Patagonia, Chile',  lat = -51.00, lng =  -73.00, radius = 100 },
	{ place = 'Andalusia, Spain',                    lat =  37.00, lng =   -4.50, radius = 60 },
	{ place = 'Białowieża, Poland',                  lat =  52.70, lng =   23.87, radius = 60 },
	{ place = 'Serengeti, Tanzania',                 lat =  -2.33, lng =   34.83, radius = 90 },
	{ place = 'Kruger, South Africa',                lat = -24.00, lng =   31.50, radius = 80 },
	{ place = 'Andasibe, Madagascar',                lat = -18.94, lng =   48.42, radius = 60 },
	{ place = 'Western Ghats, India',                lat =  11.40, lng =   76.60, radius = 80 },
	{ place = 'Danum Valley, Borneo, Malaysia',      lat =   4.97, lng =  117.80, radius = 80 },
	{ place = 'Honshu, Japan',                       lat =  35.20, lng =  135.80, radius = 80 },
	{ place = 'Great Barrier Reef, Australia',       lat = -16.92, lng =  145.78, radius = 100 },
	{ place = 'Fiordland, New Zealand',              lat = -45.40, lng =  167.70, radius = 90 },
	{ place = 'Svalbard, Norway',                    lat =  78.22, lng =   15.65, radius = 120 },
}

-- The major iNaturalist iconic taxa, INTERLEAVED (one bucket each per round) so the
-- corpus is spread across the tree of life instead of one taxon eating the cap.
local WORLDWIDE_TAXA = {
	'Aves', 'Mammalia', 'Reptilia', 'Amphibia', 'Actinopterygii',
	'Insecta', 'Arachnida', 'Mollusca', 'Plantae', 'Fungi',
}

-- Defaults: single-region Monterey Bay marine life (a public example region).
local N, NAME = 24, 'monterey'
local LAT, LNG, RADIUS = 36.62, -121.90, 40
local TAXA = 'Mollusca,Actinopterygii,Animalia'
local WORLDWIDE, FETCH, PER_BUCKET, THROTTLE = false, false, 2, 0.6
do
	local i = 1
	while arg[ i ] do
		local a = arg[ i ]
		if a == '--worldwide' then WORLDWIDE = true
		elseif a == '--fetch' then FETCH = true
		elseif a == '--n' then i = i + 1; N = tonumber( arg[ i ] ) or N
		elseif a == '--name' then i = i + 1; NAME = arg[ i ] or NAME
		elseif a == '--lat' then i = i + 1; LAT = tonumber( arg[ i ] ) or LAT
		elseif a == '--lng' then i = i + 1; LNG = tonumber( arg[ i ] ) or LNG
		elseif a == '--radius' then i = i + 1; RADIUS = tonumber( arg[ i ] ) or RADIUS
		elseif a == '--taxa' then i = i + 1; TAXA = arg[ i ] or TAXA
		elseif a == '--per-bucket' then i = i + 1; PER_BUCKET = tonumber( arg[ i ] ) or PER_BUCKET
		elseif a == '--throttle' then i = i + 1; THROTTLE = tonumber( arg[ i ] ) or THROTTLE
		end
		i = i + 1
	end
end
-- Worldwide gets a bigger default cap + a corpus name, unless overridden above.
if WORLDWIDE then
	if NAME == 'monterey' then NAME = 'worldwide' end
	if N == 24 then N = 250 end
end

local IMAGES = 'spec/fixtures/images'
local UA = 'lightroom-species-tagger/0.1 (ground-truth builder; +https://github.com/)'

local function shquote( s ) return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'" end
local function run( cmd ) local h = io.popen( cmd ); local o = h:read( '*a' ); h:close(); return o end
local function exists( p ) local f = io.open( p, 'rb' ); if f then f:close(); return true end return false end
local function curlJson( url )
	local body = run( 'curl -fsS -A ' .. shquote( UA ) .. ' ' .. shquote( url ) .. ' 2>/dev/null' )
	return body and body ~= '' and json.decode( body ) or nil
end
local function download( url, dest )
	run( 'curl -fsS -A ' .. shquote( UA ) .. ' -o ' .. shquote( dest ) .. ' ' .. shquote( url ) .. ' 2>/dev/null' )
end
local function nap() if THROTTLE and THROTTLE > 0 then run( 'sleep ' .. tostring( THROTTLE ) ) end end

--------------------------------------------------------------------------------
-- --fetch: recreate images from a committed groundtruth's recorded URLs. No APIs.

if FETCH then
	local gtPath = 'spec/fixtures/groundtruth/' .. NAME .. '.lua'
	local ok, gt = pcall( dofile, gtPath )
	if not ok or type( gt ) ~= 'table' then
		io.stderr:write( 'cannot load ' .. gtPath .. ' (build it first)\n' ); os.exit( 1 )
	end
	os.execute( 'mkdir -p ' .. IMAGES )
	local got, skip, miss = 0, 0, 0
	for _, r in ipairs( gt ) do
		local dest = IMAGES .. '/' .. r.image
		if exists( dest ) then skip = skip + 1
		elseif r.image_url and r.image_url ~= '' then
			download( r.image_url, dest )
			if exists( dest ) then got = got + 1 else miss = miss + 1 end
		else miss = miss + 1 end
	end
	print( ( 'fetch %s: downloaded %d, already present %d, missing-url/failed %d (of %d)' )
		:format( NAME, got, skip, miss, #gt ) )
	os.exit( 0 )
end

--------------------------------------------------------------------------------
-- build

local resolveHttp = { get = function( url ) return run( 'curl -fsS ' .. shquote( url ) .. ' 2>/dev/null' ) end }
os.execute( 'mkdir -p ' .. IMAGES )

local seen, dataset = {}, {}

-- Resolve one iNat observation to accepted taxonomy via GBIF, download its photo,
-- and append a ground-truth record (with the reproducible image URL + licence +
-- attribution + provenance). Returns true if a NEW species was added.
local function resolveAndRecord( o, place, lat, lng )
	if #dataset >= N then return false end
	local t = o.taxon or {}
	local sci = t.name
	local common = t.preferred_common_name
	local photo = ( o.photos or {} )[ 1 ]
	local purl = photo and photo.url
	if not ( sci and common and purl and t.rank == 'species' and not seen[ sci ] ) then return false end
	-- GBIF match for accepted scientific + genus/family (the pipeline's source of truth)
	local tx = Taxonomy.matchScientific( sci, { http = resolveHttp, cache = {} } )
	if not ( tx and tx.genus and tx.family ) then return false end
	seen[ sci ] = true
	-- 'medium' is a good size for Lens; the URL is recorded so the corpus recreates.
	local imgUrl = purl:gsub( 'square', 'medium' )
	local fname = ( 'inat_%d.jpg' ):format( t.id or #dataset )
	download( imgUrl, IMAGES .. '/' .. fname )
	dataset[ #dataset + 1 ] = {
		image = fname, common = common, scientific = tx.scientificName,
		genus = tx.genus, family = tx.family, place = place, lat = lat, lng = lng,
		image_url = imgUrl, license = photo.license_code or '',
		attribution = photo.attribution or '', observation = o.uri or '',
	}
	print( ( '  [%3d] %-28s %-24s %-16s (%s)' ):format(
		#dataset, common:sub( 1, 28 ), tx.scientificName:sub( 1, 24 ), tx.family:sub( 1, 16 ), place ) )
	return true
end

-- Pull up to `perBucket` new species from one (region × taxon) bucket.
local function pullBucket( place, lat, lng, radius, taxon, perBucket )
	local url = ( 'https://api.inaturalist.org/v1/observations?lat=%s&lng=%s&radius=%s&quality_grade=research' ..
		'&photos=true&rank=species&iconic_taxa=%s&order_by=votes&per_page=%d' )
		:format( lat, lng, radius, taxon, math.max( 6, perBucket * 3 ) )
	local d = curlJson( url )
	nap()
	if not d or not d.results then return 0 end
	local added = 0
	for _, o in ipairs( d.results ) do
		if added >= perBucket or #dataset >= N then break end
		if resolveAndRecord( o, place, lat, lng ) then added = added + 1 end
	end
	return added
end

if WORLDWIDE then
	print( ( 'Building a WORLDWIDE corpus: %d anchors × %d taxa (interleaved), up to %d species (per-bucket %d)…' )
		:format( #WORLDWIDE_ANCHORS, #WORLDWIDE_TAXA, N, PER_BUCKET ) )
	-- Interleave: each round pulls ONE bucket per taxon, advancing that taxon's anchor
	-- cursor. So all taxa fill together and the global cap can't starve plants/fungi.
	-- Each taxon STARTS at a staggered anchor (and wraps), so even when the cap binds
	-- after a few rounds the union of anchors touched still spans all regions, not just
	-- the first few — worldwide coverage across both axes.
	local nAnchor = #WORLDWIDE_ANCHORS
	local startAt, pulled = {}, {}
	for i, t in ipairs( WORLDWIDE_TAXA ) do
		startAt[ t ] = math.floor( ( i - 1 ) * nAnchor / #WORLDWIDE_TAXA ) -- 0-based offset
		pulled[ t ] = 0
	end
	local progress = true
	while #dataset < N and progress do
		progress = false
		for _, taxon in ipairs( WORLDWIDE_TAXA ) do
			if #dataset >= N then break end
			if pulled[ taxon ] < nAnchor then -- each taxon tries every anchor once (rotated)
				progress = true
				local idx = ( startAt[ taxon ] + pulled[ taxon ] ) % nAnchor + 1
				local a = WORLDWIDE_ANCHORS[ idx ]
				pullBucket( a.place, a.lat, a.lng, a.radius, taxon, PER_BUCKET )
				pulled[ taxon ] = pulled[ taxon ] + 1
			end
		end
	end
else
	print( ( 'Fetching iNaturalist research-grade observations near %s (%.2f, %.2f r%dkm; target %d species)…' )
		:format( NAME, LAT, LNG, RADIUS, N ) )
	local page = 1
	while #dataset < N and page <= 6 do
		local url = ( 'https://api.inaturalist.org/v1/observations?lat=%s&lng=%s&radius=%s&quality_grade=research' ..
			'&photos=true&rank=species&iconic_taxa=%s&order_by=votes&per_page=30&page=%d' )
			:format( LAT, LNG, RADIUS, TAXA:gsub( ',', '%%2C' ), page )
		local d = curlJson( url )
		nap()
		if not d or not d.results then break end
		for _, o in ipairs( d.results ) do
			if #dataset >= N then break end
			resolveAndRecord( o, NAME, LAT, LNG )
		end
		page = page + 1
	end
end

--------------------------------------------------------------------------------
-- write

local function q( s ) return ( '%q' ):format( s or '' ) end
local outPath = 'spec/fixtures/groundtruth/' .. NAME .. '.lua'
local out = {
	'-- ' .. outPath,
	( '-- Open ground truth from iNaturalist research-grade observations (%s).' ):format(
		WORLDWIDE and 'worldwide sweep' or ( 'near ' .. NAME ) ),
	'-- scientific/genus/family via GBIF. Generated by scripts/build-inat-corpus.lua.',
	'-- image_url + license + attribution let the corpus be recreated (lua scripts/build-inat-corpus.lua',
	'-- --fetch --name ' .. NAME .. '); the images themselves are gitignored (public but CC-licensed).',
	'return {',
}
local sourceTag = 'inaturalist:' .. NAME
for _, r in ipairs( dataset ) do
	out[ #out + 1 ] = ( '\t{ image = %s, common = %s, scientific = %s, genus = %s, family = %s, place = %s, lat = %s, lng = %s,\n' ..
		'\t  image_url = %s, license = %s, attribution = %s, observation = %s, source = %s },' )
		:format( q( r.image ), q( r.common ), q( r.scientific ), q( r.genus ), q( r.family ),
			q( r.place ), tostring( r.lat ), tostring( r.lng ),
			q( r.image_url ), q( r.license ), q( r.attribution ), q( r.observation ), q( sourceTag ) )
end
out[ #out + 1 ] = '}'
os.execute( 'mkdir -p spec/fixtures/groundtruth' )
local f = assert( io.open( outPath, 'wb' ) )
f:write( table.concat( out, '\n' ) .. '\n' ); f:close()
print( ( '\nWrote %s (%d species) + images in %s/' ):format( outPath, #dataset, IMAGES ) )
