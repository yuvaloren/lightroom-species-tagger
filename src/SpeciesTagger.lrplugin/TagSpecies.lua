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
	local keyCfg = { mode = cfg.keywordMode, flatRoot = cfg.flatRoot }
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

-- How the run's hints reach the Lens search lives in the pure, tested LensQuery
-- module (src/shared/LensQuery.lua). Location is delivered as the natural-language
-- "identify picture using location: <place>" TEXT instruction, and only on the
-- location-assisted pass — see M.observe.

-- Exposed (M.observe) so a caller can reuse the EXACT render + upload path a normal
-- tagging run uses (e.g. the location-assisted retry).
-- hints = { other = <keywords>, location = <place> }; location present => the
-- location-assisted pass (adds "identify picture using location: <place>").
function M.observe( photo, cfg, deps, hints )
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
		-- Location is NOT sent as browser geolocation (measured: geolocation makes Lens's
		-- AI Overview hedge to genus/common and drop the binomial) and NOT on the first
		-- pass (it degrades easy, web-matchable photos). It is delivered as the
		-- "identify picture using location:" TEXT instruction ONLY when hints.location is set —
		-- the location-assisted retry — which is decisive for ambiguous subjects.
		local other = hints and hints.other
		local locationText = hints and hints.location
		if locationText and locationText ~= '' then
			opts.query = LensQuery.compose { other = other, location = locationText, strategy = 'identify-location' }
		else
			opts.query = LensQuery.compose { other = other, strategy = 'none' }
		end
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

-- Ask for two optional hints for this run: a LOCATION (used only for the
-- location-assisted retry) and OTHER identifying keywords. Prefilled with the last
-- entries. Returns { location=, other= } (either may be '') or nil if cancelled.
local function promptHints( prefs )
	local result
	LrFunctionContext.callWithContext( 'speciesTagger.hints', function( ctx )
		local props = LrBinding.makePropertyTable( ctx )
		props.location = prefs.lastLocationHint or ''
		props.other = prefs.lastOtherKeywords or ''
		local f = LrView.osFactory()
		local labelW = LrView.share 'st_hint_label'
		local contents = f:column {
			bind_to_object = props, spacing = f:control_spacing(),
			f:static_text {
				title = 'Two optional hints for this run — both may be left blank:',
				width = 500,
			},
			f:row {
				f:static_text { title = 'Location:', width = labelW, alignment = 'right' },
				f:edit_field { value = LrView.bind 'location', width_in_chars = 42, immediate = true },
			},
			f:static_text {
				title = 'Where the photo was taken — e.g. “Año Nuevo State Park”. Used only if a photo ' ..
					'can’t be identified on its own; it’s then re-tried as “identify picture using location: …”, ' ..
					'which disambiguates lookalike species.',
				wrap = true, width = 500, height_in_lines = 3,
			},
			f:row {
				f:static_text { title = 'Other keywords:', width = labelW, alignment = 'right' },
				f:edit_field { value = LrView.bind 'other', width_in_chars = 42, immediate = true },
			},
			f:static_text {
				title = 'Any other identifying detail added to the search — e.g. “juvenile”, “in flight”, ' ..
					'“nudibranch”. Leave blank for a plain image search.',
				wrap = true, width = 500, height_in_lines = 2,
			},
		}
		local btn = LrDialogs.presentModalDialog {
			title = 'Species Tagger — Search hints',
			contents = contents,
			actionVerb = 'Go',
			cancelVerb = 'Cancel',
		}
		if btn == 'ok' then result = { location = props.location or '', other = props.other or '' } end
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

	-- Ask for the run's two optional hints (location + other keywords). Cancel aborts.
	if cfg.promptHints then
		local h = promptHints( prefs )
		if h == nil then return end
		cfg.locationHint = h.location
		cfg.otherKeywords = h.other
		prefs.lastLocationHint = h.location
		prefs.lastOtherKeywords = h.other
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
	-- With "Keep the browser open", the location-assisted retry REUSES this photo's
	-- existing tab (adds the location text in place) instead of opening a second one.
	local refineSearch
	if Providers.get( cfg.backend ).usesLensHelper and cfg.lensKeepOpen then
		refineSearch = Http.lensRefineAdapter {
			helperPath = LrPathUtils.child( _PLUGIN.path, 'lens/lens-search.js' ),
		}
	end
	local providerDeps = { http = http, lensSearch = lensSearch }
	local resolveCache = {} -- shared GBIF cache for the whole run
	local resolveDeps = { http = http, cache = resolveCache }
	local identCfg = { autoApplyThreshold = cfg.autoApplyThreshold }
	local function identify( obs )
		return Identify.run( obs, { resolve = function( c ) return Taxonomy.resolve( c, resolveDeps ) end }, identCfg )
	end
	local lensParse = Providers.get( cfg.backend ).parse -- {overview,strings} -> observations

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

		-- Pass 1: identify with no location (best for easy, web-matchable photos).
		local obs, err = M.observe( photo, cfg, providerDeps, { other = cfg.otherKeywords } )
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
			local result = identify( obs )
			-- Pass 2 (location-assisted retry): if the photo isn't confidently identified
			-- and we have a place — the run's location hint, else the photo's IPTC place —
			-- try once more with "identify picture using location: <place>", which disambiguates
			-- lookalike species (e.g. northern elephant seals at Año Nuevo). Keep whichever
			-- pass identifies. Skipped in keyword-only runs (no place available).
			if result.decision ~= 'apply' and cfg.locationAssistRetry and not progress:isCanceled() then
				local place = cfg.locationHint
				if not place or place == '' then place = photoPlace( photo ) end
				if place and place ~= '' then
					LrTasks.sleep( 2 + math.random() * 3 ) -- space the extra Lens hit out
					local obs2, err2
					if refineSearch then
						-- Keep-open: reuse this photo's tab, adding the location text in place.
						local okp, ppath = pcall( function() return photo:getRawMetadata( 'path' ) end )
						local q = LensQuery.compose { other = cfg.otherKeywords, location = place, strategy = 'identify-location' }
						local d = refineSearch( okp and ppath or nil, q )
						if d then obs2 = lensParse( d ) end
					else
						-- No kept-open tab to reuse: do a fresh location-assisted search.
						obs2, err2 = M.observe( photo, cfg, providerDeps, { other = cfg.otherKeywords, location = place } )
					end
					if err2 == '__lens_challenged__' then
						challenged = true
						nSkipped = nSkipped + 1
						lines[ #lines + 1 ] = '⊘ ' .. fileName( photo ) .. ' — Google challenge on location retry; stopped here'
						break
					elseif obs2 then
						local r2 = identify( obs2 )
						if r2.decision == 'apply' then result = r2 end
					end
				end
			end
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

	-- No modal summary on a normal run — the results are right there in the Keyword
	-- List and the needs-review tag. A brief bezel is enough; the per-photo detail
	-- goes to the plugin log for debugging. A modal is kept ONLY when it's actionable.
	local bezel = string.format( 'Species Tagger: tagged %d, review %d%s%s',
		nApplied, nReview,
		nSkipped > 0 and ( ', skipped ' .. nSkipped ) or '',
		nError > 0 and ( ', ' .. nError .. ' error' .. ( nError == 1 and '' or 's' ) ) or '' )
	log:info( 'run complete — ' .. bezel .. '\n' .. table.concat( lines, '\n' ) )
	LrDialogs.showBezel( bezel, 4 )

	if challenged then
		LrDialogs.message( 'Species Tagger',
			'Google rate-limited this network (the “unusual traffic” check). The block clears on ' ..
			'its own after a while. To continue now: wait and retry later, switch to a different ' ..
			'network (e.g. a phone hotspot), run a single photo (a Chrome window opens so you can ' ..
			'solve the check by hand), or switch to the Pl@ntNet / Vision backend in the plug-in settings.',
			'warning' )
	elseif nError > 0 and nApplied == 0 then
		LrDialogs.message( 'Species Tagger', string.format(
			'Nothing could be tagged (%d error%s of %d). See the plugin log for details.',
			nError, nError == 1 and '' or 's', #photos ), 'warning' )
	end
end

return M
