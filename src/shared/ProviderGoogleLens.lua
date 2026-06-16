--[[----------------------------------------------------------------------------
ProviderGoogleLens.lua
Google Lens results WITHOUT any paid API — we talk to Google Lens directly.

The image bytes are POSTed (multipart, field `encoded_image`) to
https://lens.google.com/v3/upload; Google answers with a redirect to a results
page whose HTML embeds the match data inside `AF_initDataCallback({... data:[…]})`
script blocks. fetch() pulls that embedded JSON out of the HTML; parse() then
harvests the human-readable strings from it (best-guess label + the titles of the
pages showing the same image) and hands them to the shared parser/GBIF/scorer.

Why harvest strings instead of walking fixed array offsets? Google's Lens layout
is undocumented and the nested indices move without notice (a big change landed
Feb 2025). Rather than hard-code `data[0][1][8][12][0]` and break silently, we
walk the whole decoded structure and keep every string that looks like a name or
page title. That is deliberately recall-oriented and noisy — precision is the
job of the downstream pipeline (binomial detection + GBIF gating + the scorer),
which already treats provider output as untrusted. Layout drift then degrades
recall gracefully instead of returning confident garbage.

Reliability note: Google actively blocks automated access (SearchGuard JS
challenges, consent walls, datacenter-IP throttling). From a normal residential
connection a few occasional, throttled requests usually succeed; when Google
blocks or changes the page, fetch() returns a clear error / parse() returns
nothing and the photo simply falls through to "needs review" — it never crashes.
This backend needs no key and uploads the bytes directly, so no API key and no
image host are involved.

parse()/extractData() are pure; fetch()/identify() use the injected deps.http.
------------------------------------------------------------------------------]]

local json = require 'dkjson'

local M = {
	id = 'lens',
	label = 'Google Lens (direct, no key)',
	needsImageFile = true,  -- uploads bytes as an LrHttp multipart file (no image host)
	UPLOAD_URL = 'https://lens.google.com/v3/upload',
	-- A current desktop-Chrome UA + a consent ("SOCS") cookie so Google serves
	-- results instead of the EU consent interstitial. These are the only knobs we
	-- have from LrHttp (which has no cookie jar across redirects); update the UA
	-- periodically if Google starts rejecting it.
	USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' ..
		'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
	CONSENT_COOKIE = 'SOCS=CAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg; CONSENT=YES+',
}

--------------------------------------------------------------------------------
-- pure helpers

local function urlencode( s )
	return ( tostring( s ):gsub( '[^%w%-_%.~]', function( c )
		return string.format( '%%%02X', string.byte( c ) )
	end ) )
end

-- Is this string a plausible name / page-title candidate (vs. a token, URL,
-- id, hash, css, etc.)? Deliberately permissive — the shared parser + GBIF do
-- the precise filtering downstream.
local function isCandidate( s )
	if type( s ) ~= 'string' then return false end
	local n = #s
	if n < 3 or n > 120 then return false end
	if s:find( '://' ) or s:find( 'www%.' ) then return false end  -- URLs
	if s:find( '[<>{}=;\\]' ) then return false end                -- markup / code
	if s:find( ':' ) and not s:find( '%s' ) then return false end  -- key:val tokens (e.g. ds:0)
	if s:find( '@' ) or s:find( '#' ) then return false end        -- handles / ids
	if not s:find( '%l' ) then return false end                    -- needs a lower-case letter
	if not s:find( '%a%a' ) then return false end                  -- needs real letters
	if not s:find( '%s' ) and n > 28 then return false end         -- long single token = id/base64
	local _, digits = s:gsub( '%d', '' )
	if digits * 2 > n then return false end                        -- mostly digits
	return true
end
M._isCandidate = isCandidate

-- Walk a decoded JSON structure and return the unique candidate strings in a
-- deterministic, first-seen order (sequence parts before map parts).
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

-- Slice a balanced [...] (or {...}) starting at byte index `i`, honouring JSON
-- string quoting so brackets inside strings don't confuse the depth counter.
local function balancedSlice( s, i )
	local depth, n = 0, #s
	local inStr, esc = false, false
	for j = i, n do
		local c = s:sub( j, j )
		if inStr then
			if esc then esc = false
			elseif c == '\\' then esc = true
			elseif c == '"' then inStr = false end
		else
			if c == '"' then inStr = true
			elseif c == '[' or c == '{' then depth = depth + 1
			elseif c == ']' or c == '}' then
				depth = depth - 1
				if depth == 0 then return s:sub( i, j ) end
			end
		end
	end
	return nil
end

-- Pull the `data:[…]` arrays out of every AF_initDataCallback(...) block in the
-- results HTML and JSON-decode them. Returns a list of decoded structures (or a
-- single one), or nil if none were found. Tolerant by design.
function M.extractData( html )
	if type( html ) ~= 'string' or html == '' then return nil end
	local datas, idx = {}, 1
	while true do
		local s = html:find( 'AF_initDataCallback', idx, true )
		if not s then break end
		local dpos = html:find( 'data:', s, true )
		local bstart = dpos and html:find( '%[', dpos )
		if bstart then
			local slice = balancedSlice( html, bstart )
			if slice then
				local decoded = json.decode( slice )
				if decoded ~= nil then datas[ #datas + 1 ] = decoded end
			end
			idx = bstart + 1
		else
			idx = s + #'AF_initDataCallback'
		end
	end
	if #datas == 0 then return nil end
	if #datas == 1 then return datas[ 1 ] end
	return datas
end

-- parse( decoded ) -> observations[]   (decoded = extractData()'s output)
function M.parse( decoded )
	local obs = {}
	if type( decoded ) ~= 'table' then return obs end
	local MAX = 30 -- bound the candidate count (each becomes a GBIF lookup downstream)
	for i, text in ipairs( harvest( decoded ) ) do
		if i > MAX then break end
		obs[ #obs + 1 ] = { text = text, kind = 'title', weight = 0.5, source = 'lens:web' }
	end
	return obs
end

--------------------------------------------------------------------------------
-- network (production; uses injected deps.http)

function M.buildUploadUrl( opts )
	return M.UPLOAD_URL .. '?hl=' .. urlencode( opts.hl or 'en' ) ..
		'&gl=' .. urlencode( opts.country or 'us' )
end

-- LrHttp.postMultipart content array: the image goes in the `encoded_image` part.
function M.buildParts( opts )
	return { {
		name = 'encoded_image',
		fileName = opts.fileName or 'image.jpg',
		filePath = opts.imageFile,
		contentType = opts.contentType or 'image/jpeg',
	} }
end

function M.buildHeaders()
	return {
		[ 'User-Agent' ] = M.USER_AGENT,
		[ 'Cookie' ] = M.CONSENT_COOKIE,
		[ 'Accept-Language' ] = 'en-US,en;q=0.9',
	}
end

-- Recognise the common "Google won't serve you" pages so we can report a clear
-- reason instead of silently finding nothing.
local function blockReason( html )
	if not html or html == '' then return 'no response from Google Lens' end
	if html:find( 'unusual traffic', 1, true ) or html:find( '/sorry/', 1, true ) then
		return 'Google is rate-limiting this network ("unusual traffic"). Wait a while and retry, ' ..
			'or use the Pl@ntNet / Vision backend.'
	end
	if html:find( 'Error 403', 1, true ) or html:find( 'consent.google.com', 1, true ) then
		return 'Google Lens blocked this request (403 / consent wall). This is common from ' ..
			'shared or datacenter networks; try again later or use another backend.'
	end
	return nil
end

-- fetch( opts, deps ) -> decoded, err   (opts: imageFile, hl, country)
function M.fetch( opts, deps )
	if not opts.imageFile then return nil, 'Google Lens needs an image file (opts.imageFile)' end
	local body = deps.http.postMultipart( M.buildUploadUrl( opts ), M.buildParts( opts ), M.buildHeaders() )
	local reason = blockReason( body )
	if reason then return nil, reason end
	local decoded = M.extractData( body )
	if not decoded then
		return nil, 'Google Lens returned no parseable results (the page layout may have changed, ' ..
			'or the request was blocked).'
	end
	return decoded
end

function M.identify( opts, deps )
	local decoded, err = M.fetch( opts, deps )
	if not decoded then return {}, err end
	return M.parse( decoded )
end

M._test = { balancedSlice = balancedSlice, blockReason = blockReason, harvest = harvest }

return M
