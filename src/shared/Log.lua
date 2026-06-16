--[[----------------------------------------------------------------------------
Log.lua
A thin logging shim. Inside Lightroom it wraps LrLogger; headless (tests, the
offline accuracy script) it degrades to a no-op so the same modules load
unchanged. Also exposes redact() for keeping API keys/tokens out of logs.
------------------------------------------------------------------------------]]

local M = {}

-- Replace anything that looks like a secret with a placeholder. Best-effort:
-- Google API keys (AIza...), and explicit key= / api_key= / api-key= URL params
-- (Pl@ntNet uses the hyphenated `api-key=`; Vision uses `key=`).
function M.redact( s )
	if type( s ) ~= 'string' then return s end
	s = s:gsub( '(api[%-_]key=)[%w%-_]+', '%1<key>' )
	s = s:gsub( '([?&]key=)[%w%-_]+', '%1<key>' )
	s = s:gsub( 'AIza[%w%-_]+', '<google-key>' )
	return s
end

local function noop() end

local function makeNoop()
	return { enable = noop, trace = noop, info = noop, warn = noop, error = noop }
end

-- Log.new('SpeciesTagger') -> a logger with :info/:warn/:error/:trace.
function M.new( name )
	-- rawget so this never errors when `import` isn't defined (pure test runs).
	local imp = rawget( _G, 'import' )
	if not imp then return makeNoop() end
	local ok, LrLogger = pcall( imp, 'LrLogger' )
	if not ok or not LrLogger then return makeNoop() end
	local logger = LrLogger( name or 'SpeciesTagger' )
	logger:enable( 'logfile' ) -- written to the Lightroom Documents/ logs folder
	return logger
end

return M
