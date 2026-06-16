--[[----------------------------------------------------------------------------
Http.lua
An adapter that turns Lightroom's LrHttp into the small, injectable `http`
interface the providers and the taxonomy resolver expect:

  http.get( url [, headers] )                 -> body|nil, resHeaders
  http.post( url, body [, headers] )          -> body|nil, resHeaders
  http.postMultipart( url, parts [, headers]) -> body|nil, resHeaders

`headers` is a plain { ['Header-Name'] = 'value' } map (converted to LrHttp's
array-of-{field,value} form here). `parts` is LrHttp.postMultipart's content
array. The pure modules never import this directly — the Lightroom glue builds
one of these and passes it in as a dependency, while tests pass a fake.
------------------------------------------------------------------------------]]

local M = {}

local function toLrHeaders( headers )
	if not headers then return nil end
	local arr = {}
	for k, v in pairs( headers ) do
		arr[ #arr + 1 ] = { field = k, value = v }
	end
	return arr
end

-- Build an adapter backed by the real LrHttp. Only callable inside Lightroom.
function M.lrAdapter()
	local LrHttp = import 'LrHttp'
	local TIMEOUT = 30
	return {
		get = function( url, headers )
			return LrHttp.get( url, toLrHeaders( headers ), TIMEOUT )
		end,
		post = function( url, body, headers )
			local h = toLrHeaders( headers ) or {}
			return LrHttp.post( url, body, h, 'POST', TIMEOUT )
		end,
		postMultipart = function( url, parts, headers )
			return LrHttp.postMultipart( url, parts, toLrHeaders( headers ), TIMEOUT )
		end,
	}
end

return M
