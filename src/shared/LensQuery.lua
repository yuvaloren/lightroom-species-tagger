--[[----------------------------------------------------------------------------
LensQuery.lua
Compose the text refinement added to a Google Lens *visual* search (the multisearch
"add to your search" box) from two optional user inputs:

  * location  — where the photo was taken ("Monterey, California", "Serengeti").
  * other     — any other identifying info ("juvenile", "in flight", "nudibranch").

The location must be framed as CONTEXT, not subject: Lens reads a bare place name as
part of what you're searching for, which throws the identification off. HOW to frame
it is an open, testable question, so the framings live in M.STRATEGIES and the
default is pinned in M.DEFAULT_STRATEGY. The regression corpus (scripts/capture-
corpus.lua) captures real Lens output under several strategies so the best default
is chosen from data, not asserted — see docs/SCORING.md.

  compose{ location=, other=, strategy= } -> query string | nil
      other + framed location per the named strategy, e.g.
        strategy 'in'            -> "juvenile in Monterey, California"
        strategy 'location'      -> "juvenile location: Monterey, California"
        strategy 'none'          -> "juvenile"            (location not added as text)

  build( other, location [, prep] ) -> query string | nil
      Back-compat shim for the original single-strategy caller (prepends "in ").

Pure — no network, no Lightroom — so it's unit-tested (spec/lensquery_spec.lua).
------------------------------------------------------------------------------]]

local M = {}

local function trim( s )
	return ( s:gsub( '^%s+', '' ):gsub( '%s+$', '' ) )
end

local function nonEmpty( s )
	return type( s ) == 'string' and s:match( '%S' ) ~= nil
end

-- How to phrase the location as context. Each frame(place) returns the location
-- clause (already-trimmed place); the composer joins it after the "other" text.
-- Ordered most-conservative first; keep ids stable (they name capture directories).
M.STRATEGIES = {
	-- The natural-language INSTRUCTION form. Verified to disambiguate visually
	-- ambiguous subjects (e.g. northern elephant seals at Año Nuevo): it makes Lens's
	-- AI Overview answer "Based on the location provided, the animal is <Species
	-- (Binomial)>" — a confident binomial where a plain image search only hedged. This
	-- is the strategy for the location-ASSISTED pass (hard cases), NOT the default
	-- first pass (which omits location — location hurts easy, web-matchable photos).
	{ id = 'identify-location', label = 'identify picture using location: <place>', frame = function( p ) return 'identify picture using location: ' .. p end },
	{ id = 'in',            label = 'in <place>',              frame = function( p ) return 'in ' .. p end },
	{ id = 'photographed',  label = 'photographed in <place>', frame = function( p ) return 'photographed in ' .. p end },
	{ id = 'seen',          label = 'seen in <place>',         frame = function( p ) return 'seen in ' .. p end },
	{ id = 'bare',          label = '<place>',                 frame = function( p ) return p end },
	{ id = 'location',      label = 'location: <place>',       frame = function( p ) return 'location: ' .. p end },
	{ id = 'location-info', label = 'location info: <place>',  frame = function( p ) return 'location info: ' .. p end },
	{ id = 'none',          label = '(location not added as text)', frame = function( _ ) return nil end },
}

-- The framing used by the plugin until the capture sweep says otherwise. "in" is
-- the conservative natural-language default the module shipped with.
M.DEFAULT_STRATEGY = 'in'

local byId = {}
for _, s in ipairs( M.STRATEGIES ) do byId[ s.id ] = s end
M.strategy = function( id ) return byId[ id ] end

-- compose{ location=, other=, strategy= } -> query | nil
--   location : place text (nil/'' to omit)
--   other    : other identifying info (nil/'' to omit)
--   strategy : a strategy id (default M.DEFAULT_STRATEGY); unknown ids fall back to it
function M.compose( opts )
	opts = opts or {}
	local strat = byId[ opts.strategy ] or byId[ M.DEFAULT_STRATEGY ]
	local parts = {}
	if nonEmpty( opts.other ) then parts[ #parts + 1 ] = trim( opts.other ) end
	if nonEmpty( opts.location ) then
		local clause = strat.frame( trim( opts.location ) )
		if nonEmpty( clause ) then parts[ #parts + 1 ] = clause end
	end
	if #parts == 0 then return nil end
	return table.concat( parts, ' ' )
end

-- build( other, location [, prep] ) -> query | nil
-- Back-compat: the original API prepended a preposition (default 'in') to the place.
-- Preserved so existing callers/tests keep working; new code should use compose().
function M.build( other, location, prep )
	prep = ( prep and prep ~= '' ) and prep or 'in'
	local parts = {}
	if nonEmpty( other ) then parts[ #parts + 1 ] = trim( other ) end
	if nonEmpty( location ) then parts[ #parts + 1 ] = prep .. ' ' .. trim( location ) end
	if #parts == 0 then return nil end
	return table.concat( parts, ' ' )
end

return M
