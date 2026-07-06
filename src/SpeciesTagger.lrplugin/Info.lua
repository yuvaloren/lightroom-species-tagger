--[[----------------------------------------------------------------------------
Info.lua — Lightroom plugin manifest for Species Tagger.

Adds a "Identify and Tag Species" command under Library > Plug-in Extras and a
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
		{
			title = LOC '$$$/SpeciesTagger/ReparseMenu=Re-parse Open Lens Tabs & Re-tag…',
			file = 'ReparseMenuItem.lua',
		},
		{
			title = LOC '$$$/SpeciesTagger/DebugMenu=Debug Lens on Selected Photo (headed)…',
			file = 'SpeciesTaggerDebugMenuItem.lua',
		},
	},

	VERSION = { major = 0, minor = 1, revision = 0, build = 0 },
}
