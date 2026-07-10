--[[----------------------------------------------------------------------------
SpeciesTaggerHelpItem.lua
Entry point for Help > Plug-in Extras > "Species Tagger quick start…" — a
discoverability net for users hunting in the Help menu. Shows the quick-start
summary and offers to open the wiki guide.
------------------------------------------------------------------------------]]

local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'

local WIKI_URL = 'https://github.com/yuvaloren/lightroom-species-tagger/wiki'

LrTasks.startAsyncTask( function()
	local choice = LrDialogs.confirm(
		'Species Tagger — quick start',
		table.concat( {
			'1.  Select photos in the Library.',
			'2.  Run  Library ▸ Plug-in Extras ▸ Identify and Tag Species',
			'     (also under  File ▸ Plug-in Extras  in any module).',
			'3.  A Chrome window opens with Google Lens results — HIGHLIGHT the',
			'     species name (Latin or common) and press “Tag”. “Skip” leaves a',
			'     photo untouched.',
			'',
			'Keywords (common + Latin, optionally the full taxonomy) are written',
			'to each photo via the GBIF taxonomy service.',
			'',
			'Settings:  File ▸ Plug-in Manager ▸ Species Tagger.',
		}, '\n' ),
		'Open the full guide', 'Close' )
	if choice == 'ok' then
		LrHttp.openUrlInBrowser( WIKI_URL )
	end
end )
