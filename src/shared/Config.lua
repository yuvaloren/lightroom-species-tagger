--[[----------------------------------------------------------------------------
Config.lua
Single source of truth for plugin settings: the pref keys, their defaults, and a
loader that overlays stored prefs on those defaults. Used by both the settings
dialog (SpeciesTaggerInfoProvider) and the action (TagSpecies), and unit-tested
so the defaults can't silently drift. Pure (takes a prefs-like table).
------------------------------------------------------------------------------]]

local M = {}

M.DEFAULTS = {
	-- The recognition backend. Currently only Google Lens (direct & keyless); kept
	-- as a setting so another backend can be added without changing the pipeline.
	backend = 'lens',

	-- The Lens backend shells out to the bundled Node + Chrome helper. GUI apps get
	-- a minimal PATH, so set this if `node` isn't auto-found (e.g.
	-- /opt/homebrew/bin/node, or C:\Program Files\nodejs\node.exe). Blank = auto-detect.
	nodePath = '',

	-- Lens: keep the Chrome window open after each photo (a new tab per photo) so you
	-- can refine the search and re-parse it (see TagSpecies "re-parse"), or ask
	-- Google's AI more. Off = a popup window that closes after each photo.
	lensKeepOpen = false,

	-- Whether the one-time first-run welcome (points at the settings + how to run) has
	-- been shown. Flipped to true the first time the action runs; see TagSpecies.
	firstRunDone = false,

	-- Ask for extra keywords to add to the Lens search at the start of each run
	-- (issue: "prompt you for additional keywords"). lastExtraKeywords remembers the
	-- previous entry to prefill the prompt.
	promptExtraKeywords = true,
	lastExtraKeywords = '',

	-- Keywording
	keywordMode = 'flat', -- 'flat' | 'hierarchy' | 'both'  (flat = just the common + Latin name)
	rootKeyword = '',     -- optional parent for the hierarchy (e.g. 'Wildlife')
	flatRoot = '',        -- optional parent for the flat keywords
	includeOnExport = true,
	needsReviewKeyword = 'species: needs review',

	-- Decisioning. This is an operating point on a bounded evidence score (0..1), NOT
	-- a calibrated probability — see docs/SCORING.md and Identify.lua for exactly what
	-- drives it and how to tune it against your own captures.
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

-- Validate that the chosen backend is usable. Returns ok, message.
function M.validate( cfg )
	if cfg.backend == 'lens' then
		-- Lens needs no key (it drives the bundled browser helper); nothing to
		-- validate here. Missing Node/Chrome is reported at run time, per photo.
		return true
	end
	return false, 'Unknown backend: ' .. tostring( cfg.backend )
end

return M
