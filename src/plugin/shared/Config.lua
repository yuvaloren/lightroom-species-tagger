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

	-- Burst detection: cluster near-identical frames shot <= burstGapSeconds
	-- apart (chained) so one Lens identification tags the whole burst. The
	-- similarity threshold is not a setting — it lives in Burst.lua, owned by
	-- the accuracy corpus.
	burstDetect = true,
	burstGapSeconds = 1,
}

-- load( prefs ) -> cfg   (prefs may be nil / partial)
function M.load( prefs )
	local cfg = {}
	for k, v in pairs( M.DEFAULTS ) do
		local pv = prefs and prefs[ k ]
		if pv == nil then cfg[ k ] = v else cfg[ k ] = pv end
	end
	-- The gap field is free-typed in the settings dialog: coerce and clamp to a
	-- sane range so a stray value can't glue a whole shoot into one burst.
	local g = tonumber( cfg.burstGapSeconds ) or M.DEFAULTS.burstGapSeconds
	cfg.burstGapSeconds = math.max( 1, math.min( 10, g ) )
	return cfg
end

return M
