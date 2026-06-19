--[[----------------------------------------------------------------------------
Config.lua
Single source of truth for plugin settings: the pref keys, their defaults, and a
loader that overlays stored prefs on those defaults. Used by both the settings
dialog (SpeciesTaggerInfoProvider) and the action (TagSpecies), and unit-tested
so the defaults can't silently drift. Pure (takes a prefs-like table).
------------------------------------------------------------------------------]]

local M = {}

M.DEFAULTS = {
	-- 'lens' (Google Lens, direct & keyless) | 'vision' (Google Vision) | 'plantnet'
	backend = 'lens',

	visionApiKey = '',
	plantNetKey = '',
	plantNetProject = 'all', -- Pl@ntNet flora project ('all' = worldwide)

	-- Google Lens backend shells out to the bundled Node + Chrome helper. GUI apps
	-- get a minimal PATH, so set this if `node` isn't auto-found (e.g.
	-- /opt/homebrew/bin/node). Leave blank to auto-detect.
	nodePath = '',

	-- Lens: keep the Chrome window open after each photo (a new tab per photo) so you
	-- can do follow-ups (e.g. ask Google's AI more). Off = a popup that closes per photo.
	lensKeepOpen = false,

	-- Keywording
	keywordMode = 'flat', -- 'flat' | 'hierarchy' | 'both'  (flat = just the common + Latin name)
	rootKeyword = '',     -- optional parent for the hierarchy (e.g. 'Wildlife')
	flatRoot = '',        -- optional parent for the flat keywords
	includeOnExport = true,
	needsReviewKeyword = 'species: needs review',

	-- Decisioning
	autoApplyThreshold = 0.62,

	-- Image prep
	maxEdge = 1024,
}

-- load( prefs ) -> cfg   (prefs may be nil / partial)
function M.load( prefs )
	local cfg = {}
	for k, v in pairs( M.DEFAULTS ) do
		local pv = prefs and prefs[ k ]
		if pv == nil then cfg[ k ] = v else cfg[ k ] = pv end
	end
	return cfg
end

-- Validate that the chosen backend has the credentials it needs.
-- Returns ok, message.
function M.validate( cfg )
	if cfg.backend == 'lens' then
		-- Lens needs no key (it drives the bundled browser helper); nothing to
		-- validate here. Missing Node/Chrome is reported at run time, per photo.
		return true
	elseif cfg.backend == 'vision' then
		if not cfg.visionApiKey or cfg.visionApiKey == '' then
			return false, 'Add your Google Vision API key in the plugin settings.'
		end
	elseif cfg.backend == 'plantnet' then
		if not cfg.plantNetKey or cfg.plantNetKey == '' then
			return false, 'Add your free Pl@ntNet API key in the plugin settings ' ..
				'(get one at my.plantnet.org).'
		end
	else
		return false, 'Unknown backend: ' .. tostring( cfg.backend )
	end
	return true
end

return M
