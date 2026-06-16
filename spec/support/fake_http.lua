--[[----------------------------------------------------------------------------
spec/support/fake_http.lua
A fake `http` adapter that serves recorded GBIF JSON from spec/fixtures/gbif/.
Routes GBIF /species/match, /species/search and /vernacularNames to fixture files
keyed by a slug of the query name; unmapped names get the "GBIF didn't recognise
it" answers (matchType NONE / empty results) — which is exactly how a junk
candidate should behave. This is what makes the accuracy suite deterministic and
offline.
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

-- new( [opts] ) -> http adapter. opts.uploadUrl overrides the multipart return.
function M.new( opts )
	opts = opts or {}
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
		post = function() return nil end,
		postMultipart = function() return opts.uploadUrl or 'https://files.example/fixture.jpg' end,
	}
end

return M
