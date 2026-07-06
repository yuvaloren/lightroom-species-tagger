--[[----------------------------------------------------------------------------
LensQuery.lua
Compose the text refinement added to a Google Lens *visual* search (the multisearch
"add to your search" box) from the run's extra keywords and the photo's location.

The location must be framed as CONTEXT, not subject. Lens reads a bare place name
("Monterey, California") as part of what you're searching for, which throws the
identification off. Leading it with the preposition **"in "** turns it into a
natural-language locality hint — "in Monterey, California" reads as "[this subject]
in Monterey, California", i.e. *where the photo was taken* — so Lens favours species
that occur there instead of searching for the place. (A structured form like
"location:" is worse: Lens is natural-language, not operator-based, so it would treat
the literal word "location" as a search term.)

Result shapes:
  keywords + place -> "<keywords> in <place>"   e.g. "juvenile in Monterey, California"
  place only       -> "in <place>"              e.g. "in Monterey, California"
  keywords only    -> "<keywords>"
  neither          -> nil

Pure — no network, no Lightroom — so it's unit-tested (spec/lensquery_spec.lua).
------------------------------------------------------------------------------]]

local M = {}

local function trim( s )
	return ( s:gsub( '^%s+', '' ):gsub( '%s+$', '' ) )
end

local function nonEmpty( s )
	return type( s ) == 'string' and s:match( '%S' ) ~= nil
end

-- build( extraKeywords, placeText [, prep] ) -> query string | nil
--   prep : the locality preposition (default 'in'); exposed for callers/tests.
function M.build( extraKeywords, placeText, prep )
	prep = ( prep and prep ~= '' ) and prep or 'in'
	local parts = {}
	if nonEmpty( extraKeywords ) then parts[ #parts + 1 ] = trim( extraKeywords ) end
	if nonEmpty( placeText ) then parts[ #parts + 1 ] = prep .. ' ' .. trim( placeText ) end
	if #parts == 0 then return nil end
	return table.concat( parts, ' ' )
end

return M
