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

	-- Lens: keep the Chrome window open after each photo (a new tab per photo) so you
	-- can refine the search and re-parse it (see TagSpecies "re-parse"), or ask
	-- Google's AI more. Off = a popup window that closes after each photo.
	lensKeepOpen = false,

	-- Whether the one-time first-run welcome (points at the settings + how to run) has
	-- been shown. Flipped to true the first time the action runs; see TagSpecies.
	firstRunDone = false,

	-- Ask for two optional hints at the start of each run: a LOCATION (where the photo
	-- was taken) and OTHER identifying keywords. last* remember the entries to prefill.
	promptHints = true,
	lastLocationHint = '',
	lastOtherKeywords = '',

	-- Location is decisive for visually ambiguous subjects (e.g. elephant seals) but
	-- hurts easy, web-matchable photos, so it is NOT sent on the first pass. When a
	-- photo comes back for review, retry ONCE with a location-assisted search
	-- ("identify picture using location: <place>") using the location hint or the photo's IPTC
	-- place. See docs/CORPUS.md and the LensQuery 'identify-location' strategy.
	locationAssistRetry = true,

	-- Keywording
	keywordMode = 'flat', -- 'flat' | 'hierarchy' | 'both'  (flat = just the common + Latin name)
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
	-- Back-compat: carry the old single-field prefs onto the new two-field ones so an
	-- existing install keeps its remembered entry + toggle after the split.
	if prefs then
		if prefs.promptHints == nil and prefs.promptExtraKeywords ~= nil then
			cfg.promptHints = prefs.promptExtraKeywords
		end
		if ( not prefs.lastOtherKeywords or prefs.lastOtherKeywords == '' ) and prefs.lastExtraKeywords then
			cfg.lastOtherKeywords = prefs.lastExtraKeywords
		end
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
