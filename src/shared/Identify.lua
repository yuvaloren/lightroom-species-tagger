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

WHAT THE CONFIDENCE NUMBER IS (and is not): it is a *bounded evidence score*, not a
calibrated probability. It rises monotonically with how much mutually-agreeing
evidence supports a taxon, and the squash keeps it in (0,1) so a single threshold
works — but a "0.62" does NOT mean "62% of such tags are correct". The weights above
are hand-chosen, not fitted to a labelled dataset. So treat the threshold as an
operating point (higher = fewer wrong tags, more photos left for review), and ground
it in YOUR data with the calibration sweep: `just live-accuracy -- --sweep` reports
precision/recall at each threshold over your real captures. See docs/SCORING.md.

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
	-- Common names are ambiguous (many species share / swap them), so by default a
	-- confident auto-apply requires a confirmed Latin binomial. A common-name-only
	-- taxon can still be confident if it recurs strongly (commonOnlyHits agreeing
	-- hits); set high to effectively require a binomial.
	commonOnlyHits = 6,
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

-- Would this aggregated taxon auto-apply at `threshold`? The single gate used both by
-- run() and by the calibration sweep (scripts/live-accuracy.lua --sweep), so a swept
-- threshold means exactly what the plugin would do. A confident taxon needs a confirmed
-- binomial OR strong common-name agreement, enough support, and — when the provider gave
-- an authoritative answer (Lens's AI Overview) — to be one it named.
function M.confidentAt( a, threshold, cfg, hasAuthoritative )
	cfg = cfg or M.DEFAULTS
	local trusted = ( not hasAuthoritative ) or a.authoritative
	-- Only a species/subspecies auto-applies. A genus-rank match is either a real
	-- genus-only answer (better left for review) or a fabricated pseudo-binomial the
	-- resolver collapsed to its genus ("Mexico and" -> genus Mexico); never auto-tag it.
	local rank = a.taxon and a.taxon.rank
	return a.confidence >= threshold
		and a.finalSupport >= ( cfg.minSupport or M.DEFAULTS.minSupport )
		and ( a.sci or a.hits >= ( cfg.commonOnlyHits or M.DEFAULTS.commonOnlyHits ) )
		and ( rank == 'SPECIES' or rank == 'SUBSPECIES' )
		and trusted
end

-- True when the AI Overview commits only to a GENUS ("genus X" / "X genus") and no
-- authoritative species resolved. In that case a binomial that appears only in the
-- visual-match titles is a lookalike congener, not Lens's answer, so it must not
-- auto-apply (Fix 4). Read-only over the observations.
local function overviewStatesGenusOnly( observations, hasAuthoritative )
	if hasAuthoritative then return false end
	for _, o in ipairs( observations or {} ) do
		if o.authoritative and type( o.text ) == 'string'
			and ( o.text:find( '[Gg]enus%s+%u%l+' ) or o.text:find( '%u%l+%s+genus' ) ) then
			return true
		end
	end
	return false
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
				if c.authoritative then agg.authoritative = true end
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

	-- If the provider gave an authoritative answer (e.g. Lens's AI Overview names
	-- the species), trust ONLY species it named — the visual-match titles surface
	-- many binomial-bearing lookalikes that would otherwise auto-apply as false
	-- positives. With no authoritative signal, fall back to binomial/agreement.
	local hasAuthoritative = false
	for _, a in ipairs( results ) do if a.authoritative then hasAuthoritative = true; break end end

	local genusOnly = overviewStatesGenusOnly( observations, hasAuthoritative )
	local confident = {}
	for _, a in ipairs( results ) do
		a.confident = M.confidentAt( a, cfg.autoApplyThreshold, cfg, hasAuthoritative )
		-- Genus-only overview: keep title-borne lookalike binomials out of auto-apply
		-- (they still appear in `results` for review). Downgrade, don't delete.
		if a.confident and genusOnly and not a.authoritative then a.confident = false end
		if a.confident then confident[ #confident + 1 ] = a end
	end

	return {
		candidates = cands,
		results = results,
		confident = confident,
		hasAuthoritative = hasAuthoritative,
		top = results[ 1 ],
		decision = ( #confident > 0 ) and 'apply' or 'review',
	}
end

M._test = { merge = merge }

return M
