--[[----------------------------------------------------------------------------
SpeciesTaggerHelpItem.lua
Entry point for Help > Plug-in Extras > "Species Tagger quick start…" — a
discoverability net for users hunting in the Help menu. Shows the quick-start
summary, offers to open the wiki guide, and — for installer-based (Modules
auto-load folder) installs on macOS — offers uninstall, since a folder in
~/Library is not something end users discover on their own. Windows installs
have a real uninstaller (Settings > Apps), so we point there instead.
------------------------------------------------------------------------------]]

local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'

local Uninstall = require 'Uninstall'

local WIKI_URL = 'https://github.com/yuvaloren/lightroom-species-tagger/wiki'

LrTasks.startAsyncTask( function()
	local lines = {
		'1.  Select photos in the Library.',
		'2.  Run  File ▸ Plug-in Extras ▸ Identify and Tag Species.',
		'3.  A Chrome window opens with Google Lens results — HIGHLIGHT the',
		'     species name (Latin or common) and press “Tag”. “Skip” leaves a',
		'     photo untouched.',
		'',
		'Keywords (common + Latin, optionally the full taxonomy) are written',
		'to each photo via the GBIF taxonomy service.',
		'',
		'Settings:  File ▸ Plug-in Manager ▸ Species Tagger.',
	}
	if Uninstall.isModulesInstall() then
		if WIN_ENV then
			lines[ #lines + 1 ] = 'Uninstall:  Windows Settings ▸ Apps ▸ Species Tagger.'
		else
			lines[ #lines + 1 ] = 'Uninstall:  File ▸ Plug-in Manager ▸ Species Tagger ▸ Uninstall.'
		end
	end

	local choice = LrDialogs.confirm( 'Species Tagger — quick start',
		table.concat( lines, '\n' ), 'Open the full guide', 'Close' )
	if choice == 'ok' then
		LrHttp.openUrlInBrowser( WIKI_URL )
	end
end )
