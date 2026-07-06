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
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'

local Config = require 'Config'
local Providers = require 'Providers'
local Identify = require 'Identify'
local Taxonomy = require 'Taxonomy'
local Keywords = require 'Keywords'
local LensQuery = require 'LensQuery'
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

-- Apply an Identify result to one photo inside a write transaction. Returns
-- decision ('apply'|'review') and a one-line summary. Shared by the main run loop
-- and the re-parse action so both tag identically.
function M.applyResult( catalog, photo, result, cfg )
	local keyCfg = { mode = cfg.keywordMode, rootKeyword = cfg.rootKeyword, flatRoot = cfg.flatRoot }
	local decision, line = 'review', nil
	catalog:withWriteAccessDo( 'Tag species', function()
		if result.decision == 'apply' then
			local names = {}
			for _, a in ipairs( result.confident ) do
				applyPlan( catalog, photo, Keywords.plan( a.taxon, keyCfg ), cfg )
				names[ #names + 1 ] = string.format( '%s (%s, %d%%)',
					a.taxon.commonName or a.taxon.scientificName,
					a.taxon.scientificName, math.floor( a.confidence * 100 + 0.5 ) )
			end
			decision = 'apply'
			line = '✓ ' .. fileName( photo ) .. ' — ' .. table.concat( names, '; ' )
		else
			applyNeedsReview( catalog, photo, cfg )
			-- Show the common name alongside the Latin best guess (makes a wrong guess
			-- obvious — "Egyptian weasel (Mustela subpalmata)" vs a bare binomial).
			local tt = result.top and result.top.taxon or nil
			local guess = tt and ( ( tt.commonName and tt.scientificName )
				and ( tt.commonName .. ' (' .. tt.scientificName .. ')' )
				or ( tt.commonName or tt.scientificName or '' ) ) or ''
			line = '? ' .. fileName( photo ) ..
				' — needs review' .. ( guess ~= '' and ( ' (best guess: ' .. guess .. ')' ) or '' )
		end
	end, { timeout = 30 } )
	return decision, line
end

-- Build the provider opts table from settings + image. (Glue layer — the only
-- place that maps Config keys onto the provider.) The Lens helper takes a file path.
local function optsFor( _backend, _cfg, _bytes, file )
	return { imageFile = file }
end

-- Get observations for one photo from the configured provider. The Lens helper
-- uploads the image file, so we render a temp JPEG on disk (cleaned up afterwards).
-- Capture GPS from the catalog (the rendered preview has no EXIF), so Lens can
-- favour species that occur where the photo was actually taken.
local function photoGps( photo )
	local ok, gps = pcall( function() return photo:getRawMetadata( 'gps' ) end )
	if ok and type( gps ) == 'table' and gps.latitude and gps.longitude then
		return gps.latitude, gps.longitude
	end
	return nil
end

-- The photo's IPTC place fields (sublocation, city, state, country) as a
-- "City, State, Country" string, or nil. Used two ways: as a Lens-search text
-- refinement (so location is a keyword), and — when there are no GPS coords — as a
-- place the helper geocodes for browser geolocation.
local function photoPlace( photo )
	local parts = {}
	for _, key in ipairs { 'location', 'city', 'stateProvince', 'country' } do
		local ok, v = pcall( function() return photo:getFormattedMetadata( key ) end )
		if ok and type( v ) == 'string' and v ~= '' then parts[ #parts + 1 ] = v end
	end
	if #parts == 0 then return nil end
	return table.concat( parts, ', ' )
end

-- The Lens-search text refinement (extra keywords + the location, framed with "in "
-- so Lens treats the place as context, not subject) lives in the pure, tested
-- LensQuery module. See src/shared/LensQuery.lua.

-- Exposed (M.observe) so the "Debug Lens" action can reuse the EXACT render +
-- upload path a normal tagging run uses, just with a debug-enabled lensSearch.
function M.observe( photo, cfg, deps )
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
		local placeText = photoPlace( photo )
		-- No GPS: hand the place name to the helper to geocode for browser geolocation.
		if not opts.lat then opts.place = placeText end
		-- Location + the run's extra keywords also go into the search as text
		-- (location prefixed with "in " so Lens treats it as context, not subject).
		opts.query = LensQuery.build( cfg.lensExtraKeywords, placeText )
		-- Identity for the keep-open tab, so a later "Re-parse" can re-tag this photo.
		local okp, p = pcall( function() return photo:getRawMetadata( 'path' ) end )
		opts.photoPath = okp and p or nil
		opts.photoName = fileName( photo )
	end

	local obs, oerr = provider.identify( opts, deps )
	if file then LrFileUtils.delete( file ) end
	-- Providers signal failure as ({}, err) (empty list + message). Normalise that to
	-- nil-on-error here so every caller's `if not obs` guard catches real failures
	-- (otherwise an empty table is truthy and the error is silently swallowed).
	if oerr and oerr ~= '' then return nil, oerr end
	return obs, oerr
end

--------------------------------------------------------------------------------
-- first-run welcome + per-run keyword prompt

-- Shown once (gated by prefs.firstRunDone): what the plugin does, every setting it
-- has, and where to find them next time. Answers issue 1.
local function firstRunWelcome()
	LrDialogs.message( 'Species Tagger — Welcome', table.concat( {
		'Species Tagger identifies the plants and animals in your selected photos and tags ' ..
			'them with both the common and the Latin (scientific) name, using Google Lens ' ..
			'(free — no API key).',
		'',
		'All settings live in  File ▸ Plug-in Manager ▸ Species Tagger  — open that panel any ' ..
			'time to change:',
		'  • Keep the browser open — reuse one Chrome window; refine a search and re-parse it',
		'  • node path — set only if Lightroom can’t find Node.js on its own',
		'  • Keywords — flat (common + Latin), the full taxonomy hierarchy, or both',
		'  • Hierarchy root — an optional parent keyword (e.g. Wildlife)',
		'  • Auto-tag confidence — how sure it must be before a keyword is applied',
		'  • Needs-review tag — applied when nothing is confident enough',
		'  • Ask for extra keywords each run — on or off (on by default)',
		'',
		'Recognition needs Node.js and Google Chrome installed. A Chrome window opens so you ' ..
			'can watch Google’s real results — solve any “are you human” check there if asked.',
		'',
		'Run it from  Library ▸ Plug-in Extras ▸ Identify and Tag Species.',
	}, '\n' ), 'info' )
end

-- Ask for extra keywords to fold into this run's Lens search (issue 2). Prefilled
-- with the last entry. Returns the string (possibly empty) or nil if cancelled.
local function promptExtraKeywords( prefs )
	local result
	LrFunctionContext.callWithContext( 'speciesTagger.keywords', function( ctx )
		local props = LrBinding.makePropertyTable( ctx )
		props.kw = prefs.lastExtraKeywords or ''
		local f = LrView.osFactory()
		local contents = f:column {
			bind_to_object = props, spacing = f:control_spacing(),
			f:static_text {
				title = 'Extra keywords to add to the Google Lens search (this run):',
				width = 460,
			},
			f:edit_field { value = LrView.bind 'kw', width_in_chars = 44, immediate = true },
			f:static_text {
				title = 'Optional — added to every selected photo’s search alongside its location. ' ..
					'e.g. “juvenile”, “reef”, a place name. Leave blank for a plain image search.',
				wrap = true, width = 460, height_in_lines = 2,
			},
		}
		local btn = LrDialogs.presentModalDialog {
			title = 'Species Tagger — Extra keywords',
			contents = contents,
			actionVerb = 'Search',
			cancelVerb = 'Cancel',
		}
		if btn == 'ok' then result = props.kw or '' end
	end )
	return result
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

	-- First-run welcome: what it does, every setting, and where to find them (issue 1).
	if not prefs.firstRunDone then
		firstRunWelcome()
		prefs.firstRunDone = true
	end

	-- Ask for extra keywords to include in the Lens search (issue 2). Cancel aborts.
	if cfg.promptExtraKeywords then
		local kw = promptExtraKeywords( prefs )
		if kw == nil then return end
		cfg.lensExtraKeywords = kw
		prefs.lastExtraKeywords = kw
	end

	local http = Http.lrAdapter()
	-- Google Lens has no API and renders results with JS, so its backend shells out
	-- to the bundled Node + Chrome helper (built once per run). Other backends and
	-- all GBIF lookups use LrHttp.
	-- Interactive (escalate to a visible window on a Google challenge) only for a
	-- single-photo selection — a multi-photo batch must not block per-photo waiting
	-- for the human. interactiveState lets a cancel stop any further prompting.
	local interactiveState = { allow = true }
	local interactive = ( #photos == 1 )
	local lensSearch
	if Providers.get( cfg.backend ).usesLensHelper then
		lensSearch = Http.lensSearchAdapter {
			helperPath = LrPathUtils.child( _PLUGIN.path, 'lens/lens-search.js' ),
			nodePath = cfg.nodePath,
			interactive = interactive,
			interactiveState = interactiveState,
			keepOpen = cfg.lensKeepOpen,
		}
		-- A Chrome window opens to show Google's actual page (the helper is never
		-- headless). Tell the user so the windows aren't a surprise.
		if interactive then
			LrDialogs.showBezel( 'A Chrome window will open showing Google’s page — solve any check there if asked.' )
		else
			LrDialogs.showBezel( 'A Chrome window will open for each photo to show Google’s page.' )
		end
	end
	local providerDeps = { http = http, lensSearch = lensSearch }
	local resolveCache = {} -- shared GBIF cache for the whole run
	local resolveDeps = { http = http, cache = resolveCache }
	local identCfg = { autoApplyThreshold = cfg.autoApplyThreshold }

	local progress = LrProgressScope { title = 'Identifying species…' }
	progress:setCancelable( true )

	local nApplied, nReview, nError, nSkipped = 0, 0, 0, 0
	local lines = {}
	local challenged = false       -- set if Google rate-limited us; aborts + explains
	math.randomseed( os.time() )   -- for the inter-request throttle jitter below

	for i, photo in ipairs( photos ) do
		if progress:isCanceled() then break end
		progress:setPortionComplete( i - 1, #photos )
		progress:setCaption( fileName( photo ) )

		local obs, err = M.observe( photo, cfg, providerDeps )
		if err == '__lens_cancelled__' then
			nSkipped = nSkipped + 1
			lines[ #lines + 1 ] = '⊘ ' .. fileName( photo ) .. ' — skipped (Google check cancelled)'
		elseif err == '__lens_challenged__' then
			-- Google rate-limited this IP ("unusual traffic"). Stop the batch — every
			-- further request only deepens the block — and explain how to proceed below.
			challenged = true
			nSkipped = nSkipped + 1
			lines[ #lines + 1 ] = '⊘ ' .. fileName( photo ) .. ' — Google challenge (IP rate-limited); stopped here'
			break
		elseif not obs then
			nError = nError + 1
			lines[ #lines + 1 ] = '✗ ' .. fileName( photo ) .. ' — ' .. tostring( err )
			log:warn( 'observe failed: ' .. Log.redact( tostring( err ) ) )
		else
			local result = Identify.run( obs, {
				resolve = function( c ) return Taxonomy.resolve( c, resolveDeps ) end,
			}, identCfg )
			local decision, line = M.applyResult( catalog, photo, result, cfg )
			if decision == 'apply' then nApplied = nApplied + 1 else nReview = nReview + 1 end
			lines[ #lines + 1 ] = line
		end

		-- Throttle Lens requests: Google challenges bursts ("sending requests very
		-- quickly") from one IP, so space batch photos out with a little jitter rather
		-- than firing back-to-back. Lens-only (other backends are plain API calls);
		-- skipped after the last photo and when the user has cancelled.
		if lensSearch and i < #photos and not progress:isCanceled() then
			LrTasks.sleep( 3 + math.random() * 4 )  -- ~3–7s jittered
		end
	end

	progress:done()

	local summary = string.format(
		'Tagged %d, flagged %d for review, skipped %d, %d error%s (of %d).\n\n%s',
		nApplied, nReview, nSkipped, nError, nError == 1 and '' or 's', #photos,
		table.concat( lines, '\n' ) )
	if challenged then
		summary = summary .. '\n\n⚠ Google rate-limited this network (the “unusual traffic” ' ..
			'check). The block clears on its own after a while. To continue now: wait and ' ..
			'retry later, switch to a different network (e.g. a phone hotspot), run a single ' ..
			'photo (a Chrome window opens so you can solve the check by hand), or switch to ' ..
			'the Pl@ntNet / Vision backend in the plug-in settings.'
	end
	LrDialogs.message( 'Species Tagger', summary,
		( challenged or ( nError > 0 and nApplied == 0 ) ) and 'warning' or 'info' )
end

return M
