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
local LrFileUtils = import 'LrFileUtils'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'

local WIKI_URL = 'https://github.com/yuvaloren/lightroom-species-tagger/wiki'

-- True when this copy was placed by an installer into Lightroom's auto-load
-- Modules folder (vs. a manual unzip anywhere + Plug-in Manager ▸ Add).
local function isModulesInstall()
	local p = _PLUGIN.path:gsub( '\\', '/' )
	return p:find( '/Adobe/Lightroom/Modules/', 1, true ) ~= nil
end

local function uninstallSelf()
	local go = LrDialogs.confirm(
		'Uninstall Species Tagger?',
		'This moves the plug-in to the Trash. Your photos and their keywords '
			.. 'are not touched. Restart Lightroom Classic to finish.',
		'Move to Trash', 'Cancel' )
	if go ~= 'ok' then return end
	local ok, err = LrFileUtils.moveToTrash( _PLUGIN.path )
	if ok then
		LrDialogs.message( 'Species Tagger uninstalled',
			'The plug-in is in the Trash. It disappears from the menus the '
				.. 'next time you start Lightroom Classic.', 'info' )
	else
		LrDialogs.message( 'Could not uninstall',
			'Moving the plug-in to the Trash failed ('
				.. tostring( err ) .. ').\n\nYou can delete it by hand: '
				.. _PLUGIN.path, 'critical' )
	end
end

LrTasks.startAsyncTask( function()
	local uninstallVerb = nil
	if isModulesInstall() and MAC_ENV then
		uninstallVerb = 'Uninstall…'
	end

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
	if isModulesInstall() and WIN_ENV then
		lines[ #lines + 1 ] = ''
		lines[ #lines + 1 ] = 'To uninstall:  Windows Settings ▸ Apps ▸ Species Tagger.'
	end

	local choice
	if uninstallVerb then
		choice = LrDialogs.confirm( 'Species Tagger — quick start',
			table.concat( lines, '\n' ), 'Open the full guide', 'Close', uninstallVerb )
	else
		choice = LrDialogs.confirm( 'Species Tagger — quick start',
			table.concat( lines, '\n' ), 'Open the full guide', 'Close' )
	end

	if choice == 'ok' then
		LrHttp.openUrlInBrowser( WIKI_URL )
	elseif choice == 'other' then
		uninstallSelf()
	end
end )
