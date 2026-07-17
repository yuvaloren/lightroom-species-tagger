--[[----------------------------------------------------------------------------
Taxonomy.lua
Resolves a free-text name (scientific binomial OR common name) to a canonical
taxon using the GBIF backbone — keyless, free, no account required. Gives us:
  * the accepted scientific (Latin) name,
  * the preferred English common name,
  * the full classification chain (kingdom … species) for hierarchy keywords.

Design: every network call goes through an injected `deps.http` (so the offline
test corpus replays recorded GBIF JSON and CI needs no network). All response
parsing is pure and exposed on `Taxonomy._test`.

GBIF endpoints used:
  GET /species/match?name=…           best single match (great for binomials)
  GET /species/search?q=…&rank=SPECIES full-text (used for common→scientific)
  GET /species/{key}/vernacularNames  preferred common name
------------------------------------------------------------------------------]]

local json = require 'dkjson'

local M = {}

M.BASE = 'https://api.gbif.org/v1'
-- GBIF backbone (nub) dataset — preferred over the many source datasets that
-- also surface in /species/search (some use ALL-CAPS ranks, different keys, …).
M.BACKBONE_DATASET = 'd7dddbf4-2cf0-4f39-9b2a-bb099caae36c'
M.MIN_FUZZY_CONFIDENCE = 92
M.ACCEPT_RANKS = { SPECIES = true, SUBSPECIES = true, GENUS = true }

--------------------------------------------------------------------------------
-- pure helpers

local function urlencode( s )
	return ( tostring( s ):gsub( '[^%w%-_%.~]', function( c )
		return string.format( '%%%02X', string.byte( c ) )
	end ) )
end
M._urlencode = urlencode

local function trim( s ) return ( s:gsub( '^%s+', '' ):gsub( '%s+$', '' ) ) end
local function norm( s ) return trim( ( tostring( s ):gsub( '%s+', ' ' ) ) ):lower() end

-- Common names display as lower-case with a leading capital ("Day octopus").
local function displayCommon( s )
	s = trim( ( tostring( s ):gsub( '%s+', ' ' ) ) )
	if s == '' then return s end
	s = s:lower()
	return s:sub( 1, 1 ):upper() .. s:sub( 2 )
end
M.displayCommon = displayCommon

function M.matchUrl( name )
	return M.BASE .. '/species/match?strict=false&name=' .. urlencode( name )
end

function M.searchUrl( name )
	return M.BASE .. '/species/search?rank=SPECIES&limit=8&q=' .. urlencode( name )
end

function M.vernacularUrl( usageKey )
	return M.BASE .. '/species/' .. tostring( usageKey ) .. '/vernacularNames?limit=80'
end

-- Normalize a decoded /species/match response into our taxon shape (or nil).
local function normalizeMatch( d )
	if type( d ) ~= 'table' then return nil end
	if not d.usageKey or d.matchType == 'NONE' or not d.matchType then return nil end
	-- Follow GBIF synonymy to the ACCEPTED taxon, so a synonym candidate and its
	-- accepted-name sibling aggregate under one key in Identify (instead of the
	-- synonym winning top-1 as a duplicate false positive). GBIF gives the accepted
	-- binomial in d.species and the accepted key in d.acceptedUsageKey.
	local usageKey = d.usageKey
	local sciName = d.canonicalName or d.species or d.scientificName
	if d.status == 'SYNONYM' and d.acceptedUsageKey then
		usageKey = d.acceptedUsageKey
		sciName = d.species or sciName
	end
	return {
		usageKey = usageKey,
		scientificName = sciName,
		rank = d.rank,
		matchType = d.matchType,
		confidence = d.confidence or 0,
		kingdom = d.kingdom, phylum = d.phylum, class = d.class,
		order = d.order, family = d.family, genus = d.genus,
		species = d.species,
	}
end
M._normalizeMatch = normalizeMatch

-- Should we accept a normalized /match taxon as a real identification?
local function acceptable( t )
	if not t then return false end
	if not M.ACCEPT_RANKS[ t.rank or '' ] then return false end
	if t.matchType == 'EXACT' then return true end
	if t.matchType == 'FUZZY' and ( t.confidence or 0 ) >= M.MIN_FUZZY_CONFIDENCE then
		return true
	end
	return false
end
M._acceptable = acceptable

-- Pick the best English vernacular from a decoded /vernacularNames response.
local function pickVernacular( d )
	local results = ( type( d ) == 'table' and ( d.results or d ) ) or {}
	local firstEng
	for _, v in ipairs( results ) do
		if ( v.language == 'eng' or v.language == 'en' ) and v.vernacularName then
			if v.preferred then return displayCommon( v.vernacularName ) end
			firstEng = firstEng or v.vernacularName
		end
	end
	return firstEng and displayCommon( firstEng ) or nil
end
M._pickVernacular = pickVernacular

-- From a decoded /species/search response choose the best backbone species
-- result for a common-name query. Returns { canonicalName, commonName, usageKey }.
local function pickSearchResult( d, queryName )
	local results = ( type( d ) == 'table' and d.results ) or {}
	local q = norm( queryName )
	local best, bestScore
	for _, r in ipairs( results ) do
		local rank = ( r.rank or '' ):upper()
		if rank == 'SPECIES' or rank == 'SUBSPECIES' then
			local score = 0
			if ( r.taxonomicStatus or '' ):upper() == 'ACCEPTED' then score = score + 2 end
			if ( r.nameType or 'SCIENTIFIC' ):upper() == 'SCIENTIFIC' then score = score + 1 end
			-- prefer the GBIF backbone dataset; a present nubKey is a weaker signal
			if r.datasetKey == M.BACKBONE_DATASET then score = score + 3
			elseif r.nubKey then score = score + 1 end
			-- vernacular agreement with the query
			local vernExact, vernLoose, matchedEng
			for _, v in ipairs( r.vernacularNames or {} ) do
				if v.vernacularName and ( v.language == 'eng' or v.language == 'en' or not v.language ) then
					local vn = norm( v.vernacularName )
					if vn == q then vernExact = true; matchedEng = matchedEng or v.vernacularName
					elseif vn:find( q, 1, true ) or q:find( vn, 1, true ) then
						vernLoose = true; matchedEng = matchedEng or v.vernacularName
					end
				end
			end
			if vernExact then score = score + 3 elseif vernLoose then score = score + 1 end
			if not bestScore or score > bestScore then
				bestScore = score
				best = {
					canonicalName = r.canonicalName or r.species,
					commonName = matchedEng and displayCommon( matchedEng ) or nil,
					usageKey = r.nubKey or r.speciesKey or r.key,
				}
			end
		end
	end
	-- Require at least a minimal signal so junk common candidates don't resolve.
	if best and ( bestScore or 0 ) >= 3 then return best end
	return nil
end
M._pickSearchResult = pickSearchResult

--------------------------------------------------------------------------------
-- network functions (use injected deps.http; cache via deps.cache if present)

local function httpGetJson( url, deps )
	if deps.cache and deps.cache[ url ] ~= nil then
		return deps.cache[ url ]
	end
	local body = deps.http.get( url )
	local decoded = nil
	if body and body ~= '' then
		decoded = json.decode( body )
	end
	if deps.cache then deps.cache[ url ] = decoded or false end
	return decoded
end

-- Resolve a scientific binomial to a canonical taxon (or nil if not acceptable).
function M.matchScientific( name, deps )
	local d = httpGetJson( M.matchUrl( name ), deps )
	local t = normalizeMatch( d )
	if acceptable( t ) then return t end
	return nil
end

-- Resolve a common name -> { canonicalName, commonName, usageKey } via search.
function M.searchVernacular( name, deps )
	local d = httpGetJson( M.searchUrl( name ), deps )
	return pickSearchResult( d, name )
end

-- Best-effort preferred English common name for a usageKey.
function M.vernacularEnglish( usageKey, deps )
	if not usageKey then return nil end
	local d = httpGetJson( M.vernacularUrl( usageKey ), deps )
	return pickVernacular( d )
end

-- Resolve one parser candidate to a full taxon, or nil.
--   candidate : { name = <string>, kind = 'scientific'|'common' }
--   deps      : { http = <adapter>, cache = <table?> }
--   opts      : { fetchVernacular = <bool, default true> }
function M.resolve( candidate, deps, opts )
	opts = opts or {}
	local fetchVern = opts.fetchVernacular ~= false
	local taxon, common

	if candidate.kind == 'scientific' then
		taxon = M.matchScientific( candidate.name, deps )
	else
		local sr = M.searchVernacular( candidate.name, deps )
		if sr then
			common = sr.commonName or displayCommon( candidate.name )
			taxon = M.matchScientific( sr.canonicalName, deps )
			-- carry GBIF's accepted scientific even if the re-match is unexpectedly fuzzy
			if taxon then taxon.usageKey = taxon.usageKey or sr.usageKey end
		end
	end

	if not taxon then return nil end
	taxon.commonName = common or taxon.commonName
	if fetchVern and not taxon.commonName then
		taxon.commonName = M.vernacularEnglish( taxon.usageKey, deps )
	end
	taxon.commonName = taxon.commonName and displayCommon( taxon.commonName ) or nil
	return taxon
end

M._test = {
	normalizeMatch = normalizeMatch,
	acceptable = acceptable,
	pickVernacular = pickVernacular,
	pickSearchResult = pickSearchResult,
	displayCommon = displayCommon,
	norm = norm,
}

return M
