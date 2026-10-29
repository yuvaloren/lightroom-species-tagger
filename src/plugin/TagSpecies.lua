--[[----------------------------------------------------------------------------
TagSpecies.lua
The action, run inside Lightroom. Assistive Google Lens workflow, burst-aware.
The run has three phases:

  1. GATHER  — render every selected photo to a downsized JPEG through
     Lightroom's EXPORT pipeline (LrExportSession — a real render from the
     negative with the current develop settings, original EXIF/GPS stripped;
     see shared/Render.lua for why NOT requestJpegThumbnail) and read capture
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
local LrExportSession = import 'LrExportSession'

local Config = require 'Config'
local PhotoMeta = require 'PhotoMeta'
local SelectedName = require 'SelectedName'
local KeywordApply = require 'KeywordApply'
local Burst = require 'Burst'
local TagRun = require 'TagRun'
local Render = require 'Render'
local Http = require 'Http'
local Log = require 'Log'

local M = {}
local log = Log.new( 'SpeciesTagger' )

-- How long a keyword write may wait for the catalog before it is reported as
-- NOT saved (see applyCluster below).
local WRITE_TIMEOUT_SECONDS = 30


--------------------------------------------------------------------------------
-- helpers

local tmpCounter = 0

-- Uniquifier for this process's run folders: os.time() alone is 1-second
-- coarse in a SHARED temp dir, and two Lightroom processes (two catalogs) could
-- otherwise render into each other's folder. A table address is unique per
-- allocation and ASLR varies it across processes (same trick as Http.lua).
local tmpToken = tostring( {} ):match( '(%x+)%s*$' ) or 'p'

local function tempChild( name )
	return LrPathUtils.child( LrPathUtils.getStandardFilePath( 'temp' ), name )
end

-- A private folder for this run's renders. Everything the export writes lands
-- here (original file names, collisions renamed), and the cleanup handler
-- removes the whole folder however the run ends.
local function newRunDir()
	tmpCounter = tmpCounter + 1
	local dir = tempChild( string.format( 'speciestagger-%d-%s-%d', os.time(), tmpToken, tmpCounter ) )
	LrFileUtils.createAllDirectories( dir )
	return dir
end

-- One image path per line for the helper's hash mode; a blank line marks a
-- photo whose render failed (the helper answers null, Burst leaves it alone).
-- nil when the list could not be written in full — a truncated list would
-- hash the wrong files against the wrong frames.
local function writeTempList( dir, paths )
	tmpCounter = tmpCounter + 1
	local path = LrPathUtils.child( dir, string.format( 'speciestagger-hashlist-%d.txt', tmpCounter ) )
	local fh = io.open( path, 'wb' )
	if not fh then return nil end
	local ok = fh:write( table.concat( paths, '\n' ) .. '\n' )
	fh:close()
	if not ok then LrFileUtils.delete( path ); return nil end
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

function M.run( context )
	local catalog = LrApplication.activeCatalog()
	-- getTargetPhotos() returns EVERY photo in the filmstrip when nothing is
	-- selected (documented SDK behavior) — so "no selection" used to tag the
	-- whole folder. getTargetPhoto() is nil in exactly that case; gate on it.
	local photos = catalog:getTargetPhotos()
	if not catalog:getTargetPhoto() or not photos or #photos == 0 then
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

	-- Attached to the function context so an error anywhere below still removes
	-- the scope from Lightroom's activity area instead of orphaning it there.
	local progress = LrProgressScope { title = 'Tag species with Lens…', functionContext = context }
	progress:setCancelable( true )

	-- ── Gather: render every photo once, read burst metadata (LR I/O) ─────────
	-- The orchestration itself (cluster → one Lens read per burst, block on the
	-- user's Tag, apply to every member) is the pure, unit-tested TagRun module;
	-- everything below just supplies the real effects it calls.
	local items = {} -- selection order; each { id, photo, file|false, err, t, serial, label }
	local runDir = newRunDir()

	-- The rendered JPEGs must not outlive the run HOWEVER it ends — clean
	-- finish, cancel, abort, or an error thrown anywhere below. A cleanup handler
	-- runs on every exit from the context, so this is the single sweep
	-- (onClusterDone already frees each burst's files as it completes; whatever
	-- is left here is the remainder, then the run folder itself).
	context:addCleanupHandler( function()
		for _, it in ipairs( items ) do
			if it.file then LrFileUtils.delete( it.file ) end
		end
		LrFileUtils.delete( runDir )
	end )

	-- Render through the export pipeline, not photo:requestJpegThumbnail. The
	-- thumbnail call answers from the preview cache, which in the Develop module
	-- (or right after a Develop edit, before the preview is rebuilt) hands back a
	-- blank/stale placeholder first, an "error loading thumb", or nothing at all
	-- — see shared/Render.lua. An export is a definite render of the CURRENT
	-- develop state in every module, one file per photo, or a definite error.
	local session = LrExportSession {
		photosToExport = photos,
		exportSettings = Render.exportSettings { maxEdge = cfg.maxEdge, outDir = runDir },
	}
	session:doExportOnNewTask()
	for i, rendition in session:renditions() do
		local photo = rendition.photo or photos[ i ]
		if progress:isCanceled() then
			-- Don't render what nobody will look at; the export task finishes
			-- promptly instead of filling the run folder behind the cleanup.
			LrTasks.pcall( function() rendition:skipRender() end )
		else
			-- PhotoMeta calls the SDK getters BARE — they yield (catalog read access),
			-- and a yield cannot cross a plain pcall in Lua 5.1. The pcall wrappers
			-- that used to sit here failed on every call because of that, which
			-- silently untimed every frame and broke burst grouping in the field
			-- (see shared/PhotoMeta.lua and photometa_spec.lua).
			local meta = PhotoMeta.read( photo, cfg.burstDetect )
			progress:setCaption( string.format( 'Rendering %s (%d of %d)', meta.label, i, #photos ) )
			progress:setPortionComplete( i - 1, #photos )

			local it = { id = i, photo = photo, label = meta.label, t = meta.t, serial = meta.serial, file = false }
			-- BLOCKS until this photo is rendered: (true, path) or (false, message).
			local ok, pathOrMessage = rendition:waitForRender()
			if ok and type( pathOrMessage ) == 'string' and LrFileUtils.exists( pathOrMessage ) == 'file' then
				it.file = pathOrMessage
			else
				it.err = ( not ok and pathOrMessage ) or 'could not render a preview JPEG'
			end
			items[ #items + 1 ] = it
		end
	end

	-- Fingerprint all renders in one helper call (hash mode: local, no Chrome).
	local function hashFiles( files )
		local listFile = writeTempList( runDir, files )
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
			-- Create the plan's keywords ONCE and attach the handles to every frame:
			-- re-running createKeyword per photo in one write transaction returns no
			-- usable handle for repeats and silently dropped keywords on every frame
			-- past the first (see shared/KeywordApply.lua).
			local clusterPhotos = {}
			for _, m in ipairs( members ) do clusterPhotos[ #clusterPhotos + 1 ] = m.photo end
			local status = catalog:withWriteAccessDo( undoLabel, function()
				KeywordApply.applyCluster( catalog, clusterPhotos, plan, cfg )
			end, { timeout = WRITE_TIMEOUT_SECONDS } )
			-- With a timeout the SDK does NOT throw when the catalog stays busy: it
			-- returns "aborted" and the function never ran ("executed" is success;
			-- "queued" only exists for asynchronous writes). This status used to be
			-- ignored, so a lost write was still reported as "tagged N". Tell TagRun
			-- the truth; it stops the run rather than lose the next pick the same way.
			if status ~= nil and status ~= 'executed' then
				return false, string.format( 'Lightroom’s catalog stayed busy for %d s — write status “%s”',
					WRITE_TIMEOUT_SECONDS, tostring( status ) )
			end
			return true
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

	-- NOTE: the reused window is closed inside TagRun (closeWindow dep) on a clean
	-- finish only — an aborted run intentionally leaves it open for the user.
	progress:done()

	local tally = string.format( 'tagged %d%s', out.applied,
		out.skipped > 0 and ( ', skipped ' .. out.skipped ) or '' )
	local bezel
	if out.aborted then
		-- The user closed the Chrome window (or the wait timed out, or a write
		-- was lost): the run stopped early; whatever was tagged before the stop
		-- was kept.
		bezel = string.format( 'Species Tagger stopped — %s. %s so far.',
			out.abortReason or 'the run was interrupted', tally )
	else
		bezel = 'Species Tagger: ' .. tally
	end
	log:info( 'assist run complete — ' .. bezel .. '\n' .. table.concat( out.lines, '\n' ) )
	LrDialogs.showBezel( bezel, out.aborted and 6 or 4 )
end

return M
