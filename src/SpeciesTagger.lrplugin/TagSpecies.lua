--[[----------------------------------------------------------------------------
TagSpecies.lua
The action, run inside Lightroom. Assistive Google Lens workflow. It opens ONE Chrome
window and, for each selected photo:
  1. renders a downsized JPEG (requestJpegThumbnail — also strips original EXIF/GPS),
  2. shows Google Lens's real results in the window (a fresh tab per photo, an "m of n"
     counter in a bottom bar),
  3. the user reads the results and HIGHLIGHTS the species' name, then presses the on-page
     "Tag" button (or "Skip"),
  4. resolves the highlighted name through GBIF and writes the common + Latin keywords
     (per settings). Skipped / unresolved photos are simply left untouched.

The plugin never reads or scrapes Google's results — it uses only the text the user
highlighted (see scripts/lens/lens-search.js and src/shared/SelectedName.lua). The window
is reused across photos and closed cleanly at the end. This is the only file that talks to
the Lightroom catalog; the decision logic lives in the pure, unit-tested shared modules.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrProgressScope = import 'LrProgressScope'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local Config = require 'Config'
local SelectedName = require 'SelectedName'
local KeywordApply = require 'KeywordApply'
local Http = require 'Http'
local Log = require 'Log'

local M = {}
local log = Log.new( 'SpeciesTagger' )

-- Remote-debug port for the reused assist window (its own, distinct from any other Chrome).
local ASSIST_PORT = 9334

--------------------------------------------------------------------------------
-- helpers

local tmpCounter = 0

local function fileName( photo )
	local ok, name = pcall( function() return photo:getFormattedMetadata( 'fileName' ) end )
	return ok and name or '(photo)'
end

-- Render a downsized JPEG of the photo into memory. requestJpegThumbnail is async; we
-- wait (cooperatively) for its callback.
local function jpegBytes( photo, maxEdge )
	local data, errMsg, done
	photo:requestJpegThumbnail( maxEdge, maxEdge, function( jpeg, err )
		if jpeg then data = jpeg else errMsg = err end
		done = true
	end )
	local waited = 0
	while not done and waited < 200 do -- up to ~20s
		LrTasks.sleep( 0.1 )
		waited = waited + 1
	end
	if not data then return nil, errMsg or 'could not render a preview JPEG' end
	return data
end

local function writeTempJpeg( bytes )
	tmpCounter = tmpCounter + 1
	local name = string.format( 'speciestagger-%d-%d.jpg', os.time(), tmpCounter )
	local path = LrPathUtils.child( LrPathUtils.getStandardFilePath( 'temp' ), name )
	local fh, err = io.open( path, 'wb' )
	if not fh then return nil, err end
	fh:write( bytes )
	fh:close()
	return path
end

--------------------------------------------------------------------------------
-- first-run welcome

local function firstRunWelcome()
	LrDialogs.message( 'Species Tagger — Welcome', table.concat( {
		'WHERE TO FIND IT:  select photos in the Library, then ' ..
			'Library ▸ Plug-in Extras ▸ Identify and Tag Species.',
		'',
		'Species Tagger helps you tag the plants and animals in your photos with both the ' ..
			'common and the Latin (scientific) name.',
		'',
		'How it works: it opens Google Lens in a Chrome window showing Google’s real results. ' ..
			'You read them (refine in Google’s own search box if you like), then HIGHLIGHT the ' ..
			'species’ Latin name and press the “Tag” button in the bar at the bottom. The plugin ' ..
			'resolves your pick through the GBIF taxonomy and writes the keywords to that photo. ' ..
			'Press “Skip” to leave a photo untagged.',
		'',
		'You stay in control — the plugin uses only the name you highlight; it does not read ' ..
			'Google’s results for you.',
		'',
		'Settings live in  File ▸ Plug-in Manager ▸ Species Tagger  (keyword style, export). ' ..
			'Recognition needs only Google Chrome installed.',
	}, '\n' ), 'info' )
end

--------------------------------------------------------------------------------
-- main

function M.run( _ )
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()
	if not photos or #photos == 0 then
		LrDialogs.message( 'Species Tagger', 'Select one or more photos first.', 'info' )
		return
	end

	local prefs = LrPrefs.prefsForPlugin()
	local cfg = Config.load( prefs )

	if not prefs.firstRunDone then
		firstRunWelcome()
		prefs.firstRunDone = true
	end

	local assist = Http.lensAssistAdapter {
		helperPath = LrPathUtils.child( _PLUGIN.path, 'lens/lens-search.js' ),
		pluginPath = _PLUGIN.path,
		tabsPort = ASSIST_PORT,
	}
	local resolveDeps = { http = Http.lrAdapter(), cache = {} } -- shared GBIF cache for the run
	local keyCfg = { keywordMode = cfg.keywordMode }

	LrDialogs.showBezel( 'A Chrome window opens showing Google’s results — highlight the species and press Tag.' )

	local progress = LrProgressScope { title = 'Tag species with Lens…' }
	progress:setCancelable( true )

	local nApplied, nSkipped = 0, 0
	local lines = {}

	for i, photo in ipairs( photos ) do
		if progress:isCanceled() then break end
		progress:setPortionComplete( i - 1, #photos )
		progress:setCaption( fileName( photo ) )

		local bytes, err = jpegBytes( photo, cfg.maxEdge )
		if not bytes then
			nSkipped = nSkipped + 1
			lines[ #lines + 1 ] = '✗ ' .. fileName( photo ) .. ' — ' .. tostring( err )
			log:warn( 'render failed: ' .. Log.redact( tostring( err ) ) )
		else
			local file, werr = writeTempJpeg( bytes )
			if not file then
				nSkipped = nSkipped + 1
				lines[ #lines + 1 ] = '✗ ' .. fileName( photo ) .. ' — temp file: ' .. tostring( werr )
			else
				local pos = string.format( 'Photo %d of %d', i, #photos )
				-- opens/reuses the window; blocks until the user Tags a selection (or Skips / times out)
				local name, aerr = assist.tag( file, pos )
				LrFileUtils.delete( file )

				if not name then
					-- Skipped, timed out, or a helper error: leave the photo untouched.
					nSkipped = nSkipped + 1
					local why = ( aerr == Http.LENS_CANCELLED ) and 'skipped'
						or ( 'not tagged (' .. tostring( aerr ) .. ')' )
					lines[ #lines + 1 ] = '⊘ ' .. fileName( photo ) .. ' — ' .. why
					if aerr ~= Http.LENS_CANCELLED then log:warn( 'assist: ' .. Log.redact( tostring( aerr ) ) ) end
				else
					local res = SelectedName.resolve( name, resolveDeps, keyCfg )
					if res.ok then
						catalog:withWriteAccessDo( 'Tag species', function()
							KeywordApply.apply( catalog, photo, res.plan, cfg )
						end, { timeout = 30 } )
						nApplied = nApplied + 1
						lines[ #lines + 1 ] = string.format( '✓ %s — %s (%s)', fileName( photo ),
							res.taxon.commonName or res.taxon.scientificName, res.taxon.scientificName )
					else
						nSkipped = nSkipped + 1
						lines[ #lines + 1 ] = '⊘ ' .. fileName( photo ) ..
							' — “' .. tostring( name ) .. '” not found in GBIF'
					end
				end
			end
		end
	end

	assist.close() -- shut the reused window down cleanly (no "didn't shut down correctly" prompt)
	progress:done()

	local bezel = string.format( 'Species Tagger: tagged %d%s',
		nApplied, nSkipped > 0 and ( ', skipped ' .. nSkipped ) or '' )
	log:info( 'assist run complete — ' .. bezel .. '\n' .. table.concat( lines, '\n' ) )
	LrDialogs.showBezel( bezel, 4 )
end

return M
