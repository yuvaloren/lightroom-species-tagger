--[[----------------------------------------------------------------------------
ReparseMenuItem.lua
Entry point for Library > Plug-in Extras > "Re-parse Open Lens Tab & Re-tag".
Runs on an async task inside a function context, then hands off to ReparseLens.run —
re-scrapes the kept-open Lens tab you refined and re-tags the selected photo.
------------------------------------------------------------------------------]]

local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

LrTasks.startAsyncTask( function()
	LrFunctionContext.callWithContext( 'speciesTagger.reparse', function( context )
		local ok, err = LrTasks.pcall( function()
			local ReparseLens = require 'ReparseLens'
			ReparseLens.run( context )
		end )
		if not ok then
			LrDialogs.message( 'Species Tagger — Re-parse', 'Something went wrong:\n\n' .. tostring( err ), 'critical' )
		end
	end )
end )
