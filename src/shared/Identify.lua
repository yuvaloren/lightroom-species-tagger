--[[----------------------------------------------------------------------------
Identify.lua
The orchestrator. Given a provider's observations and a taxonomy `resolve`
function, it produces a ranked, confidence-scored list of identified taxa and a
decision ('apply' when at least one taxon clears the auto-apply threshold, else
'review').

Pure and network-free: the taxonomy resolver is injected as `deps.resolve`
(candidate -> taxon|nil). In Lightroom that's Taxonomy.resolve over LrHttp; in
tests it's a fixture-backed function. This is what makes accuracy a deterministic,
offline regression test.

Scoring (transparent + tunable via cfg; see M.DEFAULTS):
  contribution = candidate.score
               * kindFactor[kind]        -- a confirmed binomial outweighs a common name
               * matchFactor[matchType]  -- EXACT > FUZZY
               * rankFactor[rank]        -- species > genus
  finalSupport = sum(contributions) * agreementBonus(if both a scientific AND a
                 common candidate resolved to the same taxon)
  confidence   = finalSupport / (finalSupport + squashK)   -- squashed to (0,1)

Multi-subject images work naturally: every taxon clearing the threshold is
returned in `confident`, so a frame with two animals can tag both.
------------------------------------------------------------------------------]]

local SpeciesParser = require 'SpeciesParser'

local M = {}

M.DEFAULTS = {
	autoApplyThreshold = 0.62,
	maxCandidates = 14, -- bound on resolver calls per image
	squashK = 2.0,
	minSupport = 0.8, -- floor below which nothing is ever "confident"
	kingdoms = { -- allow-list: only living-thing kingdoms (GBIF only returns these anyway)
		Animalia = true, Plantae = true, Fungi = true,
		Chromista = true, Protozoa = true, Bacteria = true, Archaea = true,
		Viruses = true,
	},
	kindFactor = { scientific = 2.0, common = 1.0 },
	matchFactor = { EXACT = 1.0, FUZZY = 0.8, HIGHERRANK = 0.4 },
	rankFactor = { SPECIES = 1.0, SUBSPECIES = 1.0, GENUS = 0.5 },
	agreementBonus = 1.3,
}

local function merge( base, over )
	local out = {}
	for k, v in pairs( base ) do out[ k ] = v end
	if over then for k, v in pairs( over ) do out[ k ] = v end end
	return out
end

function M.confidence( finalSupport, squashK )
	squashK = squashK or M.DEFAULTS.squashK
	if finalSupport <= 0 then return 0 end
	return finalSupport / ( finalSupport + squashK )
end

-- run( observations, deps, cfg ) -> result
--   deps.resolve(candidate) -> taxon|nil   (required)
function M.run( observations, deps, cfg )
	cfg = merge( M.DEFAULTS, cfg )
	assert( deps and type( deps.resolve ) == 'function', 'Identify.run needs deps.resolve' )

	local cands = SpeciesParser.candidates( observations, { max = cfg.maxCandidates } )

	local byKey, order = {}, {}
	for i, c in ipairs( cands ) do
		if i > cfg.maxCandidates then break end
		local taxon = deps.resolve( c )
		local kingdomOk = ( not taxon )
			or ( not taxon.kingdom ) or cfg.kingdoms[ taxon.kingdom ] == true
		if taxon and kingdomOk and taxon.usageKey then
			local key = taxon.usageKey
			local agg = byKey[ key ]
			if not agg then
				agg = { taxon = taxon, support = 0, hits = 0,
					sci = false, common = false, candidates = {} }
				byKey[ key ] = agg
				order[ #order + 1 ] = key
			end
			local kf = cfg.kindFactor[ c.kind ] or 1.0
			local mf = cfg.matchFactor[ taxon.matchType or 'EXACT' ] or 0.8
			local rf = cfg.rankFactor[ taxon.rank or 'SPECIES' ] or 0.8
			agg.support = agg.support + ( c.score * kf * mf * rf )
			agg.hits = agg.hits + ( c.hits or 1 )
			if c.kind == 'scientific' then agg.sci = true else agg.common = true end
			-- Prefer a common name the recognition signal actually surfaced (a
			-- 'common' candidate) over GBIF's arbitrary "first English" vernacular
			-- from a scientific lookup — e.g. "Day octopus", not "Cyane's octopus".
			if taxon.commonName then
				local fromCommon = ( c.kind == 'common' )
				if not agg.taxon.commonName or ( fromCommon and not agg.commonObserved ) then
					agg.taxon.commonName = taxon.commonName
					agg.commonObserved = fromCommon
				end
			end
			agg.candidates[ #agg.candidates + 1 ] = c
		end
	end

	local results = {}
	for _, key in ipairs( order ) do
		local a = byKey[ key ]
		local bonus = ( a.sci and a.common ) and cfg.agreementBonus or 1.0
		a.finalSupport = a.support * bonus
		a.confidence = M.confidence( a.finalSupport, cfg.squashK )
		results[ #results + 1 ] = a
	end
	table.sort( results, function( x, y )
		if x.finalSupport ~= y.finalSupport then return x.finalSupport > y.finalSupport end
		if x.hits ~= y.hits then return x.hits > y.hits end
		return ( x.taxon.scientificName or '' ) < ( y.taxon.scientificName or '' )
	end )

	local confident = {}
	for _, a in ipairs( results ) do
		a.confident = a.confidence >= cfg.autoApplyThreshold
			and a.finalSupport >= cfg.minSupport
			and ( a.sci or a.hits >= 2 )
		if a.confident then confident[ #confident + 1 ] = a end
	end

	return {
		candidates = cands,
		results = results,
		confident = confident,
		top = results[ 1 ],
		decision = ( #confident > 0 ) and 'apply' or 'review',
	}
end

M._test = { merge = merge }

return M
