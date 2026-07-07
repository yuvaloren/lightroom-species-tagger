--[[----------------------------------------------------------------------------
spec/support/fixtures.lua
Loads files from spec/fixtures/, resolving the directory relative to THIS file so
it works no matter the current working directory.
------------------------------------------------------------------------------]]

local json = require 'dkjson'

local M = {}

local here = ( debug.getinfo( 1, 'S' ).source:match( '^@(.*/)' ) ) or './'
M.DIR = here .. '../fixtures'

function M.readFile( abspath )
	local f = io.open( abspath, 'rb' )
	if not f then return nil end
	local s = f:read( '*a' )
	f:close()
	return s
end

-- read a file under spec/fixtures/ ; returns its raw string or nil
function M.read( relpath )
	return M.readFile( M.DIR .. '/' .. relpath )
end

-- read + JSON-decode a file under spec/fixtures/
function M.loadJson( relpath )
	local s = M.read( relpath )
	if not s then return nil, 'fixture not found: ' .. relpath end
	local d, _, err = json.decode( s )
	if not d then return nil, 'bad json in ' .. relpath .. ': ' .. tostring( err ) end
	return d
end


return M
