--[[----------------------------------------------------------------------------
ProviderGoogleVision.lua
Google Cloud Vision "Web Detection" (https://cloud.google.com/vision/docs/detecting-web).

This accepts the image bytes directly (base64 inline) in a JSON body — no
multipart, no image host. Web Detection is Google's reverse-image-search entity
pipeline; the useful signals are:
  * webDetection.bestGuessLabels[].label  — Google's single best guess
  * webDetection.webEntities[].description — ranked entities (with .score)
  * pagesWithMatchingImages[].pageTitle    — extra title signal

parse() is pure; fetch()/identify() use the injected deps.http.
------------------------------------------------------------------------------]]

local json = require 'dkjson'
local Base64 = require 'Base64'

local M = {
	id = 'vision',
	label = 'Google Vision (Web Detection)',
	-- no needsImageFile: Vision takes the bytes base64-inline in a JSON body
	ENDPOINT = 'https://vision.googleapis.com/v1/images:annotate',
}

function M.endpointWithKey( apiKey )
	return M.ENDPOINT .. '?key=' .. ( apiKey or '' )
end

-- buildBody( imageBase64 [, maxResults] ) -> JSON request string
function M.buildBody( imageBase64, maxResults )
	return json.encode( {
		requests = { {
			image = { content = imageBase64 },
			features = { { type = 'WEB_DETECTION', maxResults = maxResults or 15 } },
		} },
	} )
end

-- parse( decoded ) -> observations[]
function M.parse( decoded )
	local obs = {}
	local resp = decoded and decoded.responses and decoded.responses[ 1 ]
	if resp and resp.error and resp.error.message then return obs end
	local wd = resp and resp.webDetection
	if type( wd ) ~= 'table' then return obs end

	for _, bg in ipairs( wd.bestGuessLabels or {} ) do
		if bg.label and bg.label ~= '' then
			obs[ #obs + 1 ] = { text = bg.label, kind = 'label', weight = 1.3, source = 'vision:bestguess' }
		end
	end
	for _, e in ipairs( wd.webEntities or {} ) do
		if e.description and e.description ~= '' then
			local score = e.score or 0
			-- Vision's entity score is an opaque relevance; map to a 0.5..1.0 weight.
			local weight = 0.5 + math.min( 0.5, score / ( score + 1 ) )
			obs[ #obs + 1 ] = {
				text = e.description, kind = 'entity', weight = weight,
				source = 'vision:entity', score = score,
			}
		end
	end
	for _, p in ipairs( wd.pagesWithMatchingImages or {} ) do
		if p.pageTitle and p.pageTitle ~= '' then
			obs[ #obs + 1 ] = { text = p.pageTitle, kind = 'title', weight = 0.4, source = 'vision:page', url = p.url }
		end
	end
	return obs
end

-- fetch( opts, deps ) -> decoded, err   (opts: imageBytes, apiKey, maxResults)
function M.fetch( opts, deps )
	if not opts.imageBytes then return nil, 'Vision needs raw image bytes (opts.imageBytes)' end
	local body = M.buildBody( Base64.encode( opts.imageBytes ), opts.maxResults )
	local resBody = deps.http.post( M.endpointWithKey( opts.apiKey ), body,
		{ [ 'Content-Type' ] = 'application/json' } )
	if not resBody or resBody == '' then return nil, 'no response from Google Vision' end
	local decoded = json.decode( resBody )
	if not decoded then return nil, 'could not parse Vision response' end
	local resp = decoded.responses and decoded.responses[ 1 ]
	if resp and resp.error and resp.error.message then return nil, 'Vision: ' .. resp.error.message end
	if decoded.error then return nil, 'Vision: ' .. tostring( decoded.error.message or decoded.error ) end
	return decoded
end

function M.identify( opts, deps )
	local decoded, err = M.fetch( opts, deps )
	if not decoded then return {}, err end
	return M.parse( decoded )
end

return M
