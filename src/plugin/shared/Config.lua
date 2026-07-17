--[[----------------------------------------------------------------------------
Config.lua
Single source of truth for plugin settings: the pref keys, their defaults, and a
loader that overlays stored prefs on those defaults. Used by both the settings dialog
(SpeciesTaggerInfoProvider) and the action (TagSpecies), and unit-tested so the defaults
can't silently drift. Pure (takes a prefs-like table).
------------------------------------------------------------------------------]]

local M = {}

M.DEFAULTS = {
	-- Whether the one-time first-run welcome has been shown (flipped true on first run).
	firstRunDone = false,

	-- Keywording.
	keywordMode = 'flat', -- 'flat' (common + Latin) | 'hierarchy' (Kingdom→Species) | 'both'
	includeOnExport = true,

	-- Longest edge (px) of the downsized JPEG uploaded to Lens (also strips original EXIF/GPS).
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

return M
