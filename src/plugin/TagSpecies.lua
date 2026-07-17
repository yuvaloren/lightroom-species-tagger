--[[----------------------------------------------------------------------------
TagSpecies.lua
The action, run inside Lightroom. Assistive Google Lens workflow, burst-aware.
The run has three phases:

  1. GATHER  — for every selected photo: render a downsized JPEG
     (requestJpegThumbnail — also strips original EXIF/GPS) and read capture
     time + camera serial from the catalog; then one helper call (hash mode,
     no Chrome) fingerprints all the renders.
  2. CLUSTER — Burst.cluster groups near-identical frames shot within
     cfg.burstGapSeconds of each other (see shared/Burst.lua for the gates).
     With burst detection off, every photo is its own cluster in selection
     order — byte-for-byte the old per-photo behavior.
  3. ASSIST  — for each cluster: show its FIRST frame in Google Lens (a fresh
     tab in one reused visible Chrome window, "Burst m of n — k photos"
     counter), the user HIGHLIGHTS the species name and presses Tag (or
     Skip), and the resolved GBIF keywords are applied to EVERY member in one
     undo step. Skipped / unresolved clusters are left untouched.

The plugin never reads or scrapes Google's results — it uses only the text the
user highlighted (see src/helper/ and src/plugin/shared/SelectedName.lua). This
is the only file that talks to the Lightroom catalog; the decision logic lives
in the pure, unit-tested shared modules.
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
local Burst = require 'Burst'
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

local function tempChild( name )
	return LrPathUtils.child( LrPathUtils.getStandardFilePath( 'temp' ), name )
end

local function writeTempJpeg( bytes )
	tmpCounter = tmpCounter + 1
	local path = tempChild( string.format( 'speciestagger-%d-%d.jpg', os.time(), tmpCounter ) )
	local fh, err = io.open( path, 'wb' )
	if not fh then return nil, err end
	fh:write( bytes )
	fh:close()
	return path
end

-- One image path per line for the helper's hash mode; a blank line marks a
-- photo whose render failed (the helper answers null, Burst leaves it alone).
local function writeTempList( paths )
	tmpCounter = tmpCounter + 1
	local path = tempChild( string.format( 'speciestagger-hashlist-%d-%d.txt', os.time(), tmpCounter ) )
	local fh = io.open( path, 'wb' )
	if not fh then return nil end
	fh:write( table.concat( paths, '\n' ) .. '\n' )
	fh:close()
	return path
end

--------------------------------------------------------------------------------
-- first-run welcome

local function firstRunWelcome()
	LrDialogs.message( 'Species Tagger — Welcome', table.concat( {
		'WHERE TO FIND IT:  select photos in the Library, then ' ..
			'File ▸ Plug-in Extras ▸ Identify and Tag Species.',
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
		'Bursts are grouped automatically: near-identical frames shot within a second of each ' ..
			'other are tagged together from one identification, so a long burst costs you one ' ..
			'highlight, not one per frame.',
		'',
		'You stay in control — the plugin uses only the name you highlight; it does not read ' ..
			'Google’s results for you.',
		'',
		'Settings live in  File ▸ Plug-in Manager ▸ Species Tagger  (keyword style, burst ' ..
			'detection, export). Recognition needs only Google Chrome installed.',
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
		pluginPath = _PLUGIN.path,
		tabsPort = ASSIST_PORT,
	}
	local resolveDeps = { http = Http.lrAdapter(), cache = {} } -- shared GBIF cache for the run
	local keyCfg = { keywordMode = cfg.keywordMode }

	LrDialogs.showBezel( 'A Chrome window opens showing Google’s results — highlight the species and press Tag.' )

	local progress = LrProgressScope { title = 'Tag species with Lens…' }
	progress:setCancelable( true )

	-- ── Phase 1: gather — render every photo once, read burst metadata ────────
	local rec = {}    -- i -> { photo, file|nil, err|nil }
	local frames = {} -- Burst.cluster input, id = selection index
	for i, photo in ipairs( photos ) do
		if progress:isCanceled() then break end
		progress:setCaption( string.format( 'Preparing %s (%d of %d)', fileName( photo ), i, #photos ) )
		progress:setPortionComplete( i - 1, #photos )

		local r = { photo = photo }
		local bytes, err = jpegBytes( photo, cfg.maxEdge )
		if not bytes then
			r.err = err
		else
			local file, werr = writeTempJpeg( bytes )
			if file then r.file = file else r.err = werr end
		end
		rec[ i ] = r

		local t, serial
		if cfg.burstDetect then
			local okT, tv = pcall( function() return photo:getRawMetadata( 'dateTimeOriginal' ) end )
			if okT and type( tv ) == 'number' then t = tv end
			local okS, sv = pcall( function() return photo:getFormattedMetadata( 'cameraSerialNumber' ) end )
			if okS and type( sv ) == 'string' and sv ~= '' then serial = sv end
		end
		frames[ i ] = { id = i, t = t, serial = serial } -- hash filled in below
	end
	local gathered = #frames

	-- one helper call fingerprints all renders (hash mode: local, no Chrome)
	if cfg.burstDetect and gathered > 1 and not progress:isCanceled() then
		progress:setCaption( 'Detecting bursts…' )
		local list = {}
		for i = 1, gathered do list[ i ] = rec[ i ].file or '' end
		local listFile = writeTempList( list )
		if listFile then
			local hashes, herr = assist.hash( listFile, gathered )
			LrFileUtils.delete( listFile )
			if hashes then
				for i = 1, gathered do
					if hashes[ i ] then frames[ i ].hash = hashes[ i ] end
				end
			else
				-- no hashes -> every frame stays a singleton (the old behavior)
				log:warn( 'burst hashing unavailable: ' .. Log.redact( tostring( herr ) ) )
			end
		end
	end

	-- ── Phase 2: cluster (pure) ───────────────────────────────────────────────
	local clusters
	if cfg.burstDetect then
		clusters = Burst.cluster( frames, { gapSeconds = cfg.burstGapSeconds } )
		local plan = {}
		for k, cl in ipairs( clusters ) do
			local names = {}
			for _, i in ipairs( cl ) do names[ #names + 1 ] = fileName( rec[ i ].photo ) end
			plan[ #plan + 1 ] = string.format( '  burst %d (%d photo%s): %s',
				k, #cl, #cl == 1 and '' or 's', table.concat( names, ' ' ) )
		end
		log:info( 'burst plan — ' .. #clusters .. ' group(s) from ' .. gathered .. ' photo(s)\n'
			.. table.concat( plan, '\n' ) )
	else
		clusters = {}
		for i = 1, gathered do clusters[ i ] = { i } end
	end

	-- ── Phase 3: assist loop, one Lens read per cluster ───────────────────────
	local nApplied, nSkipped = 0, 0
	local lines = {}
	local function moreSuffix( cl )
		return #cl > 1 and ( ' +' .. ( #cl - 1 ) .. ' more' ) or ''
	end

	for k, cl in ipairs( clusters ) do
		if progress:isCanceled() then break end
		progress:setPortionComplete( k - 1, #clusters )
		local r = rec[ cl[ 1 ] ] -- representative: first frame by capture time
		progress:setCaption( fileName( r.photo ) )

		if not r.file then
			nSkipped = nSkipped + #cl
			lines[ #lines + 1 ] = '✗ ' .. fileName( r.photo ) .. moreSuffix( cl ) .. ' — ' .. tostring( r.err )
			log:warn( 'render failed: ' .. Log.redact( tostring( r.err ) ) )
		else
			local pos
			if #cl > 1 then
				pos = string.format( 'Burst %d of %d — %d photos', k, #clusters, #cl )
			else
				pos = string.format( 'Photo %d of %d', k, #clusters )
			end
			-- opens/reuses the window; blocks until the user Tags a selection (or Skips / times out)
			local name, aerr = assist.tag( r.file, pos )

			if not name then
				-- Skipped, timed out, or a helper error: leave the whole cluster untouched.
				nSkipped = nSkipped + #cl
				local why = ( aerr == Http.LENS_CANCELLED ) and 'skipped'
					or ( 'not tagged (' .. tostring( aerr ) .. ')' )
				lines[ #lines + 1 ] = '⊘ ' .. fileName( r.photo ) .. moreSuffix( cl ) .. ' — ' .. why
				if aerr ~= Http.LENS_CANCELLED then log:warn( 'assist: ' .. Log.redact( tostring( aerr ) ) ) end
			else
				local res = SelectedName.resolve( name, resolveDeps, keyCfg )
				if res.ok then
					local undoLabel = #cl > 1
						and string.format( 'Tag species (%d photos)', #cl ) or 'Tag species'
					catalog:withWriteAccessDo( undoLabel, function()
						for _, i in ipairs( cl ) do
							KeywordApply.apply( catalog, rec[ i ].photo, res.plan, cfg )
						end
					end, { timeout = 30 } )
					nApplied = nApplied + #cl
					lines[ #lines + 1 ] = string.format( '✓ %s%s — %s (%s)', fileName( r.photo ),
						moreSuffix( cl ), res.taxon.commonName or res.taxon.scientificName,
						res.taxon.scientificName )
				else
					nSkipped = nSkipped + #cl
					lines[ #lines + 1 ] = '⊘ ' .. fileName( r.photo ) .. moreSuffix( cl ) ..
						' — “' .. tostring( name ) .. '” not found in GBIF'
				end
			end
		end

		-- this cluster is done with its renders — free the disk as we go
		for _, i in ipairs( cl ) do
			if rec[ i ].file then
				LrFileUtils.delete( rec[ i ].file )
				rec[ i ].file = nil
			end
		end
	end

	-- cancel mid-run leaves later clusters' renders behind: sweep them
	for i = 1, gathered do
		if rec[ i ].file then LrFileUtils.delete( rec[ i ].file ) end
	end

	assist.close() -- shut the reused window down cleanly (no "didn't shut down correctly" prompt)
	progress:done()

	local bezel = string.format( 'Species Tagger: tagged %d%s',
		nApplied, nSkipped > 0 and ( ', skipped ' .. nSkipped ) or '' )
	log:info( 'assist run complete — ' .. bezel .. '\n' .. table.concat( lines, '\n' ) )
	LrDialogs.showBezel( bezel, 4 )
end

return M
