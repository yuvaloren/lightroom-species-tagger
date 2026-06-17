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
-- it, so the upload is never "associated" with the results request. curl keeps a
-- persistent cookie jar (-b/-c) across -L and across calls, so the session holds.
--
-- The session is SELF-GENERATED: the adapter pre-seeds the consent cookie and
-- warms up the jar with a GET to google.com (which returns fresh NID/AEC), exactly
-- like opening Lens in a fresh incognito window — no browser copy-paste needed.
-- opts.cookie is an OPTIONAL override (a Cookie value pasted from a browser) for
-- the rare case where a self-generated session is refused; it augments the jar.
-- macOS/Linux only for now (POSIX sh quoting); Windows curl needs different quoting.
function M.curlAdapter( opts )
	local LrTasks = import 'LrTasks'
	local LrPathUtils = import 'LrPathUtils'
	local LrFileUtils = import 'LrFileUtils'
	opts = opts or {}
	local cookie = opts.cookie
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

	-- one persistent session jar for this adapter, pre-seeded with a consent cookie
	-- so Google serves results instead of bouncing to consent.google.com.
	local jar = tmp( 'jar' )
	do
		local f = io.open( jar, 'w' )
		if f then
			f:write( '# Netscape HTTP Cookie File\n' )
			f:write( '.google.com\tTRUE\t/\tTRUE\t2147483647\tSOCS\t' ..
				( opts.socs or 'CAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg' ) .. '\n' )
			f:write( '.google.com\tTRUE\t/\tFALSE\t2147483647\tCONSENT\tYES+1\n' )
			f:close()
		end
	end

	-- run curl with the given argument string; capture stdout from a temp file.
	-- The persistent jar is read AND written every call, so cookies the upload
	-- sets are carried into the followed results request.
	local function exec( argstr )
		local out = tmp( 'out' )
		local cmd = curl .. ' -sS --compressed -L --max-time 30 -b ' .. sh( jar ) .. ' -c ' .. sh( jar )
		if cookie and cookie ~= '' then cmd = cmd .. ' -b ' .. sh( cookie ) end
		cmd = cmd .. argstr .. ' -o ' .. sh( out ) .. ' 2>/dev/null'
		LrTasks.execute( cmd )
		local body = readFile( out )
		LrFileUtils.delete( out )
		return body
	end

	-- warm up the session (fetch fresh NID/AEC into the jar) unless disabled
	if opts.bootstrap ~= false then
		exec( ' -H ' .. sh( 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' ..
			'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15' ) ..
			' ' .. sh( 'https://www.google.com/' ) )
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
