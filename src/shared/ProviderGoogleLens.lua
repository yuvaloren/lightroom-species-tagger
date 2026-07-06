--[[----------------------------------------------------------------------------
ProviderGoogleLens.lua
Google Lens results WITHOUT any paid API.

Google Lens has no anonymous API and its results page is rendered by JavaScript,
so it can't be read by a plain HTTP client (curl or Lightroom's LrHttp only get
the "enable JavaScript" shell). It IS reachable through a real browser: the
companion helper `scripts/lens/lens-search.js` uploads the image, transplants the
anonymous session into the user's installed Chrome, lets Chrome render the JS
results, and returns the visible match strings. That helper is injected here as
`deps.lensSearch( imageFile ) -> strings[], err`.

This module's job is the PURE part: take those match strings (page titles, the AI
overview, etc.) and harvest name candidates from them — deliberately recall-
oriented and noisy, because precision is the downstream pipeline's job (binomial
detection + GBIF gating + the scorer, which treat provider output as untrusted).

parse() is pure and unit-tested; identify() calls the injected deps.lensSearch.
------------------------------------------------------------------------------]]

local M = {
	id = 'lens',
	label = 'Google Lens (browser, no key)',
	needsImageFile = true,  -- the helper takes an image file path
	usesLensHelper = true,  -- driven via the browser helper, not deps.http
}

--------------------------------------------------------------------------------
-- pure helpers

-- Is this string a plausible name / page-title candidate (vs. a token, URL,
-- id, hash, css, etc.)? Deliberately permissive — the shared parser + GBIF do
-- the precise filtering downstream.
local function isCandidate( s )
	if type( s ) ~= 'string' then return false end
	local n = #s
	if n < 3 or n > 120 then return false end
	if s:find( '://' ) or s:find( 'www%.' ) then return false end  -- URLs
	if s:find( '[<>{}=;\\]' ) then return false end                -- markup / code
	if s:find( ':' ) and not s:find( '%s' ) then return false end  -- key:val tokens
	if s:find( '@' ) or s:find( '#' ) then return false end        -- handles / ids
	if not s:find( '%l' ) then return false end                    -- needs a lower-case letter
	if not s:find( '%a%a' ) then return false end                  -- needs real letters
	if not s:find( '%s' ) and n > 28 then return false end         -- long single token = id/base64
	local _, digits = s:gsub( '%d', '' )
	if digits * 2 > n then return false end                        -- mostly digits
	return true
end
M._isCandidate = isCandidate

-- Walk a value (string, or a list/tree of strings) and return the unique
-- candidate strings in deterministic first-seen order.
local function harvest( decoded )
	local seen, order = {}, {}
	local function walk( v, depth )
		if depth > 40 then return end
		local t = type( v )
		if t == 'string' then
			if isCandidate( v ) then
				local k = v:lower()
				if not seen[ k ] then seen[ k ] = true; order[ #order + 1 ] = v end
			end
		elseif t == 'table' then
			local len = #v
			for i = 1, len do walk( v[ i ], depth + 1 ) end
			for key, e in pairs( v ) do
				if not ( type( key ) == 'number' and key >= 1 and key <= len and key == math.floor( key ) ) then
					walk( e, depth + 1 )
				end
			end
		end
	end
	walk( decoded, 0 )
	return order
end
M._harvest = harvest

-- parse( decoded ) -> observations[]
--   decoded may be the helper's result table { overview = <string>, strings = {…} }
--   or a plain list of strings (representative fixtures / tests).
-- Google's "AI Overview" is its single authoritative answer (it names the species
-- and usually the binomial), so it's emitted as a strong 'label'; the visual-match
-- titles are noisy supporting signal at low weight. Precision stays the job of the
-- downstream binomial-detection + GBIF gating + scorer.
function M.parse( decoded )
	local obs = {}
	if type( decoded ) ~= 'table' then return obs end
	local overview = ( type( decoded.overview ) == 'string' ) and decoded.overview or nil
	local list = decoded.strings or decoded

	if overview and overview ~= '' then
		-- Google's AI Overview is its single authoritative answer; mark it so the
		-- scorer trusts it over the noisy (often binomial-bearing) match titles.
		obs[ #obs + 1 ] = { text = overview, kind = 'label', weight = 2.0, source = 'lens:ai', authoritative = true }
	end
	local MAX = 40 -- bound the candidate count (each may become a GBIF lookup downstream)
	for i, text in ipairs( harvest( list ) ) do
		if i > MAX then break end
		-- low weight: visual-match titles are noisy supporting signal (Lens shows many
		-- related species). The AI Overview above is the authoritative answer; titles
		-- mostly corroborate. Keeps the precision bar high for title-only candidates.
		obs[ #obs + 1 ] = { text = text, kind = 'title', weight = 0.35, source = 'lens:web' }
	end
	return obs
end

--------------------------------------------------------------------------------
-- identify: the browser helper does the upload + JS render; we harvest its output

-- identify( opts, deps ) -> observations[], err
--   opts.imageFile : path to the (downsized) JPEG
--   opts.lat/opts.lng : optional capture coordinates (helps Lens favour local species)
--   opts.place        : optional place name (city/state/country) used when there are
--                       no coordinates — the helper geocodes it
--   opts.query        : optional text refinement (user keywords + place name) added
--                       to the visual search (Lens "multisearch"); best-effort
--   opts.photoPath/opts.photoName : identity stamped on the keep-open tab so a later
--                       re-parse can re-tag this exact photo
--   deps.lensSearch( imageFile, lat, lng, place, query, photoPath, photoName ) -> strings[]|nil, err
function M.identify( opts, deps )
	if type( deps.lensSearch ) ~= 'function' then
		return {}, 'Google Lens needs the browser helper (deps.lensSearch) — see scripts/lens'
	end
	if not opts.imageFile then return {}, 'Google Lens needs an image file (opts.imageFile)' end
	local strings, err = deps.lensSearch( opts.imageFile, opts.lat, opts.lng, opts.place, opts.query,
		opts.photoPath, opts.photoName )
	if not strings then return {}, err or 'Google Lens returned nothing' end
	return M.parse( strings )
end

M._test = { harvest = harvest }

return M
