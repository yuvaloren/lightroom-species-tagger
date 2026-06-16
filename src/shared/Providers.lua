--[[----------------------------------------------------------------------------
Providers.lua
Registry + common contract for the recognition backends. A provider is a module
exposing:

  id            : short string ('lens', 'vision', 'plantnet')
  label         : human label for the settings popup
  needsImageFile: true if fetch() uploads the image as an LrHttp multipart file
                  (Lens, Pl@ntNet) vs. sending bytes inline in a JSON body (Vision)
  parse(decoded)        -> observations[]            (PURE — unit tested)
  identify(opts, deps)  -> observations[], errString  (fetch + parse)

Keeping providers behind one seam is what lets the parser/scorer/test layers stay
identical no matter which backend produced the observations.
------------------------------------------------------------------------------]]

local M = { _byId = {}, _order = {} }

function M.register( mod )
	assert( mod and mod.id, 'provider needs an id' )
	if not M._byId[ mod.id ] then M._order[ #M._order + 1 ] = mod.id end
	M._byId[ mod.id ] = mod
	return mod
end

function M.get( id ) return M._byId[ id ] end

function M.all()
	local out = {}
	for _, id in ipairs( M._order ) do out[ #out + 1 ] = M._byId[ id ] end
	return out
end

function M.ids()
	local out = {}
	for _, id in ipairs( M._order ) do out[ #out + 1 ] = id end
	return out
end

-- Register the built-ins (these modules do not require Providers, so no cycle).
-- Order here is the order shown in the settings popup; 'lens' is the default.
M.register( require 'ProviderGoogleLens' )
M.register( require 'ProviderGoogleVision' )
M.register( require 'ProviderPlantNet' )

return M
