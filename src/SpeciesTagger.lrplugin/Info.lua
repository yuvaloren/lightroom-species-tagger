--[[----------------------------------------------------------------------------
Info.lua — Lightroom plugin manifest for Species Tagger.

Adds the "Identify and Tag Species" command under BOTH Library > Plug-in Extras
and File > Plug-in Extras (the File menu is visible from every module — plugin
commands may only live in File/Library/Help Plug-in Extras, so we take all the
visibility the SDK offers), a "quick start" under Help > Plug-in Extras, and a
settings panel in the Plug-in Manager. The VERSION table is stamped by
build/build.lua at build time (do not hand-edit the numbers).
------------------------------------------------------------------------------]]

return {
	LrSdkVersion = 12.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = 'org.yoren.lightroom.speciestagger',
	LrPluginName = LOC '$$$/SpeciesTagger/PluginName=Species Tagger',

	LrPluginInfoProvider = 'SpeciesTaggerInfoProvider.lua',

	LrLibraryMenuItems = {
		{
			title = LOC '$$$/SpeciesTagger/Menu=Identify and Tag Species…',
			file = 'SpeciesTaggerMenuItem.lua',
		},
	},

	-- Same command in File > Plug-in Extras: visible from EVERY module and the
	-- first place most users look for plugin commands.
	LrExportMenuItems = {
		{
			title = LOC '$$$/SpeciesTagger/Menu=Identify and Tag Species…',
			file = 'SpeciesTaggerMenuItem.lua',
		},
	},

	LrHelpMenuItems = {
		{
			title = LOC '$$$/SpeciesTagger/HelpMenu=Species Tagger quick start…',
			file = 'SpeciesTaggerHelpItem.lua',
		},
	},

	VERSION = { major = 0, minor = 1, revision = 0, build = 0 },
}
