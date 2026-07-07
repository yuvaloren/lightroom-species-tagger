--[[----------------------------------------------------------------------------
SpeciesTaggerInfoProvider.lua
The settings panel shown in Plug-in Manager. Binds the Config pref keys to simple
controls. Defaults are seeded from Config.DEFAULTS on first open.
------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'

local Config = require 'Config'

local M = {}

function M.sectionsForTopOfDialog( f, _ )
	local prefs = LrPrefs.prefsForPlugin()
	for k, v in pairs( Config.DEFAULTS ) do
		if prefs[ k ] == nil then prefs[ k ] = v end
	end

	-- Full version label (stamped into Version.lua at build time). Lightroom's own
	-- version field is numeric (shows e.g. 0.1.0.0), so we surface the real label here.
	local okVer, version = pcall( require, 'Version' )
	version = ( okVer and type( version ) == 'string' ) and version or 'dev'

	-- Bind every control directly to the plugin's stored prefs (LrPrefs). Without an
	-- explicit bind_to_object, LrView binds to a transient per-dialog table that is NOT
	-- seeded and NOT persisted — which is why the dropdowns opened empty, the checkbox
	-- showed the indeterminate "–" state, and the keep-open setting never took effect.
	local function bind( spec )
		if type( spec ) == 'string' then spec = { key = spec } end
		spec.bind_to_object = spec.bind_to_object or prefs
		return LrView.bind( spec )
	end
	local labelW = LrView.share 'st_label_width'

	return {
		{
			title = 'Recognition (Google Lens)',
			f:static_text {
				title = 'Free — no API key. Opens your installed Google Chrome to run a Lens image search, ' ..
					'then resolves names through GBIF. Needs Node.js + Chrome. See docs/PRIVACY.md.',
				wrap = true, width = 540, height_in_lines = 2,
			},
			f:row {
				f:checkbox {
					title = 'Keep the browser open (a tab per photo) to refine a search and re-parse it',
					value = bind 'lensKeepOpen',
				},
			},
		},
		{
			title = 'Tagging',
			f:row {
				f:static_text { title = 'Keywords:', width = labelW, alignment = 'right' },
				f:popup_menu {
					value = bind 'keywordMode',
					items = {
						{ title = 'Common + Latin (flat)', value = 'flat' },
						{ title = 'Full taxonomy hierarchy', value = 'hierarchy' },
						{ title = 'Both flat + hierarchy', value = 'both' },
					},
				},
			},
			f:row {
				f:static_text { title = 'Auto-tag confidence:', width = labelW, alignment = 'right' },
				f:slider { value = bind 'autoApplyThreshold', min = 0.30, max = 0.95, width = 200 },
				f:static_text {
					width_in_chars = 5,
					title = bind { key = 'autoApplyThreshold',
						transform = function( v ) return string.format( '%.2f', v or 0 ) end },
				},
			},
			f:static_text {
				title = 'Minimum confidence (0–1) to auto-apply keywords; below it the photo just gets the ' ..
					'needs-review tag. Higher = fewer wrong tags, more photos left for review.',
				wrap = true, width = 540, height_in_lines = 2,
			},
			f:row {
				f:static_text { title = 'Needs-review tag:', width = labelW, alignment = 'right' },
				f:edit_field { value = bind 'needsReviewKeyword', width_in_chars = 28 },
			},
			f:row {
				f:checkbox { title = 'Include applied keywords on export', value = bind 'includeOnExport' },
			},
			f:row {
				f:checkbox {
					title = 'Ask for search hints (location + other keywords) at the start of each run',
					value = bind 'promptHints',
				},
			},
			f:row {
				f:checkbox {
					title = 'Location-assisted retry: re-try a photo left for review as “identify picture using location: …”',
					value = bind 'locationAssistRetry',
				},
			},
			f:static_text {
				title = 'Photos are identified without location first; only those left for review are ' ..
					'retried with it (your hint or the photo’s IPTC place) to disambiguate lookalikes.',
				wrap = true, width = 540, height_in_lines = 2,
			},
			f:row {
				f:static_text { title = 'Version: ' .. version },
			},
		},
	}
end

return M
