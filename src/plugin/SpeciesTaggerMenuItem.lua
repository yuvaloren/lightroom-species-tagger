--[[----------------------------------------------------------------------------
SpeciesTaggerMenuItem.lua
Entry point for File > Plug-in Extras > "Identify and Tag Species". Runs the
work on an async task inside a function context (so progress + error handling
behave), then hands off to TagSpecies.run.
------------------------------------------------------------------------------]]

local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

LrTasks.startAsyncTask( function()
	LrFunctionContext.callWithContext( 'speciesTagger.run', function( context )
		local ok, err = LrTasks.pcall( function()
			local TagSpecies = require 'TagSpecies'
			TagSpecies.run( context )
		end )
		if not ok then
			LrDialogs.message( 'Species Tagger', 'Something went wrong:\n\n' .. tostring( err ), 'critical' )
		end
	end )
end )
