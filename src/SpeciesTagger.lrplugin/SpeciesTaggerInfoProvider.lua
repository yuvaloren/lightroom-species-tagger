--[[----------------------------------------------------------------------------
SpeciesTaggerInfoProvider.lua
The settings panel shown in Plug-in Manager. Binds the Config pref keys to simple
controls. Defaults are seeded from Config.DEFAULTS on first open.
------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'

local Config = require 'Config'
local Providers = require 'Providers'

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

	local backendItems = {}
	for _, p in ipairs( Providers.all() ) do
		backendItems[ #backendItems + 1 ] = { title = p.label, value = p.id }
	end

	return {
		{
			title = 'Recognition backend',
			f:row {
				f:static_text { title = 'Backend:', width = labelW, alignment = 'right' },
				f:popup_menu { value = bind 'backend', items = backendItems },
			},
			f:static_text {
				title = 'Google Lens needs no key — the plugin opens your installed Google Chrome ' ..
					'(in a visible window, so you see Google’s real page) to run a Lens image search. ' ..
					'It needs Node.js + Google Chrome on this machine (macOS/Linux). Pl@ntNet (plants ' ..
					'only) and Google Vision are alternative backends that use their own key below. ' ..
					'See docs/PRIVACY.md for what leaves your machine.',
				wrap = true, width = 540, height_in_lines = 3,
			},
			f:row {
				f:checkbox {
					title = 'Keep the browser open (a new tab per photo) for follow-ups, e.g. asking Google’s AI',
					value = bind 'lensKeepOpen',
				},
			},
			f:row {
				f:static_text { title = 'node path:', width = labelW, alignment = 'right' },
				f:edit_field { value = bind 'nodePath', width_in_chars = 40 },
				f:static_text { title = '(Lens; blank = auto)' },
			},
			f:row {
				f:static_text { title = 'Pl@ntNet key:', width = labelW, alignment = 'right' },
				f:password_field { value = bind 'plantNetKey', width_in_chars = 40 },
				f:static_text { title = '(free at my.plantnet.org)' },
			},
			f:row {
				f:static_text { title = 'Google Vision key:', width = labelW, alignment = 'right' },
				f:password_field { value = bind 'visionApiKey', width_in_chars = 40 },
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
				f:static_text { title = 'Hierarchy root:', width = labelW, alignment = 'right' },
				f:edit_field { value = bind 'rootKeyword', width_in_chars = 20 },
				f:static_text { title = '(optional parent, e.g. Wildlife)' },
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
				title = 'How confident the identification must be (0–1) before keywords are applied ' ..
					'automatically. Below this, the photo is only flagged with the needs-review tag ' ..
					'instead of tagged. Higher = fewer wrong tags, but more photos left for review.',
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
				f:static_text { title = 'Version: ' .. version },
			},
		},
	}
end

return M
