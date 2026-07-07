#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
scripts/score-captures.lua
Score the checked-in Google Lens captures (spec/fixtures/captures/<variant>/) through
the real parser → GBIF → scorer pipeline, and report each variant's success rate.

This is how we pick the best query framing from DATA: capture the same species under
several framings (baseline / loc-in / loc-label / kw-*), then compare recall, top-1,
and false positives here. Replay is deterministic (GBIF responses are cached under
output/ — regenerable, so gitignored like the rest of the generated tree — and
fetched live only on a miss), so once warm it needs no network.

Accuracy is judged on the accepted Latin name + genus + family (common names vary).

Usage:
  lua scripts/score-captures.lua                     # score + compare every variant
  lua scripts/score-captures.lua --variant baseline  # one variant, per-image detail
  lua scripts/score-captures.lua --threshold 0.62    # override the auto-apply gate
------------------------------------------------------------------------------]]

package.path = table.concat( { 'src/shared/?.lua', 'output/deps/?.lua', package.path }, ';' )

local json = require 'dkjson'
local Lens = require 'ProviderGoogleLens'
local Identify = require 'Identify'
local Taxonomy = require 'Taxonomy'

local opts = { dir = 'spec/fixtures/captures', gbif = nil, variant = nil, limit = nil, threshold = nil }
do
	local i = 1
	while arg[ i ] do
		local a = arg[ i ]
		if a == '--variant' then i = i + 1; opts.variant = arg[ i ]
		elseif a == '--dir' then i = i + 1; opts.dir = arg[ i ]
		elseif a == '--gbif' then i = i + 1; opts.gbif = arg[ i ]
		elseif a == '--limit' then i = i + 1; opts.limit = tonumber( arg[ i ] )
		elseif a == '--threshold' then i = i + 1; opts.threshold = tonumber( arg[ i ] )
		end
		i = i + 1
	end
end
-- The GBIF response cache is regenerable, so it lives under output/ (the gitignored
-- generated tree) — NOT next to the committed captures.
opts.gbif = opts.gbif or 'output/captures-gbif'

local function shquote( s ) return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'" end
local function run( cmd ) local h = io.popen( cmd ); local o = h:read( '*a' ); h:close(); return o end
local function exists( p ) local f = io.open( p, 'rb' ); if f then f:close(); return true end return false end
local function readFile( p ) local f = io.open( p, 'rb' ); if not f then return nil end local b = f:read( '*a' ); f:close(); return b end
local function writeFile( p, s ) local f = assert( io.open( p, 'wb' ) ); f:write( s ); f:close() end
os.execute( 'mkdir -p ' .. shquote( opts.gbif ) )

-- GBIF: serve from the committed cache; on a miss fetch live and cache (deterministic).
local function slug( s )
	return ( ( s or '' ):lower():gsub( '%%20', ' ' ):gsub( '+', ' ' ):gsub( '[^%w]+', '_' ):gsub( '^_+', '' ):gsub( '_+$', '' ) )
end
local function param( url, key )
	local v = url:match( '[?&]' .. key .. '=([^&]*)' )
	if not v then return nil end
	return ( v:gsub( '+', ' ' ):gsub( '%%(%x%x)', function( h ) return string.char( tonumber( h, 16 ) ) end ) )
end
local function gbifRel( url )
	if url:find( '/species/match', 1, true ) then return 'match_' .. slug( param( url, 'name' ) ) .. '.json'
	elseif url:find( '/vernacularNames', 1, true ) then local k = url:match( '/species/(%d+)/vernacularNames' ); return k and ( 'vern_' .. k .. '.json' )
	elseif url:find( '/species/search', 1, true ) then return 'search_' .. slug( param( url, 'q' ) ) .. '.json' end
end
local gbifHttp = { get = function( url )
	local rel = gbifRel( url )
	if rel and exists( opts.gbif .. '/' .. rel ) then return readFile( opts.gbif .. '/' .. rel ) end
	local body = run( 'curl -fsS ' .. shquote( url ) .. ' 2>/dev/null' )
	if rel and body and body ~= '' then writeFile( opts.gbif .. '/' .. rel, body ) end
	return body
end }

-- List the *.json fixtures in one variant dir (skips the shared gbif/ cache).
local function fixturesIn( variant )
	local out = {}
	local h = io.popen( 'ls ' .. shquote( opts.dir .. '/' .. variant ) .. '/*.json 2>/dev/null' )
	for line in h:lines() do out[ #out + 1 ] = line end
	h:close()
	table.sort( out )
	return out
end

-- Score one capture against its expected species. Mirrors spec/support/harness.metrics.
local function scoreOne( fx )
	local result = Identify.run( Lens.parse { overview = fx.overview, strings = fx.strings }, {
		resolve = function( c ) return Taxonomy.resolve( c, { http = gbifHttp, cache = {} } ) end,
	}, { autoApplyThreshold = opts.threshold } )
	local confident = {}
	for _, a in ipairs( result.confident ) do confident[ a.taxon.scientificName ] = a end
	local a = confident[ fx.scientific ]
	local falsePos = 0
	for sci in pairs( confident ) do if sci ~= fx.scientific then falsePos = falsePos + 1 end end
	return {
		found = a ~= nil,
		genus = a ~= nil and a.taxon.genus == fx.genus,
		family = a ~= nil and a.taxon.family == fx.family,
		top1 = result.top ~= nil and result.top.taxon.scientificName == fx.scientific,
		falsePos = falsePos,
		decision = result.decision,
	}
end

local function scoreVariant( variant, detail )
	local files = fixturesIn( variant )
	local n, found, top1, gen, fam, fp = 0, 0, 0, 0, 0, 0
	if detail then
		print( ('%-24s %-26s %-6s %-6s %-6s %s'):format( 'image', 'expected', 'found', 'top1', 'false+', 'query' ) )
		print( ('-'):rep( 92 ) )
	end
	for _, path in ipairs( files ) do
		if opts.limit and n >= opts.limit then break end
		local fx = json.decode( readFile( path ) )
		if fx and fx.scientific then
			local m = scoreOne( fx )
			n = n + 1
			if m.found then found = found + 1 end
			if m.top1 then top1 = top1 + 1 end
			if m.genus then gen = gen + 1 end
			if m.family then fam = fam + 1 end
			fp = fp + m.falsePos
			if detail then
				print( ('%-24s %-26s %-6s %-6s %-6d %s'):format(
					fx.image:sub( 1, 24 ), ( fx.scientific or '' ):sub( 1, 26 ),
					m.found and 'yes' or 'NO', m.top1 and 'yes' or '-', m.falsePos,
					( fx.query ~= '' and ( '"' .. fx.query .. '"' ) or '(baseline)' ) ) )
			end
		end
	end
	return { variant = variant, n = n, found = found, top1 = top1, genus = gen, family = fam, fp = fp }
end

-- Which variants to score.
local variants = {}
if opts.variant then
	variants = { opts.variant }
else
	local h = io.popen( 'ls -d ' .. shquote( opts.dir ) .. '/*/ 2>/dev/null' )
	for line in h:lines() do
		local name = line:match( '([^/]+)/%s*$' )
		if name and name ~= 'gbif' then variants[ #variants + 1 ] = name end
	end
	h:close()
	table.sort( variants )
end

if #variants == 0 then
	print( 'No capture variants found under ' .. opts.dir .. '/ (run scripts/capture-corpus.lua first).' )
	os.exit( 0 )
end

local rows = {}
for _, v in ipairs( variants ) do
	rows[ #rows + 1 ] = scoreVariant( v, opts.variant ~= nil )
end

print( '\n' .. ('='):rep( 74 ) )
print( ( 'CAPTURE SCORING  (auto-apply threshold: %s)' ):format( opts.threshold and tostring( opts.threshold ) or 'plugin default' ) )
print( 'recall/top-1/genus/family judged on accepted Latin name + genus + family' )
print( ('-'):rep( 74 ) )
print( ('%-14s %-6s %-9s %-9s %-9s %-9s %s'):format( 'variant', 'n', 'recall', 'top-1', 'genus', 'family', 'false+' ) )
print( ('-'):rep( 74 ) )
for _, r in ipairs( rows ) do
	local pct = function( x ) return r.n > 0 and ('%d (%d%%)'):format( x, 100 * x / r.n ) or '-' end
	print( ('%-14s %-6d %-9s %-9s %-9s %-9s %d'):format(
		r.variant, r.n, pct( r.found ), pct( r.top1 ), pct( r.genus ), pct( r.family ), r.fp ) )
end
print( ('-'):rep( 74 ) )
print( 'Higher recall/top-1 with fewer false+ = the better framing. Pick that as' )
print( 'LensQuery.DEFAULT_STRATEGY. Per-image detail: --variant <name>.' )
