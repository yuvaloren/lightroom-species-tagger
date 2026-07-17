--[[----------------------------------------------------------------------------
SpeciesTaggerInfoProvider.lua
The settings panel shown in Plug-in Manager. Binds the Config pref keys to simple
controls. Defaults are seeded from Config.DEFAULTS on first open.
------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local Config = require 'Config'
local Uninstall = require 'Uninstall'

local M = {}

-- Uninstall lives HERE because this is where users look: Lightroom's own
-- Remove button sits right in this dialog but is permanently greyed out for
-- auto-load (Modules folder) installs. Manual installs keep using Remove, so
-- for them this section only explains that.
local function uninstallSection( f )
	if Uninstall.isModulesInstall() then
		local how
		if WIN_ENV then
			how = f:static_text {
				title = 'Use Windows Settings ▸ Apps ▸ Species Tagger for Lightroom Classic. ' ..
					'(Lightroom’s own Remove button doesn’t apply to installer-based plug-ins.)',
				wrap = true, width = 540, height_in_lines = 2,
			}
		else
			how = f:row {
				f:push_button {
					title = 'Uninstall Species Tagger…',
					action = function()
						LrTasks.startAsyncTask( function() Uninstall.run() end )
					end,
				},
				f:static_text {
					title = 'Moves the plug-in to the Trash. Photos and keywords are not touched.',
				},
			}
		end
		return { title = 'Uninstall', how }
	end
	return {
		title = 'Uninstall',
		f:static_text {
			title = 'This copy was added manually: select it in the list on the left and use ' ..
				'Lightroom’s Remove button, then delete the SpeciesTagger.lrplugin folder.',
			wrap = true, width = 540, height_in_lines = 2,
		},
	}
end

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
					'See the Privacy page on the project wiki.',
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
		{
			title = 'Burst detection',
			f:row {
				f:checkbox {
					title = 'Group burst photos automatically (one identification tags the whole burst)',
					value = bind 'burstDetect',
				},
			},
			f:row {
				f:static_text { title = 'Max seconds between frames:', width = labelW, alignment = 'right' },
				f:edit_field {
					value = bind 'burstGapSeconds',
					width_in_chars = 3, min = 1, max = 10, precision = 0,
					enabled = bind 'burstDetect',
				},
			},
			f:static_text {
				title = 'Frames group only when they are close in time AND look nearly identical — ' ..
					'a different subject one second later stays separate. Tag or Skip always acts ' ..
					'on the whole group; one Undo restores it.',
				wrap = true, width = 540, height_in_lines = 2,
			},
		},
		uninstallSection( f ),
	}
end

return M
