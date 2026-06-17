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

	local bind = LrView.bind
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
				title = 'Google Lens needs no key: the plugin shells out to curl and generates its own ' ..
					'Google session (like a fresh incognito window), so just pick it. Pl@ntNet (plants) ' ..
					'and Google Vision use their own key below. (Lens is macOS/Linux; needs curl on PATH.) ' ..
					'See docs/PRIVACY.md for what leaves your machine.',
				wrap = true, width = 540, height_in_lines = 3,
			},
			f:row {
				f:static_text { title = 'Lens cookie:', width = labelW, alignment = 'right' },
				f:password_field { value = bind 'lensCookie', width_in_chars = 40 },
				f:static_text { title = '(optional fallback)' },
			},
			f:static_text {
				title = 'Leave the Lens cookie blank to use a self-generated session. Only if your ' ..
					'network refuses it: in a browser where lens.google.com works, open DevTools → ' ..
					'Network, do a Lens image search, click the "upload" request, and paste its Cookie ' ..
					'header value here.',
				wrap = true, width = 540, height_in_lines = 3,
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
			f:row {
				f:static_text { title = 'Lens locale:', width = labelW, alignment = 'right' },
				f:edit_field { value = bind 'lensHl', width_in_chars = 4 },
				f:static_text { title = '/' },
				f:edit_field { value = bind 'lensCountry', width_in_chars = 4 },
				f:static_text { title = '(language / country)' },
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
				f:static_text { title = 'Auto-apply at:', width = labelW, alignment = 'right' },
				f:slider { value = bind 'autoApplyThreshold', min = 0.30, max = 0.95, width = 200 },
				f:static_text {
					width_in_chars = 5,
					title = bind { key = 'autoApplyThreshold',
						transform = function( v ) return string.format( '%.2f', v or 0 ) end },
				},
			},
			f:row {
				f:static_text { title = 'Needs-review tag:', width = labelW, alignment = 'right' },
				f:edit_field { value = bind 'needsReviewKeyword', width_in_chars = 28 },
			},
			f:row {
				f:checkbox { title = 'Include applied keywords on export', value = bind 'includeOnExport' },
			},
		},
	}
end

return M
