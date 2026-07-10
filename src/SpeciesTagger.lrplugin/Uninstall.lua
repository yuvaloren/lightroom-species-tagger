--[[----------------------------------------------------------------------------
Uninstall.lua
Shared uninstall helpers for installer-based (Lightroom auto-load Modules
folder) copies of the plugin. Used by the Plug-in Manager section (the button
lives there, right where Lightroom's own Remove button sits greyed-out for
Modules installs) and referenced in text by the Help quick start.
------------------------------------------------------------------------------]]

local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'

local M = {}

-- True when this copy was placed by an installer into Lightroom's auto-load
-- Modules folder (vs. a manual unzip anywhere + Plug-in Manager ▸ Add).
function M.isModulesInstall()
	local p = _PLUGIN.path:gsub( '\\', '/' )
	return p:find( '/Adobe/Lightroom/Modules/', 1, true ) ~= nil
end

-- Confirm, move the plugin folder to the Trash, tell the user to restart.
function M.run()
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

return M
