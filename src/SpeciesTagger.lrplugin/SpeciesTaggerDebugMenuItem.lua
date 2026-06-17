--[[----------------------------------------------------------------------------
SpeciesTaggerDebugMenuItem.lua
Entry point for Library > Plug-in Extras > "Debug Lens on Selected Photo (headed)".
Runs on an async task inside a function context, then hands off to DebugLens.run —
the in-Lightroom version of ./debug-lens.sh for troubleshooting a wrong ID.
------------------------------------------------------------------------------]]

local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

LrTasks.startAsyncTask( function()
	LrFunctionContext.callWithContext( 'speciesTagger.debugLens', function( context )
		local ok, err = LrTasks.pcall( function()
			local DebugLens = require 'DebugLens'
			DebugLens.run( context )
		end )
		if not ok then
			LrDialogs.message( 'Species Tagger — Debug Lens', 'Something went wrong:\n\n' .. tostring( err ), 'critical' )
		end
	end )
end )
