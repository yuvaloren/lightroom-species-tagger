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
	-- seeded and NOT persisted — which is why the dropdowns opened empty and the
	-- checkboxes showed the indeterminate "–" state.
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
				title = 'Free — no API key. Opens your installed Google Chrome to show Google Lens ' ..
					'results; you highlight the species and press Tag, and the name is resolved through ' ..
					'GBIF. The plugin never reads Google’s results for you. Needs only Google Chrome. ' ..
					'See docs/PRIVACY.md.',
				wrap = true, width = 540, height_in_lines = 3,
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
				f:checkbox { title = 'Include applied keywords on export', value = bind 'includeOnExport' },
			},
			f:row {
				f:static_text { title = 'Version: ' .. version },
			},
		},
	}
end

return M
