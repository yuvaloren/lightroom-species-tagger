--[[----------------------------------------------------------------------------
ProviderPlantNet.lua
Pl@ntNet identification API (https://my.plantnet.org/) — a genuinely free,
no-credit-card backend. A free account gives an API key and 500 identifications
per day. It accepts the image bytes directly (multipart upload), so no image
host is involved.

Pl@ntNet is PLANTS ONLY. It is included as a high-precision specialist: when a
photo is a plant/flower/fungus it returns clean scientific + common names with a
confidence score, which feeds the shared parser/GBIF/scorer like any other
provider. For animals it simply returns weak/no results and the photo falls
through to "needs review" — pair it with the Lens backend for broad coverage.

Endpoint: POST https://my-api.plantnet.org/v2/identify/{project}?api-key=KEY
  project: 'all' (worldwide) or a regional flora; we default to 'all'.
  response.results[] = { score, species = { scientificNameWithoutAuthor,
    genus = { scientificNameWithoutAuthor }, family = {...}, commonNames = {…} } }

parse() is pure; fetch()/identify() use the injected deps.http.
------------------------------------------------------------------------------]]

local json = require 'dkjson'

local M = {
	id = 'plantnet',
	label = 'Pl@ntNet (plants, free key)',
	needsImageFile = true, -- multipart file upload
	ENDPOINT = 'https://my-api.plantnet.org/v2/identify',
	MAX_RESULTS = 5, -- only the top few results carry useful signal
}

local function urlencode( s )
	return ( tostring( s ):gsub( '[^%w%-_%.~]', function( c )
		return string.format( '%%%02X', string.byte( c ) )
	end ) )
end

-- buildUrl( opts ) -> request URL. opts: apiKey, project, lang
function M.buildUrl( opts )
	local project = ( opts.project and opts.project ~= '' ) and opts.project or 'all'
	return M.ENDPOINT .. '/' .. urlencode( project ) ..
		'?lang=' .. urlencode( opts.lang or 'en' ) ..
		'&include-related-images=false' ..
		'&api-key=' .. urlencode( opts.apiKey or '' )
end

-- buildParts( opts ) -> LrHttp.postMultipart content array.
-- Pl@ntNet pairs each `images` file with an `organs` hint; 'auto' lets it decide.
function M.buildParts( opts )
	return {
		{ name = 'organs', value = opts.organ or 'auto' },
		{
			name = 'images',
			fileName = opts.fileName or 'image.jpg',
			filePath = opts.imageFile,
			contentType = opts.contentType or 'image/jpeg',
		},
	}
end

-- parse( decoded ) -> observations[]
function M.parse( decoded )
	local obs = {}
	if type( decoded ) ~= 'table' or type( decoded.results ) ~= 'table' then return obs end

	local function add( text, weight, source )
		if text and text ~= '' then
			obs[ #obs + 1 ] = { text = text, kind = 'label', weight = weight, source = source }
		end
	end

	for i, r in ipairs( decoded.results or {} ) do
		if i > M.MAX_RESULTS then break end
		local score = tonumber( r.score ) or 0
		-- Pl@ntNet's score is a real 0..1 probability; map to a 0.6..1.4 weight.
		local weight = 0.6 + math.min( 0.8, score )
		local sp = r.species or {}
		local sci = sp.scientificNameWithoutAuthor or sp.scientificName
		add( sci, weight, 'plantnet:sci' )
		for _, cn in ipairs( sp.commonNames or {} ) do
			add( cn, weight * 0.8, 'plantnet:common' )
		end
	end
	return obs
end

-- fetch( opts, deps ) -> decoded, err   (opts: imageFile, apiKey, project, lang, organ)
function M.fetch( opts, deps )
	if not opts.imageFile then return nil, 'Pl@ntNet needs an image file (opts.imageFile)' end
	if not opts.apiKey or opts.apiKey == '' then return nil, 'Pl@ntNet needs an API key' end
	local body = deps.http.postMultipart( M.buildUrl( opts ), M.buildParts( opts ) )
	if not body or body == '' then return nil, 'no response from Pl@ntNet' end
	local decoded = json.decode( body )
	if not decoded then return nil, 'could not parse Pl@ntNet response' end
	-- Pl@ntNet reports errors as { statusCode, error, message } (e.g. 404 = "no
	-- plant detected", 401 = bad key). Surface the message; an empty result set
	-- is not an error (likely just not a plant).
	if decoded.statusCode and decoded.statusCode >= 400 then
		return nil, 'Pl@ntNet: ' .. tostring( decoded.message or decoded.error or decoded.statusCode )
	end
	return decoded
end

function M.identify( opts, deps )
	local decoded, err = M.fetch( opts, deps )
	if not decoded then return {}, err end
	return M.parse( decoded )
end

return M
