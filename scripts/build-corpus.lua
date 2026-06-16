#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
scripts/build-corpus.lua
One-off builder for the @yuvalsaw ground-truth corpus.

Source of truth = the captions in an Instagram "Download Your Information" export
(each post's caption leads with the species). The species names below were
curated by hand from those captions; this script then resolves each through the
REAL GBIF backbone (live, over curl) to fill in the accepted scientific name,
genus and family — so the committed ground truth is what GBIF actually returns,
and the resolver is exercised against the real species mix.

It writes:
  * spec/fixtures/groundtruth/yuvalsaw.lua  — the full labelled dataset
  * spec/fixtures/lens/<slug>.json          — the Lens results for each
      `corpus = true` entry: a representative blob by default, or the REAL Google
      Lens capture with --live
  * spec/fixtures/gbif/*.json               — REAL GBIF captures the offline
      pipeline replays for those corpus cases
  * spec/fixtures/lens/raw/<slug>.html      — (only with --live) Google's raw
      response, so you can audit that the saved fixtures are genuinely Google's
and prints the manifest cases to paste into spec/fixtures/manifest.lua.

Usage:  lua scripts/build-corpus.lua                   (resolve + write dataset)
        lua scripts/build-corpus.lua --corpus          (also build representative fixtures)
        lua scripts/build-corpus.lua --corpus --live   (REFRESH fixtures from real Google
                                                        Lens — run from a residential
                                                        connection; datacenter/VPN IPs are
                                                        blocked by Google)
Then `just accuracy` scores the (now real) fixtures offline; the saved lens/*.json
and lens/raw/*.html are yours to inspect and diff.
Requires: curl, and `lua build/build.lua --fetch-deps` (for dkjson).
------------------------------------------------------------------------------]]

package.path = table.concat( {
	'src/shared/?.lua', 'build/.deps/?.lua', 'spec/?.lua', package.path,
}, ';' )

local json = require 'dkjson'
local Identify = require 'Identify'
local Taxonomy = require 'Taxonomy'
local Lens = require 'ProviderGoogleLens'

-- Flags:
--   --corpus   (re)build the offline accuracy fixtures + manifest
--   --live     capture REAL Google Lens output for each corpus image instead of
--              the representative blob (run from a RESIDENTIAL connection — Google
--              blocks datacenter/VPN IPs). Also dumps the raw HTML to
--              spec/fixtures/lens/raw/ so you can audit that it's genuinely Google's.
--   --images D where the photos live (default spec/fixtures/images)
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
-- Hand-curated labels from the @yuvalsaw IG captions (common name as written +
-- the species it denotes). `corpus = true` marks the taxonomically-diverse
-- subset that also gets an offline accuracy case. `image` is the export filename.
-- `also` lists ADDITIONAL animals in the same frame (multi-subject photos) — each
-- becomes its own ground-truth row, mirroring the plugin tagging every species.
--
-- Multi-animal frames audited from the captions + the images. Secondary subjects
-- that cannot be resolved to a confident SPECIES are intentionally left out rather
-- than guessed (ground truth must be correct, not just complete):
--   18349712272246623 "anemone eating a starfish" — the starfish is engulfed/not
--       visible; only the Urticina piscivora anemone is labelled.
--   18102139598066261 "lingcod among metridium"  — the Metridium anemones are
--       out-of-focus background and the caption gives only the genus; lingcod only.
--   18123724987543504 "a little bird + African buffalo" — the bird is a small
--       oxpecker, not resolvable to species from the frame; buffalo only.
local GOLD = {
	{ image = '18118084048758540.jpg', common = 'Spotfin porcupinefish', scientific = 'Diodon hystrix', corpus = true },
	{ image = '18398736889152502.jpg', common = 'Spotted linckia',        scientific = 'Linckia multifora', corpus = true },
	{ image = '18132156424607739.jpg', common = 'Pacific trumpetfish',    scientific = 'Aulostomus chinensis' },
	{ image = '17972253002901502.jpg', common = 'Freckled hawkfish',      scientific = 'Paracirrhites forsteri' },
	{ image = '18120867067606496.jpg', common = 'Variegated lizardfish',  scientific = 'Synodus variegatus' },
	{ image = '18068101841415789.jpg', common = 'Blue-lined long-spine urchin', scientific = 'Diadema savignyi' },
	{ image = '17930107470324084.jpg', common = 'Giant frogfish',         scientific = 'Antennarius commerson' },
	{ image = '18169200037427762.jpg', common = 'Day octopus',            scientific = 'Octopus cyanea',
		also = { { common = 'Lei triggerfish', scientific = 'Sufflamen bursa' } }, corpus = true, id = 'reef_octopus_triggerfish' },
	{ image = '17979580718862902.jpg', common = 'Hawaiian lionfish',      scientific = 'Pterois sphex' },
	{ image = '18074894648306286.jpg', common = 'Horned helmet snail',    scientific = 'Cassis cornuta' },
	{ image = '18097003880239640.jpg', common = 'Snowflake moray',        scientific = 'Echidna nebulosa', corpus = true },
	{ image = '18392793022090924.jpg', common = 'Bigeye emperor',         scientific = 'Monotaxis grandoculis' },
	{ image = '18106325992990317.jpg', common = 'Stripebelly puffer',     scientific = 'Arothron hispidus' },
	{ image = '18118621126685822.jpg', common = 'Whitemouth moray',       scientific = 'Gymnothorax meleagris' },
	{ image = '17999717894944929.jpg', common = 'Rock scallop',           scientific = 'Crassadoma gigantea' },
	{ image = '18389088166093319.jpg', common = 'Wart-necked piddock',    scientific = 'Chaceia ovoidea' },
	{ image = '18349712272246623.jpg', common = 'Fish-eating anemone',    scientific = 'Urticina piscivora' },
	{ image = '18102139598066261.jpg', common = 'Lingcod',                scientific = 'Ophiodon elongatus' },
	{ image = '18089997965065784.jpg', common = 'Northern elephant seal', scientific = 'Mirounga angustirostris' },
	{ image = '18123724987543504.jpg', common = 'African buffalo',        scientific = 'Syncerus caffer', corpus = true },
	{ image = '18117218410583822.jpg', common = 'Impala',                 scientific = 'Aepyceros melampus' },
	{ image = '17905787328167859.jpg', common = 'California golden gorgonian', scientific = 'Muricea californica', corpus = true },
	{ image = '17971927646831006.jpg', common = 'Kelp rockfish',          scientific = 'Sebastes atrovirens' },
	{ image = '18046430771705572.jpg', common = 'Pacific red octopus',    scientific = 'Octopus rubescens' },
	{ image = '18049851059441667.jpg', common = 'Ocean sunfish',          scientific = 'Mola mola', corpus = true },
	{ image = '18137893420479323.jpg', common = 'Hooded nudibranch',      scientific = 'Melibe leonina', corpus = true },
	{ image = '17920244406229556.jpg', common = 'Flat abalone',           scientific = 'Haliotis walallensis' },
	{ image = '17861520192560372.jpg', common = 'San Diego dorid',        scientific = 'Diaulula sandiegensis' },
	{ image = '17855454504546113.jpg', common = 'American black bear',    scientific = 'Ursus americanus' },
	{ image = '17997124220894029.jpg', common = 'Cabezon',                scientific = 'Scorpaenichthys marmoratus' },
	{ image = '18103507690702609.jpg', common = 'Bornean orangutan',      scientific = 'Pongo pygmaeus', corpus = true },
	{ image = '18137119555471460.jpg', common = 'Yellow warbler',         scientific = 'Setophaga petechia' },
	{ image = '18550403395009338.jpg', common = 'Humpback whale',         scientific = 'Megaptera novaeangliae' },
	{ image = '18310157134267276.jpg', common = 'North American porcupine', scientific = 'Erethizon dorsatum' },
	{ image = '18052542377412770.jpg', common = 'Wolf eel',               scientific = 'Anarrhichthys ocellatus', corpus = true },
	{ image = '17846728464657941.jpg', common = 'Marabou stork',          scientific = 'Leptoptilos crumenifer' },
	{ image = '18061071692296720.jpg', common = 'Bald eagle',             scientific = 'Haliaeetus leucocephalus', corpus = true },
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
		post = function() return nil end,
		postMultipart = function() return nil end,
	}
end

-- A representative Google Lens results blob (what the direct backend would
-- harvest): a couple of scientific-bearing titles + the common name + noise.
local function lensBlob( entries )
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
	return { json.null, { 'Visual matches', matches },
		{ 'related searches', { 'wildlife', 'nature', 'ocean' } } }
end

-- Capture REAL Google Lens output for an image (runs the actual provider over a
-- curl multipart upload, following the redirect like LrHttp does). Returns the
-- extracted data, the raw HTML (for auditing), and an error string. Needs a
-- residential connection — Google blocks datacenter/VPN IPs.
local function captureLiveLens( imagePath )
	local raw
	local h = {
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
			-- NOTE: no -f, so we keep the body even on a 4xx (403/consent) page —
			-- that lets the provider report WHY Google refused, and the raw dump
			-- captures it for auditing.
			raw = run( 'curl -sSL' .. hs .. fs .. ' ' .. shquote( url ) .. ' 2>/dev/null' )
			return raw
		end,
	}
	local decoded, err = Lens.fetch( { imageFile = imagePath, hl = 'en', country = 'us' }, { http = h } )
	return decoded, raw, err
end

local function fileExists( p ) local f = io.open( p, 'rb' ); if f then f:close(); return true end return false end

--------------------------------------------------------------------------------
-- 1) resolve every gold entry through live GBIF; build the dataset

local resolveHttp = httpAdapter( false )
local dataset = {}

-- Resolve one (image, common, scientific) subject into a dataset row. The common
-- name is the photographer's own label — the authoritative ground truth; GBIF
-- only supplies the accepted scientific name + classification (NOT the colloquial
-- name, whose "first English vernacular" is often an obscure one e.g.
-- "Cyane's octopus" for Octopus cyanea).
local function resolveRow( image, common, scientific )
	local deps = { http = resolveHttp, cache = {} }
	local t = Taxonomy.matchScientific( scientific, deps )
	if not t then
		io.stderr:write( ( '  ! GBIF did not match %q (from "%s")\n' ):format( scientific, common ) )
		return nil
	end
	return {
		image = image, common = common, scientific = t.scientificName,
		genus = t.genus, family = t.family, order = t.order,
		class = t.class, phylum = t.phylum, kingdom = t.kingdom,
	}
end

-- One row per ANIMAL in the frame: the lead subject plus any `also` species, so
-- multi-subject photos (e.g. the day octopus + lei triggerfish) are fully
-- represented — matching the plugin, which tags every species over threshold.
for _, e in ipairs( GOLD ) do
	local subjects = { { common = e.common, scientific = e.scientific } }
	for _, a in ipairs( e.also or {} ) do subjects[ #subjects + 1 ] = a end
	for _, s in ipairs( subjects ) do
		local row = resolveRow( e.image, s.common, s.scientific )
		if row then
			dataset[ #dataset + 1 ] = row
			print( ( '  %-26s -> %-26s %s / %s' ):format(
				s.common, row.scientific, row.genus or '?', row.family or '?' ) )
		end
	end
end
print( ( 'Resolved %d subjects across %d photos.' ):format( #dataset, #GOLD ) )

-- write the dataset
local function lua_q( s ) return ( '%q' ):format( s or '' ) end
local out = {
	'-- spec/fixtures/groundtruth/yuvalsaw.lua',
	'-- Ground-truth species labels curated from the @yuvalsaw Instagram captions',
	'-- (one\'s own posts, exported via "Download Your Information"), with the',
	'-- accepted scientific name / genus / family resolved against the GBIF backbone.',
	'-- Generated by scripts/build-corpus.lua. Images are the photographer\'s own and',
	'-- are NOT committed (see spec/fixtures/images/); this file is the labels only.',
	'return {',
}
for _, r in ipairs( dataset ) do
	out[ #out + 1 ] = ( '\t{ image = %s, common = %s, scientific = %s, genus = %s, family = %s, ' ..
		'order = %s, class = %s, phylum = %s, kingdom = %s, source = "instagram:@yuvalsaw" },' ):format(
		lua_q( r.image ), lua_q( r.common ), lua_q( r.scientific ), lua_q( r.genus ), lua_q( r.family ),
		lua_q( r.order ), lua_q( r.class ), lua_q( r.phylum ), lua_q( r.kingdom ) )
end
out[ #out + 1 ] = '}'
os.execute( 'mkdir -p ' .. FIX .. '/groundtruth' )
writeFile( FIX .. '/groundtruth/yuvalsaw.lua', table.concat( out, '\n' ) .. '\n' )
print( ( '\nWrote %s/groundtruth/yuvalsaw.lua (%d species)' ):format( FIX, #dataset ) )

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

-- expected = the GROUND TRUTH (every animal in the frame, from the dataset above),
-- NOT the pipeline's prediction. So with --live the accuracy run measures real Lens
-- against the truth (and may legitimately fall short); with the representative blob
-- it passes by construction.
local expectedByImage = {}
for _, r in ipairs( dataset ) do
	local e = expectedByImage[ r.image ] or {}
	e[ #e + 1 ] = { common = r.common, scientific = r.scientific, genus = r.genus, family = r.family }
	expectedByImage[ r.image ] = e
end

for _, e in ipairs( GOLD ) do
	if e.corpus then
		local entries = { { common = e.common, scientific = e.scientific } }
		for _, a in ipairs( e.also or {} ) do entries[ #entries + 1 ] = a end
		local caseId = e.id or slug( e.common )
		local expected = expectedByImage[ e.image ] or {}

		-- get the Lens response: real Google capture (--live) or representative blob
		local blob, skip
		if LIVE then
			local path = IMAGES .. '/' .. e.image
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

			-- run the real pipeline with a RECORDING adapter: captures the GBIF
			-- fixtures the offline suite replays.
			local result = Identify.run( Lens.parse( blob ), {
				resolve = function( c ) return Taxonomy.resolve( c, { http = recHttp, cache = {} } ) end,
			} )

			-- report how many ground-truth species this Lens response recovered
			local got = {}
			for _, a in ipairs( result.confident ) do got[ a.taxon.scientificName ] = true end
			local found = 0
			for _, x in ipairs( expected ) do if got[ x.scientific ] then found = found + 1 end end

			manifestCases[ #manifestCases + 1 ] = { id = caseId .. '_lens', image = e.image,
				provider = 'lens', response = 'lens/' .. caseId .. '.json', expected = expected }
			print( ( '  %-28s recovered %d/%d  (%d confident)' ):format(
				caseId, found, #expected, #result.confident ) )
		end
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
