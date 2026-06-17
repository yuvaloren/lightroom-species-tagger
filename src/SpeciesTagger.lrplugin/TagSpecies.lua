--[[----------------------------------------------------------------------------
TagSpecies.lua
The action, run inside Lightroom. For each selected photo it:
  1. renders a downsized JPEG (requestJpegThumbnail — also strips original EXIF/GPS),
  2. asks the configured provider (Lens or Vision) for observations,
  3. resolves + scores them into ranked taxa (Identify + Taxonomy/GBIF),
  4. auto-applies keywords for every confident taxon (flat + hierarchy per settings),
     or tags the photo "species: needs review" when nothing clears the threshold.

This is the only file that talks to the Lightroom catalog; all the decision logic
lives in the pure, unit-tested shared modules.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrProgressScope = import 'LrProgressScope'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local Config = require 'Config'
local Providers = require 'Providers'
local Identify = require 'Identify'
local Taxonomy = require 'Taxonomy'
local Keywords = require 'Keywords'
local Http = require 'Http'
local Log = require 'Log'

local M = {}
local log = Log.new( 'SpeciesTagger' )

--------------------------------------------------------------------------------
-- helpers

local tmpCounter = 0

local function fileName( photo )
	local ok, name = pcall( function() return photo:getFormattedMetadata( 'fileName' ) end )
	return ok and name or '(photo)'
end

-- Render a downsized JPEG of the photo into memory. requestJpegThumbnail is
-- async; we wait (cooperatively) for its callback.
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

-- Ensure a keyword path exists (creating ancestors as needed) and return the leaf.
-- Must be called inside catalog:withWriteAccessDo.
local function ensureLeaf( catalog, path, synonyms, includeOnExport )
	local parent, leaf
	for idx, name in ipairs( path ) do
		local isLeaf = ( idx == #path )
		leaf = catalog:createKeyword( name, isLeaf and ( synonyms or {} ) or {},
			includeOnExport, parent, true ) -- returnExisting = true
		parent = leaf
	end
	return leaf
end

local function applyPlan( catalog, photo, plan, cfg )
	for _, node in ipairs( plan.nodes ) do
		local leaf = ensureLeaf( catalog, node.path, node.synonyms, cfg.includeOnExport )
		if node.attach and leaf then photo:addKeyword( leaf ) end
	end
end

local function applyNeedsReview( catalog, photo, cfg )
	local kw = catalog:createKeyword( cfg.needsReviewKeyword, {}, false, nil, true )
	if kw then photo:addKeyword( kw ) end
end

-- Build the provider-specific opts table for a backend from settings + image.
-- (Glue layer — the only place that maps Config keys onto each provider.)
local function optsFor( backend, cfg, bytes, file )
	if backend == 'vision' then
		return { imageBytes = bytes, apiKey = cfg.visionApiKey }
	elseif backend == 'plantnet' then
		return { imageFile = file, apiKey = cfg.plantNetKey, project = cfg.plantNetProject }
	else -- 'lens' (the browser helper takes just the file path)
		return { imageFile = file }
	end
end

-- Get observations for one photo from the configured provider. Vision sends the
-- bytes inline; Lens and Pl@ntNet upload them as a multipart file, so those need
-- a temp JPEG on disk (cleaned up afterwards).
-- Capture GPS from the catalog (the rendered preview has no EXIF), so Lens can
-- favour species that occur where the photo was actually taken.
local function photoGps( photo )
	local ok, gps = pcall( function() return photo:getRawMetadata( 'gps' ) end )
	if ok and type( gps ) == 'table' and gps.latitude and gps.longitude then
		return gps.latitude, gps.longitude
	end
	return nil
end

-- Fallback when there are no GPS coords: the IPTC place fields (sublocation, city,
-- state, country). The Lens helper geocodes the resulting "City, State, Country".
local function photoPlace( photo )
	local parts = {}
	for _, key in ipairs { 'location', 'city', 'stateProvince', 'country' } do
		local ok, v = pcall( function() return photo:getFormattedMetadata( key ) end )
		if ok and type( v ) == 'string' and v ~= '' then parts[ #parts + 1 ] = v end
	end
	if #parts == 0 then return nil end
	return table.concat( parts, ', ' )
end

local function observe( photo, cfg, deps )
	local bytes, err = jpegBytes( photo, cfg.maxEdge )
	if not bytes then return nil, err end

	local provider = Providers.get( cfg.backend )
	local file
	if provider.needsImageFile then
		local werr
		file, werr = writeTempJpeg( bytes )
		if not file then return nil, 'temp file: ' .. tostring( werr ) end
	end

	local opts = optsFor( cfg.backend, cfg, bytes, file )
	if cfg.backend == 'lens' then
		opts.lat, opts.lng = photoGps( photo )
		if not opts.lat then opts.place = photoPlace( photo ) end
	end

	local obs, oerr = provider.identify( opts, deps )
	if file then LrFileUtils.delete( file ) end
	return obs, oerr
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
	local ok, why = Config.validate( cfg )
	if not ok then
		LrDialogs.message( 'Species Tagger', why, 'warning' )
		return
	end

	local http = Http.lrAdapter()
	-- Google Lens has no API and renders results with JS, so its backend shells out
	-- to the bundled Node + Chrome helper (built once per run). Other backends and
	-- all GBIF lookups use LrHttp.
	local lensSearch
	if Providers.get( cfg.backend ).usesLensHelper then
		lensSearch = Http.lensSearchAdapter {
			helperPath = LrPathUtils.child( _PLUGIN.path, 'lens/lens-search.js' ),
			nodePath = cfg.nodePath,
		}
	end
	local providerDeps = { http = http, lensSearch = lensSearch }
	local resolveCache = {} -- shared GBIF cache for the whole run
	local resolveDeps = { http = http, cache = resolveCache }
	local identCfg = { autoApplyThreshold = cfg.autoApplyThreshold }
	local keyCfg = { mode = cfg.keywordMode, rootKeyword = cfg.rootKeyword, flatRoot = cfg.flatRoot }

	local progress = LrProgressScope { title = 'Identifying species…' }
	progress:setCancelable( true )

	local nApplied, nReview, nError = 0, 0, 0
	local lines = {}

	for i, photo in ipairs( photos ) do
		if progress:isCanceled() then break end
		progress:setPortionComplete( i - 1, #photos )
		progress:setCaption( fileName( photo ) )

		local obs, err = observe( photo, cfg, providerDeps )
		if not obs then
			nError = nError + 1
			lines[ #lines + 1 ] = '✗ ' .. fileName( photo ) .. ' — ' .. tostring( err )
			log:warn( 'observe failed: ' .. Log.redact( tostring( err ) ) )
		else
			local result = Identify.run( obs, {
				resolve = function( c ) return Taxonomy.resolve( c, resolveDeps ) end,
			}, identCfg )

			catalog:withWriteAccessDo( 'Tag species', function()
				if result.decision == 'apply' then
					local names = {}
					for _, a in ipairs( result.confident ) do
						applyPlan( catalog, photo, Keywords.plan( a.taxon, keyCfg ), cfg )
						names[ #names + 1 ] = string.format( '%s (%s, %d%%)',
							a.taxon.commonName or a.taxon.scientificName,
							a.taxon.scientificName, math.floor( a.confidence * 100 + 0.5 ) )
					end
					nApplied = nApplied + 1
					lines[ #lines + 1 ] = '✓ ' .. fileName( photo ) .. ' — ' .. table.concat( names, '; ' )
				else
					applyNeedsReview( catalog, photo, cfg )
					nReview = nReview + 1
					local guess = result.top and ( result.top.taxon.scientificName or '' ) or ''
					lines[ #lines + 1 ] = '? ' .. fileName( photo ) ..
						' — needs review' .. ( guess ~= '' and ( ' (best guess: ' .. guess .. ')' ) or '' )
				end
			end, { timeout = 30 } )
		end
	end

	progress:done()

	local summary = string.format(
		'Tagged %d, flagged %d for review, %d error%s (of %d).\n\n%s',
		nApplied, nReview, nError, nError == 1 and '' or 's', #photos,
		table.concat( lines, '\n' ) )
	LrDialogs.message( 'Species Tagger', summary, ( nError > 0 and nApplied == 0 ) and 'warning' or 'info' )
end

return M
