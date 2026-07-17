--[[----------------------------------------------------------------------------
test/plugin/support/fake_http.lua
A fake `http` adapter that serves recorded GBIF JSON from test/plugin/fixtures/gbif/.
Routes GBIF /species/match, /species/search and /vernacularNames to fixture files
keyed by a slug of the query name; unmapped names get the "GBIF didn't recognise
it" answers (matchType NONE / empty results) — which is exactly how a junk
candidate should behave. This is what makes the accuracy suite deterministic and
offline. Only `get` is needed: the Lens provider parses recorded helper output
(no http), and GBIF is GET-only.
------------------------------------------------------------------------------]]

local fixtures = require 'support.fixtures'

local M = {}

local function slug( s )
	s = ( s or '' ):lower()
	s = s:gsub( '%%20', ' ' ):gsub( '+', ' ' )
	s = s:gsub( '[^%w]+', '_' ):gsub( '^_+', '' ):gsub( '_+$', '' )
	return s
end
M.slug = slug

local function param( url, key )
	local v = url:match( '[?&]' .. key .. '=([^&]*)' )
	if not v then return nil end
	v = v:gsub( '+', ' ' ):gsub( '%%(%x%x)', function( h )
		return string.char( tonumber( h, 16 ) )
	end )
	return v
end
M.param = param

-- new() -> http adapter serving recorded GBIF JSON over `get`.
function M.new()
	return {
		get = function( url )
			if url:find( '/species/match', 1, true ) then
				return fixtures.read( 'gbif/match_' .. slug( param( url, 'name' ) ) .. '.json' )
					or '{"matchType":"NONE"}'
			elseif url:find( '/vernacularNames', 1, true ) then
				local key = url:match( '/species/(%d+)/vernacularNames' )
				return ( key and fixtures.read( 'gbif/vern_' .. key .. '.json' ) )
					or '{"results":[]}'
			elseif url:find( '/species/search', 1, true ) then
				return fixtures.read( 'gbif/search_' .. slug( param( url, 'q' ) ) .. '.json' )
					or '{"results":[]}'
			end
			return nil
		end,
	}
end

return M
