--[[----------------------------------------------------------------------------
Providers.lua
Registry + common contract for the recognition backend(s). A provider is a module
exposing:

  id            : short string (currently just 'lens')
  label         : human label for the settings panel
  needsImageFile: true if identify() needs the image as a file on disk (Lens does
                  — its browser helper takes a file path)
  parse(decoded)        -> observations[]            (PURE — unit tested)
  identify(opts, deps)  -> observations[], errString  (fetch + parse)

Keeping the provider behind one seam is what lets the parser/scorer/test layers
stay identical regardless of the recognition source, and leaves room to add
another backend later without touching the pipeline.
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

-- Register the built-in(s). The provider module does not require Providers, so
-- there's no cycle. Google Lens is the only backend (free, keyless).
M.register( require 'ProviderGoogleLens' )

return M
