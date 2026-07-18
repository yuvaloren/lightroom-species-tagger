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
is the only file that talks to the Lightroom catalog; the ORCHESTRATION (cluster
→ one Lens read per burst, block on the user's Tag, apply to every member) is the
pure, unit-tested shared/TagRun.lua — this file only renders the photos and
supplies TagRun the real effects (render, hash, GBIF resolve, catalog write).
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrProgressScope = import 'LrProgressScope'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local Config = require 'Config'
local PhotoMeta = require 'PhotoMeta'
local SelectedName = require 'SelectedName'
local KeywordApply = require 'KeywordApply'
local Burst = require 'Burst'
local TagRun = require 'TagRun'
local Http = require 'Http'
local Log = require 'Log'

local M = {}
local log = Log.new( 'SpeciesTagger' )


--------------------------------------------------------------------------------
-- helpers

local tmpCounter = 0

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

	local assist = Http.lensAssistAdapter { pluginPath = _PLUGIN.path }
	local resolveDeps = { http = Http.lrAdapter(), cache = {} } -- shared GBIF cache for the run
	local keyCfg = { keywordMode = cfg.keywordMode }

	LrDialogs.showBezel( 'A Chrome window opens showing Google’s results — highlight the species and press Tag.' )

	local progress = LrProgressScope { title = 'Tag species with Lens…' }
	progress:setCancelable( true )

	-- ── Gather: render every photo once, read burst metadata (LR I/O) ─────────
	-- The orchestration itself (cluster → one Lens read per burst, block on the
	-- user's Tag, apply to every member) is the pure, unit-tested TagRun module;
	-- everything below just supplies the real effects it calls.
	local items = {} -- selection order; each { id, photo, file|false, err, t, serial, label }
	for i, photo in ipairs( photos ) do
		if progress:isCanceled() then break end
		-- PhotoMeta calls the SDK getters BARE — they yield (catalog read access),
		-- and a yield cannot cross a plain pcall in Lua 5.1. The pcall wrappers
		-- that used to sit here failed on every call because of that, which
		-- silently untimed every frame and broke burst grouping in the field
		-- (see shared/PhotoMeta.lua and photometa_spec.lua).
		local meta = PhotoMeta.read( photo, cfg.burstDetect )
		progress:setCaption( string.format( 'Preparing %s (%d of %d)', meta.label, i, #photos ) )
		progress:setPortionComplete( i - 1, #photos )

		local it = { id = i, photo = photo, label = meta.label, t = meta.t, serial = meta.serial, file = false }
		local bytes, err = jpegBytes( photo, cfg.maxEdge )
		if not bytes then
			it.err = err
		else
			local file, werr = writeTempJpeg( bytes )
			if file then it.file = file else it.err = werr end
		end
		items[ i ] = it
	end

	-- Fingerprint all renders in one helper call (hash mode: local, no Chrome).
	local function hashFiles( files )
		local listFile = writeTempList( files )
		if not listFile then return nil end
		local hashes = assist.hash( listFile, #files )
		LrFileUtils.delete( listFile )
		return hashes
	end

	local out = TagRun.run {
		items = items,
		cfg = cfg,
		cluster = Burst.cluster,
		hashFiles = hashFiles,
		tag = assist.tag,
		cancelled = Http.LENS_CANCELLED,
		aborted = Http.LENS_ABORTED,
		-- Shut the reused window at the end of a CLEAN run only; TagRun skips this
		-- on an abort so a window the user is still reading stays open.
		closeWindow = function() assist.close() end,
		resolve = function( name ) return SelectedName.resolve( name, resolveDeps, keyCfg ) end,
		applyCluster = function( members, plan )
			local undoLabel = #members > 1
				and string.format( 'Tag species (%d photos)', #members ) or 'Tag species'
			catalog:withWriteAccessDo( undoLabel, function()
				for _, m in ipairs( members ) do KeywordApply.apply( catalog, m.photo, plan, cfg ) end
			end, { timeout = 30 } )
		end,
		onClusterDone = function( members ) -- free the disk as each burst finishes
			for _, m in ipairs( members ) do
				if m.file then LrFileUtils.delete( m.file ); m.file = false end
			end
		end,
		progress = {
			canceled = function() return progress:isCanceled() end,
			caption = function( s ) progress:setCaption( s ) end,
			portion = function( d, t ) progress:setPortionComplete( d, t ) end,
		},
		log = {
			info = function( s ) log:info( s ) end,
			warn = function( s ) log:warn( Log.redact( s ) ) end,
		},
	}

	-- Cancel mid-run leaves later bursts' renders behind: sweep them.
	for _, it in ipairs( items ) do
		if it.file then LrFileUtils.delete( it.file ) end
	end

	-- NOTE: the reused window is closed inside TagRun (closeWindow dep) on a clean
	-- finish only — an aborted run intentionally leaves it open for the user.
	progress:done()

	local tally = string.format( 'tagged %d%s', out.applied,
		out.skipped > 0 and ( ', skipped ' .. out.skipped ) or '' )
	local bezel
	if out.aborted then
		-- The user closed the Chrome window (or the wait timed out): the run
		-- stopped early; whatever was tagged before the stop was kept.
		bezel = string.format( 'Species Tagger stopped — %s. %s so far.',
			out.abortReason or 'the run was interrupted', tally )
	else
		bezel = 'Species Tagger: ' .. tally
	end
	log:info( 'assist run complete — ' .. bezel .. '\n' .. table.concat( out.lines, '\n' ) )
	LrDialogs.showBezel( bezel, out.aborted and 6 or 4 )
end

return M
