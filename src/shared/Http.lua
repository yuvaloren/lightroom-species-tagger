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

-- A transport that shells out to `curl` via LrTasks.execute, for endpoints that
-- need a real browser SESSION (Google Lens) which LrHttp cannot drive: LrHttp
-- auto-follows the upload→results redirect and drops the session cookie across
-- it, so the upload is never "associated" with the results request. curl, with a
-- cookie jar (-b/-c) carried across -L, keeps the session intact.
--
-- opts.cookie : the user's Google "Cookie" header value (pasted from a browser
--               where Lens works; stored in plugin prefs). It is sent via -b so
--               curl's cookie engine forwards it (and any Set-Cookie) across the
--               redirect. Returns (body, nil) — only the body is used downstream.
-- macOS/Linux only for now (POSIX sh quoting); Windows curl needs different quoting.
function M.curlAdapter( opts )
	local LrTasks = import 'LrTasks'
	local LrPathUtils = import 'LrPathUtils'
	local LrFileUtils = import 'LrFileUtils'
	local cookie = opts and opts.cookie
	local curl = '/usr/bin/curl'
	local seq = 0

	local function sh( s ) return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'" end
	local function tmp( tag )
		seq = seq + 1
		return LrPathUtils.child( LrPathUtils.getStandardFilePath( 'temp' ),
			string.format( 'speciestagger-%s-%d-%d.tmp', tag, os.time(), seq ) )
	end
	local function readFile( p )
		local f = io.open( p, 'rb' ); if not f then return nil end
		local b = f:read( '*a' ); f:close(); return b
	end

	-- run curl with the given argument string; capture stdout from a temp file.
	local function exec( argstr )
		local out, jar = tmp( 'out' ), tmp( 'jar' )
		local cmd = curl .. ' -sS --compressed -L --max-time 30 -c ' .. sh( jar )
		if cookie and cookie ~= '' then cmd = cmd .. ' -b ' .. sh( cookie ) end
		cmd = cmd .. argstr .. ' -o ' .. sh( out ) .. ' 2>/dev/null'
		LrTasks.execute( cmd )
		local body = readFile( out )
		LrFileUtils.delete( out ); LrFileUtils.delete( jar )
		return body
	end

	local function headerArgs( headers )
		local a = ''
		for k, v in pairs( headers or {} ) do a = a .. ' -H ' .. sh( k .. ': ' .. v ) end
		return a
	end

	return {
		get = function( url, headers )
			return exec( headerArgs( headers ) .. ' ' .. sh( url ) )
		end,
		post = function( url, body, headers )
			local bf = tmp( 'post' ); local f = io.open( bf, 'wb' ); f:write( body or '' ); f:close()
			local r = exec( headerArgs( headers ) .. ' --data-binary @' .. sh( bf ) .. ' ' .. sh( url ) )
			LrFileUtils.delete( bf ); return r
		end,
		postMultipart = function( url, parts, headers )
			local a = headerArgs( headers )
			for _, p in ipairs( parts ) do
				if p.filePath then
					a = a .. ' -F ' .. sh( p.name .. '=@' .. p.filePath ..
						( p.contentType and ( ';type=' .. p.contentType ) or '' ) )
				else
					a = a .. ' -F ' .. sh( p.name .. '=' .. p.value )
				end
			end
			return exec( a .. ' ' .. sh( url ) )
		end,
	}
end

return M
