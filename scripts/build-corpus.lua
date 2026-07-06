#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
scripts/build-corpus.lua
Builder for the offline REFERENCE corpus — the labelled set the accuracy suite
replays. Nothing here is tied to any person or account: it's a hand-picked list of
well-known species spanning several phyla (fish, cephalopods, echinoderms,
cnidarians, mammals, birds), chosen to exercise the parser/GBIF/scorer across
diverse taxonomy.

For each species it resolves the accepted scientific name / genus / family through
the REAL GBIF backbone (live, over curl), so the committed ground truth is exactly
what GBIF returns and the resolver is exercised against a real species mix.

It writes:
  * spec/fixtures/groundtruth/reference.lua  — the full labelled dataset
  * spec/fixtures/lens/<slug>.json           — the Lens results for each entry:
      a REPRESENTATIVE blob by default, or the REAL Google Lens capture with --live
  * spec/fixtures/gbif/*.json                — REAL GBIF captures the offline
      pipeline replays
  * spec/fixtures/lens/raw/<slug>.html       — (only with --live) Google's raw
      response, so you can audit that the saved fixtures are genuinely Google's
and prints the manifest cases to paste into spec/fixtures/manifest.lua.

Usage:  lua scripts/build-corpus.lua                   (resolve + write dataset)
        lua scripts/build-corpus.lua --corpus          (also build representative fixtures)
        lua scripts/build-corpus.lua --corpus --live   (REFRESH fixtures from real Google
                                                        Lens via the browser helper)
--live captures REAL Google Lens output via the browser helper (scripts/lens):
`cd scripts/lens && npm i` (puppeteer-core) + Google Chrome installed; run from a
residential network. The saved lens/*.json and lens/raw/*.html are yours to inspect.
Requires: curl, and `lua build/build.lua --fetch-deps` (for dkjson).

To GROW the corpus from an open, reproducible source instead of this curated list,
see scripts/build-inat-corpus.lua (iNaturalist research-grade observations).
------------------------------------------------------------------------------]]

package.path = table.concat( {
	'src/shared/?.lua', 'output/deps/?.lua', 'spec/?.lua', package.path,
}, ';' )

local json = require 'dkjson'
local Identify = require 'Identify'
local Taxonomy = require 'Taxonomy'
local Lens = require 'ProviderGoogleLens'

-- Flags:
--   --corpus   (re)build the offline accuracy fixtures + manifest
--   --live     capture REAL Google Lens output for each corpus image instead of
--              the representative blob (run from a RESIDENTIAL connection). Also
--              dumps raw HTML to spec/fixtures/lens/raw/ so you can audit it.
--   --images D where the images live for --live (default spec/fixtures/images)
local DO_CORPUS, LIVE, IMAGES = false, false, 'spec/fixtures/images'
do
	local i = 1
	while arg[ i ] do
		local a = arg[ i ]
		if a == '--corpus' then DO_CORPUS = true
		elseif a == '--live' then LIVE = true
		elseif a == '--images' then i = i + 1; IMAGES = arg[ i ] or IMAGES
		elseif a:match( '^%-%-images=' ) then IMAGES = a:match( '=(.+)$' ) end
		i = i + 1
	end
end

--------------------------------------------------------------------------------
-- The reference species. `slug` is the descriptive image/fixture name (the offline
-- suite replays recorded JSON, not pixels). `also` lists ADDITIONAL species in the
-- same frame (multi-subject case) — each becomes its own ground-truth row, mirroring
-- the plugin tagging every species over threshold. These are all common, widely
-- photographed wild species; no data here is specific to any person.
local GOLD = {
	{ slug = 'spotfin_porcupinefish',        common = 'Spot-fin porcupinefish',      scientific = 'Diodon hystrix' },
	{ slug = 'spotted_linckia',              common = 'Multipore sea star',          scientific = 'Linckia multifora' },
	{ slug = 'reef_octopus_triggerfish',     common = 'Day octopus',                 scientific = 'Octopus cyanea',
		also = { { common = 'Lei triggerfish', scientific = 'Sufflamen bursa' } } },
	{ slug = 'snowflake_moray',              common = 'Snowflake moray',             scientific = 'Echidna nebulosa' },
	{ slug = 'african_buffalo',              common = 'African buffalo',             scientific = 'Syncerus caffer' },
	{ slug = 'california_golden_gorgonian',  common = 'California golden gorgonian',  scientific = 'Muricea californica' },
	{ slug = 'ocean_sunfish',                common = 'Ocean sunfish',               scientific = 'Mola mola' },
	{ slug = 'hooded_nudibranch',            common = 'Hooded nudibranch',           scientific = 'Melibe leonina' },
	{ slug = 'bornean_orangutan',            common = 'Bornean orangutan',           scientific = 'Pongo pygmaeus' },
	{ slug = 'wolf_eel',                     common = 'Wolf-eel',                    scientific = 'Anarrhichthys ocellatus' },
	{ slug = 'bald_eagle',                   common = 'Bald eagle',                  scientific = 'Haliaeetus leucocephalus' },
}

--------------------------------------------------------------------------------
-- helpers

local function shquote( s ) return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'" end
local function run( cmd ) local h = io.popen( cmd ); local o = h:read( '*a' ); h:close(); return o end
local function curlGet( url ) return run( 'curl -fsS ' .. shquote( url ) .. ' 2>/dev/null' ) end

local function slug( s )
	return ( ( s or '' ):lower():gsub( '%%20', ' ' ):gsub( '+', ' ' )
		:gsub( '[^%w]+', '_' ):gsub( '^_+', '' ):gsub( '_+$', '' ) )
end

local function writeFile( path, body )
	local f = assert( io.open( path, 'wb' ), 'cannot write ' .. path )
	f:write( body ); f:close()
end

local function param( url, key )
	local v = url:match( '[?&]' .. key .. '=([^&]*)' )
	if not v then return nil end
	return ( v:gsub( '+', ' ' ):gsub( '%%(%x%x)', function( h ) return string.char( tonumber( h, 16 ) ) end ) )
end

-- An http adapter over curl. When `record` is set, every GBIF GET is also saved
-- to the fixture file the offline fake_http will look for.
local FIX = 'spec/fixtures'
local function httpAdapter( record )
	return {
		get = function( url )
			local body = curlGet( url )
			if record and body and body ~= '' then
				local rel
				if url:find( '/species/match', 1, true ) then
					rel = 'gbif/match_' .. slug( param( url, 'name' ) ) .. '.json'
				elseif url:find( '/vernacularNames', 1, true ) then
					local key = url:match( '/species/(%d+)/vernacularNames' )
					rel = key and ( 'gbif/vern_' .. key .. '.json' )
				elseif url:find( '/species/search', 1, true ) then
					rel = 'gbif/search_' .. slug( param( url, 'q' ) ) .. '.json'
				end
				if rel then writeFile( FIX .. '/' .. rel, body ) end
			end
			return body
		end,
	}
end

-- A representative Google Lens results blob (what the browser helper harvests): an
-- AI-Overview line naming the species + a few scientific-bearing titles + noise.
local function lensBlob( entries )
	local overview
	do
		local names = {}
		for _, e in ipairs( entries ) do
			names[ #names + 1 ] = e.common .. ' (' .. e.scientific .. ')'
		end
		overview = 'The animal in the image is a ' .. table.concat( names, ', and a ' ) .. '.'
	end
	local matches = {}
	for _, e in ipairs( entries ) do
		matches[ #matches + 1 ] = { e.common .. ' (' .. e.scientific .. ') - Wikipedia',
			'https://en.wikipedia.org/wiki/' .. e.scientific:gsub( ' ', '_' ), 'Wikipedia' }
		matches[ #matches + 1 ] = { e.scientific .. ' - iNaturalist',
			'https://www.inaturalist.org/taxa/' .. e.scientific:gsub( ' ', '-' ), 'iNaturalist' }
		matches[ #matches + 1 ] = { e.common, 'https://example.org/' .. slug( e.common ), 'Field Guide' }
	end
	matches[ #matches + 1 ] = { 'Underwater photography tips', 'https://blog.example.com/uw', 'Blog' }
	matches[ #matches + 1 ] = { 'Wildlife stock photo 90210', 'https://www.shutterstock.com/x', 'Shutterstock' }
	return { overview = overview, strings = { 'Visual matches', matches,
		{ 'related searches', { 'wildlife', 'nature', 'ocean' } } } }
end

local function fileExists( p ) local f = io.open( p, 'rb' ); if f then f:close(); return true end return false end

-- Capture REAL Google Lens output via the browser helper (scripts/lens). Returns
-- ({ overview, strings }, rawJson, err).
local function captureLiveLens( imagePath )
	local cmd = 'node ' .. shquote( 'scripts/lens/lens-search.js' ) .. ' ' .. shquote( imagePath ) .. ' 2>/dev/null'
	local raw = run( cmd )
	if not raw or raw == '' then
		return nil, raw, 'lens helper produced no output (run `cd scripts/lens && npm i`, and ensure node + Chrome)'
	end
	local decoded = json.decode( raw )
	if type( decoded ) ~= 'table' then return nil, raw, 'lens helper: unparseable output' end
	if not decoded.ok then return nil, raw, 'lens helper: ' .. tostring( decoded.error ) end
	if type( decoded.strings ) ~= 'table' or #decoded.strings == 0 then
		return nil, raw, 'lens helper: no match strings'
	end
	return { overview = decoded.overview, strings = decoded.strings }, raw, nil
end

--------------------------------------------------------------------------------
-- 1) resolve every reference entry through live GBIF; build the dataset

local resolveHttp = httpAdapter( false )
local dataset = {}

-- Resolve one (slug, common, scientific) subject into a dataset row. The common
-- name is the curated label; GBIF supplies the accepted scientific name +
-- classification (NOT the colloquial name, whose "first English vernacular" is
-- often obscure, e.g. "Cyane's octopus" for Octopus cyanea).
local function resolveRow( imgSlug, common, scientific )
	local deps = { http = resolveHttp, cache = {} }
	local t = Taxonomy.matchScientific( scientific, deps )
	if not t then
		io.stderr:write( ( '  ! GBIF did not match %q (from "%s")\n' ):format( scientific, common ) )
		return nil
	end
	return {
		image = imgSlug .. '.jpg', common = common, scientific = t.scientificName,
		genus = t.genus, family = t.family, order = t.order,
		class = t.class, phylum = t.phylum, kingdom = t.kingdom,
	}
end

-- One row per species in the frame (lead subject + any `also`), so multi-subject
-- photos are fully represented — matching the plugin, which tags every species
-- over threshold.
for _, e in ipairs( GOLD ) do
	local subjects = { { common = e.common, scientific = e.scientific } }
	for _, a in ipairs( e.also or {} ) do subjects[ #subjects + 1 ] = a end
	for _, s in ipairs( subjects ) do
		local row = resolveRow( e.slug, s.common, s.scientific )
		if row then
			dataset[ #dataset + 1 ] = row
			print( ( '  %-26s -> %-26s %s / %s' ):format(
				s.common, row.scientific, row.genus or '?', row.family or '?' ) )
		end
	end
end
print( ( 'Resolved %d subjects across %d reference photos.' ):format( #dataset, #GOLD ) )

-- write the dataset
local function lua_q( s ) return ( '%q' ):format( s or '' ) end
local out = {
	'-- spec/fixtures/groundtruth/reference.lua',
	'-- Ground-truth species labels for the offline REFERENCE corpus — a hand-picked',
	'-- set of well-known species across several phyla, with the accepted scientific',
	'-- name / genus / family resolved against the GBIF backbone. Generated by',
	'-- scripts/build-corpus.lua. Nothing here is tied to any person or account; the',
	'-- image slugs are descriptive (the offline suite replays recorded JSON, not pixels).',
	'return {',
}
for _, r in ipairs( dataset ) do
	out[ #out + 1 ] = ( '\t{ image = %s, common = %s, scientific = %s, genus = %s, family = %s, ' ..
		'order = %s, class = %s, phylum = %s, kingdom = %s, source = "reference" },' ):format(
		lua_q( r.image ), lua_q( r.common ), lua_q( r.scientific ), lua_q( r.genus ), lua_q( r.family ),
		lua_q( r.order ), lua_q( r.class ), lua_q( r.phylum ), lua_q( r.kingdom ) )
end
out[ #out + 1 ] = '}'
os.execute( 'mkdir -p ' .. FIX .. '/groundtruth' )
writeFile( FIX .. '/groundtruth/reference.lua', table.concat( out, '\n' ) .. '\n' )
print( ( '\nWrote %s/groundtruth/reference.lua (%d species)' ):format( FIX, #dataset ) )

--------------------------------------------------------------------------------
-- 2) build the offline accuracy corpus (representative fixtures + manifest)

if not DO_CORPUS then
	print( '\n(Re-run with --corpus to (re)build the offline accuracy fixtures + manifest.)' )
	return
end

print( ( '\nBuilding offline corpus cases (%s Lens output)…' ):format( LIVE and 'LIVE' or 'representative' ) )
os.execute( 'mkdir -p ' .. FIX .. '/lens' )
if LIVE then os.execute( 'mkdir -p ' .. FIX .. '/lens/raw' ) end
local recHttp = httpAdapter( true )
local manifestCases = {}

-- expected = the GROUND TRUTH (every species in the frame), NOT the pipeline's
-- prediction. So with --live the accuracy run measures real Lens against the truth
-- (and may legitimately fall short); with the representative blob it passes by
-- construction.
local expectedByImage = {}
for _, r in ipairs( dataset ) do
	local e = expectedByImage[ r.image ] or {}
	e[ #e + 1 ] = { common = r.common, scientific = r.scientific, genus = r.genus, family = r.family }
	expectedByImage[ r.image ] = e
end

for _, e in ipairs( GOLD ) do
	local entries = { { common = e.common, scientific = e.scientific } }
	for _, a in ipairs( e.also or {} ) do entries[ #entries + 1 ] = a end
	local caseId = e.slug
	local imageName = e.slug .. '.jpg'
	local expected = expectedByImage[ imageName ] or {}

	-- get the Lens response: real Google capture (--live) or representative blob
	local blob, skip
	if LIVE then
		local path = IMAGES .. '/' .. imageName
		if not fileExists( path ) then
			io.stderr:write( ( '  ! %s: image not found at %s — skipping\n' ):format( caseId, path ) )
			skip = true
		else
			local decoded, raw, ferr = captureLiveLens( path )
			if not decoded then
				io.stderr:write( ( '  ! %s: live Lens failed (%s) — skipping\n' ):format( caseId, tostring( ferr ) ) )
				skip = true
			else
				blob = decoded
				if raw then writeFile( FIX .. '/lens/raw/' .. caseId .. '.html', raw ) end
			end
		end
	else
		blob = lensBlob( entries )
	end

	if not skip then
		writeFile( FIX .. '/lens/' .. caseId .. '.json', json.encode( blob, { indent = true } ) )

		-- run the real pipeline with a RECORDING adapter: captures the GBIF fixtures
		-- the offline suite replays.
		local result = Identify.run( Lens.parse( blob ), {
			resolve = function( c ) return Taxonomy.resolve( c, { http = recHttp, cache = {} } ) end,
		} )

		-- report how many ground-truth species this Lens response recovered
		local got = {}
		for _, a in ipairs( result.confident ) do got[ a.taxon.scientificName ] = true end
		local found = 0
		for _, x in ipairs( expected ) do if got[ x.scientific ] then found = found + 1 end end

		manifestCases[ #manifestCases + 1 ] = { id = caseId .. '_lens', image = imageName,
			provider = 'lens', response = 'lens/' .. caseId .. '.json', expected = expected }
		print( ( '  %-28s recovered %d/%d  (%d confident)' ):format(
			caseId, found, #expected, #result.confident ) )
	end
end

-- print manifest entries to paste
print( '\n--- paste into spec/fixtures/manifest.lua ---\n' )
for _, c in ipairs( manifestCases ) do
	local lines = { '\t{', ( '\t\tid = %q,' ):format( c.id ), ( '\t\timage = %q,' ):format( c.image ),
		( '\t\tprovider = %q,' ):format( c.provider ), ( '\t\tresponse = %q,' ):format( c.response ),
		'\t\texpected = {' }
	for _, x in ipairs( c.expected ) do
		lines[ #lines + 1 ] = ( '\t\t\t{ common = %q, scientific = %q, genus = %q, family = %q },' ):format(
			x.common, x.scientific, x.genus, x.family )
	end
	lines[ #lines + 1 ] = '\t\t},'; lines[ #lines + 1 ] = '\t},'
	print( table.concat( lines, '\n' ) )
end
