--[[----------------------------------------------------------------------------
SpeciesParser.lua
The pure heart of the identifier. Takes the *normalized observations* a provider
produced (Google Lens label guesses + web-page titles, or Vision best-guess
labels + web entities) and turns them into a ranked list of NAME CANDIDATES:

  { name = 'Sufflamen bursa', kind = 'scientific', score = 4.1, hits = 3 }
  { name = 'Lei triggerfish', kind = 'common',     score = 2.0, hits = 2 }

Two channels are mined from every observation:
  * scientific binomials   — a "Genus species" pattern (high precision once the
    taxonomy step confirms them against GBIF; this stage is deliberately
    permissive and lets GBIF be the final gate).
  * common-name candidates — cleaned label text / the leading segment of a page
    title, with site boilerplate stripped.

No network, no Lightroom — fully unit-testable. Internals are exposed on
`SpeciesParser._test` for white-box tests.

An "observation" is: { text = <string>, kind = 'label'|'entity'|'title',
weight = <number>, source = <string>, url = <string?> }.
------------------------------------------------------------------------------]]

local M = {}

local function toSet( list )
	local s = {}
	for _, w in ipairs( list ) do s[ w:lower() ] = true end
	return s
end

-- First tokens that look like a genus but are almost always English title noise.
-- Precision helper only — GBIF still gates every scientific candidate.
M.GENUS_STOPWORDS = toSet {
	'The', 'A', 'An', 'Of', 'In', 'On', 'And', 'Or', 'For', 'With', 'From',
	'New', 'San', 'Los', 'Las', 'El', 'La', 'Le', 'De', 'Del', 'Da', 'Di',
	'Sea', 'Red', 'Big', 'Blue', 'Black', 'White', 'Green', 'Giant', 'Common',
	'Stock', 'Royalty', 'Getty', 'Photo', 'Image', 'Images', 'Picture', 'Reef',
	'Coral', 'Wild', 'Marine', 'Tropical', 'Hawaiian', 'Pacific', 'Indian',
	'How', 'What', 'Why', 'When', 'Where', 'Best', 'Top', 'Free', 'Premium',
	'Day', 'Night', 'Adult', 'Juvenile', 'Male', 'Female', 'Baby', 'Young',
	'Close', 'Side', 'Front', 'Two', 'Three', 'Spotted', 'Spiny', 'Long', 'Short',
}

-- English function words that are never Latin species epithets. Checked on the
-- SECOND (species) token only, so no genuine epithet can be filtered. This kills
-- the pseudo-binomials the "Genus species" regex mines out of range prose, e.g.
-- "native to India and Sri Lanka" -> "India and" / "Lanka and" (epithet "and"),
-- "found in Mexico and…" -> "Mexico and" — GBIF then resolves the leading token to
-- a real GENUS and the junk would auto-apply. (Short words like 'is'/'or' are
-- already rejected by the >=3-char rule.)
M.EPITHET_STOPWORDS = toSet {
	'and', 'are', 'the', 'this', 'these', 'that', 'was', 'were', 'from', 'with',
	'its', 'has', 'have', 'their', 'they', 'which', 'when', 'where', 'near', 'such', 'also',
}

-- Site / boilerplate tokens stripped from page titles before they become
-- common-name candidates (compared case-insensitively, as whole segments).
M.TITLE_NOISE = toSet {
	'wikipedia', 'inaturalist', 'flickr', 'reddit', 'youtube', 'facebook',
	'instagram', 'pinterest', 'fishbase', 'reef guide', 'reefguide',
	'sealifebase', 'animalia', 'eol', 'encyclopedia of life', 'shutterstock',
	'alamy', 'istock', 'adobe stock', 'getty images', 'stock photo',
	'stock photos', 'royalty free', 'royalty-free', 'depositphotos', 'dreamstime',
}

--------------------------------------------------------------------------------
-- text helpers

local function trim( s )
	return ( s:gsub( '^%s+', '' ):gsub( '%s+$', '' ) )
end

-- Uppercase only the first letter (Vision's bestGuessLabels often arrive all
-- lower-case, e.g. "sufflamen bursa"; this lets the binomial regex see them).
local function capitalizeFirst( s )
	if not s or s == '' then return s end
	return s:sub( 1, 1 ):upper() .. s:sub( 2 )
end

local function collapseWs( s )
	return ( s:gsub( '%s+', ' ' ) )
end

-- normalized key for de-duplication
local function normKey( s )
	return ( trim( collapseWs( s ) ):lower() )
end

-- Capitalize first letter, lowercase the rest of the string's words minimally:
-- common names are conventionally lower-case except a leading capital.
local function titleCommon( s )
	s = trim( collapseWs( s ) )
	if s == '' then return s end
	return s:sub( 1, 1 ):upper() .. s:sub( 2 )
end
M.titleCommon = titleCommon

local function isBinomialTokens( genus, species )
	if M.GENUS_STOPWORDS[ genus:lower() ] then return false end
	if #genus < 3 then return false end
	if #species < 3 then return false end
	if M.EPITHET_STOPWORDS[ species:lower() ] then return false end
	return true
end

-- Extract "Genus species" candidates from a piece of text. Returns a list of
-- { name = 'Genus species', strong = <bool> }. `strong` means the binomial was
-- found inside parentheses (the conventional "Common name (Genus species)"
-- form), which is a much stronger signal than a bare in-title occurrence.
local function extractScientific( text )
	if not text or text == '' then return {} end
	text = collapseWs( text )
	local found, order = {}, {}

	local function add( genus, species, strong )
		if not isBinomialTokens( genus, species ) then return end
		local name = genus .. ' ' .. species:lower()
		local key = name:lower()
		if found[ key ] == nil then
			order[ #order + 1 ] = name
			found[ key ] = strong
		elseif strong and not found[ key ] then
			found[ key ] = true
		end
	end

	-- strong pass: anything inside parentheses
	for inner in text:gmatch( '%b()' ) do
		for g, sp in inner:gmatch( '(%u%l+)%s+(%l[%l%-]+)' ) do
			add( g, sp, true )
		end
	end
	-- weak pass: whole text
	for g, sp in text:gmatch( '(%u%l+)%s+(%l[%l%-]+)' ) do
		add( g, sp, false )
	end

	local out = {}
	for _, name in ipairs( order ) do
		out[ #out + 1 ] = { name = name, strong = found[ name:lower() ] }
	end
	return out
end

-- Strip a trailing scientific parenthetical and obvious site noise from a
-- single title/label segment; return a clean common-name candidate or nil.
local function cleanCommon( segment )
	if not segment then return nil end
	local s = trim( collapseWs( segment ) )
	s = s:gsub( '%s*%b()%s*$', '' ) -- drop a trailing "(Genus species)" etc.
	s = trim( s )
	if s == '' then return nil end
	-- reject pure noise / junk
	if M.TITLE_NOISE[ s:lower() ] then return nil end
	if s:find( '%d' ) then return nil end        -- model numbers, years, sizes
	if s:find( 'http' ) then return nil end
	local _, spaces = s:gsub( ' ', '' )
	local words = #s - spaces -- not exact word count, but cheap upper bound proxy
	if words > 40 then return nil end             -- absurdly long → not a name
	local wordCount = select( 2, s:gsub( '%S+', '' ) )
	if wordCount > 5 then return nil end          -- a phrase, not a species name
	return s
end
M._cleanCommon = cleanCommon

-- Take the leading subject segment out of a page title (before the first " - ",
-- "|", "–", "—", ":" separator) and clean it.
local function commonFromTitle( title )
	if not title then return nil end
	local s = collapseWs( title )
	-- split on the first separator
	local head = s:match( '^(.-)%s+[%-%|–—:·]%s+' ) or s:match( '^(.-)[%|–—:]' ) or s
	return cleanCommon( head )
end

--------------------------------------------------------------------------------
-- main entry

local DEFAULT_WEIGHTS = {
	scientific = 2.0, -- a confirmed binomial is worth more than a common name
	strongCtx = 1.5,  -- multiplier when the binomial was parenthetical
	commonLabel = 1.0,
	commonTitle = 0.5,
}

-- candidates( observations [, opts] ) -> rankedCandidates
--   opts.weights : override DEFAULT_WEIGHTS
--   opts.max     : cap on returned candidates (default 24)
function M.candidates( observations, opts )
	opts = opts or {}
	local w = {}
	for k, v in pairs( DEFAULT_WEIGHTS ) do w[ k ] = v end
	if opts.weights then for k, v in pairs( opts.weights ) do w[ k ] = v end end

	local acc = {} -- key (kind:normname) -> entry

	-- `authoritative` marks a candidate that came from an authoritative observation
	-- (obs.authoritative — e.g. Google Lens's AI Overview, its single best answer),
	-- so the scorer can trust it over noisy supporting matches.
	local function bump( name, kind, weight, authoritative )
		if not name or name == '' then return end
		local key = kind .. ':' .. normKey( name )
		local e = acc[ key ]
		if not e then
			e = { name = name, kind = kind, score = 0, hits = 0 }
			acc[ key ] = e
		end
		e.score = e.score + weight
		e.hits = e.hits + 1
		if authoritative then e.authoritative = true end
	end

	for _, obs in ipairs( observations or {} ) do
		local ow = obs.weight or 1.0
		local auth = obs.authoritative
		-- scientific channel. Always scan the text as-is; for short "label" text
		-- (e.g. Vision bestGuessLabels) also scan a first-letter-capitalized copy
		-- so an all-lower-case binomial is still seen. De-dup within the obs.
		local texts = { obs.text }
		if obs.kind == 'label' or obs.kind == 'entity' then
			texts[ #texts + 1 ] = capitalizeFirst( obs.text )
		end
		local seenSci = {}
		for _, t in ipairs( texts ) do
			for _, sci in ipairs( extractScientific( t ) ) do
				local k = sci.name:lower()
				if not seenSci[ k ] then
					seenSci[ k ] = true
					local mult = sci.strong and w.strongCtx or 1.0
					bump( sci.name, 'scientific', ow * w.scientific * mult, auth )
				end
			end
		end
		-- common channel
		local common
		if obs.kind == 'title' then
			common = commonFromTitle( obs.text )
			if common then bump( titleCommon( common ), 'common', ow * w.commonTitle, auth ) end
		else -- 'label' / 'entity' / anything else: treat the text as a clean-ish label
			common = cleanCommon( obs.text )
			if common then bump( titleCommon( common ), 'common', ow * w.commonLabel, auth ) end
		end
	end

	local list = {}
	for _, e in pairs( acc ) do list[ #list + 1 ] = e end
	table.sort( list, function( a, b )
		if a.score ~= b.score then return a.score > b.score end
		if a.hits ~= b.hits then return a.hits > b.hits end
		return a.name < b.name
	end )

	local max = opts.max or 24
	while #list > max do table.remove( list ) end
	return list
end

--------------------------------------------------------------------------------
-- white-box test surface
M._test = {
	extractScientific = extractScientific,
	cleanCommon = cleanCommon,
	commonFromTitle = commonFromTitle,
	titleCommon = titleCommon,
	normKey = normKey,
	isBinomialTokens = isBinomialTokens,
}

return M
