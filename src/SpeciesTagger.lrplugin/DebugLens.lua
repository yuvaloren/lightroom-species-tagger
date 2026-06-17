--[[----------------------------------------------------------------------------
DebugLens.lua
The in-Lightroom version of ./debug-lens.sh. For the selected photo it runs the
Google Lens helper in a VISIBLE Chrome window with full debug artifacts, using the
EXACT render + upload path a normal tagging run uses (TagSpecies.observe with a
debug-enabled lensSearch). Afterwards it reveals the artifacts folder in Finder and
shows what Lens returned and how the pipeline would score it — so a wrong
identification (e.g. a fish coming back as a weasel) can be diagnosed without a
terminal.

Backend is forced to Lens here regardless of the configured one — this command is
specifically for debugging the Lens path.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrPrefs = import 'LrPrefs'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrShell = import 'LrShell'

local Config = require 'Config'
local Identify = require 'Identify'
local Taxonomy = require 'Taxonomy'
local Http = require 'Http'
local TagSpecies = require 'TagSpecies'

local M = {}

local function shallowCopy( t )
	local o = {}
	for k, v in pairs( t ) do o[ k ] = v end
	return o
end

local function nameOf( photo )
	local ok, n = pcall( function() return photo:getFormattedMetadata( 'fileName' ) end )
	return ok and n or 'photo'
end

function M.run( _ )
	local catalog = LrApplication.activeCatalog()
	local photo = catalog:getTargetPhoto()
	if not photo then
		local sel = catalog:getTargetPhotos()
		photo = sel and sel[ 1 ]
	end
	if not photo then
		LrDialogs.message( 'Species Tagger — Debug Lens', 'Select a photo first.', 'info' )
		return
	end

	-- Debug is Lens-specific; force the Lens backend regardless of the configured one.
	local cfg = shallowCopy( Config.load( LrPrefs.prefsForPlugin() ) )
	cfg.backend = 'lens'

	-- Artifacts go to a findable, per-run folder we reveal in Finder afterwards.
	local stamp = os.date( '%Y%m%d-%H%M%S' )
	local safeName = nameOf( photo ):gsub( '[^%w%.%-]', '_' )
	local debugDir = LrPathUtils.child(
		LrPathUtils.child( LrPathUtils.getStandardFilePath( 'desktop' ), 'SpeciesTagger-debug' ),
		safeName .. '-' .. stamp )
	LrFileUtils.createAllDirectories( debugDir )

	local http = Http.lrAdapter()
	local lensSearch = Http.lensSearchAdapter {
		helperPath = LrPathUtils.child( _PLUGIN.path, 'lens/lens-search.js' ),
		nodePath = cfg.nodePath,
		debugDir = debugDir,
		interactive = true, -- debugging a challenged session is exactly when you solve it
	}
	local providerDeps = { http = http, lensSearch = lensSearch }

	LrDialogs.showBezel( 'Opening a Chrome window to run Google Lens…' )
	local obs, err = TagSpecies.observe( photo, cfg, providerDeps )

	-- Reveal the artifacts no matter what: page.png/.html, the scraped strings + the
	-- page region each came from (strings-sources.json), uploaded.jpg, results-url.txt
	-- and helper-stderr.log explain what happened even on failure.
	LrShell.revealInShell( debugDir )

	if err == '__lens_cancelled__' then
		LrDialogs.message( 'Species Tagger — Debug Lens',
			'Cancelled — the Google check was not completed.\n\nArtifacts are at:\n' .. debugDir, 'info' )
		return
	end
	if not obs or #obs == 0 then
		LrDialogs.message( 'Species Tagger — Debug Lens',
			'Lens helper failed or returned nothing:\n\n' .. tostring( err or 'no observations were scraped' ) ..
			'\n\nThe Chrome window (if it opened) + artifacts (incl. helper-stderr.log) are at:\n' .. debugDir, 'warning' )
		return
	end

	-- Score it through the same pipeline so the dialog explains the identification.
	local resolveDeps = { http = http, cache = {} }
	local result = Identify.run( obs, {
		resolve = function( c ) return Taxonomy.resolve( c, resolveDeps ) end,
	}, { autoApplyThreshold = cfg.autoApplyThreshold } )

	local overview
	for _, o in ipairs( obs ) do
		if o.source == 'lens:ai' then overview = o.text; break end
	end

	local lines = {}
	lines[ #lines + 1 ] = 'Photo: ' .. nameOf( photo )
	lines[ #lines + 1 ] = 'AI Overview: ' .. ( overview and ( '"' .. overview .. '"' ) or '(none on the page)' )
	lines[ #lines + 1 ] = 'Observations scraped: ' .. #obs
	lines[ #lines + 1 ] = ''
	if result.decision == 'apply' then
		lines[ #lines + 1 ] = 'WOULD TAG:'
		for _, a in ipairs( result.confident ) do
			lines[ #lines + 1 ] = string.format( '  • %s (%s) — %d%%',
				a.taxon.commonName or a.taxon.scientificName, a.taxon.scientificName,
				math.floor( a.confidence * 100 + 0.5 ) )
		end
	else
		local t = result.top and result.top.taxon
		local guess = t and ( ( t.commonName and t.scientificName )
			and ( t.commonName .. ' (' .. t.scientificName .. ')' )
			or ( t.commonName or t.scientificName or '?' ) ) or '(nothing resolved)'
		lines[ #lines + 1 ] = 'NEEDS REVIEW — best guess: ' .. guess
	end
	lines[ #lines + 1 ] = ''
	lines[ #lines + 1 ] = 'Scraped names (up to 15):'
	local shown = 0
	for _, o in ipairs( obs ) do
		if not ( o.kind == 'label' and o.source == 'lens:ai' ) then
			shown = shown + 1
			if shown <= 15 then lines[ #lines + 1 ] = '  · ' .. tostring( o.text ) end
		end
	end
	lines[ #lines + 1 ] = ''
	lines[ #lines + 1 ] = 'A Chrome window was left open so you can see exactly what Lens showed.'
	lines[ #lines + 1 ] = ''
	lines[ #lines + 1 ] = 'Artifacts (revealed in Finder):'
	lines[ #lines + 1 ] = debugDir
	lines[ #lines + 1 ] = ''
	lines[ #lines + 1 ] = 'Open results-url.txt in your own Chrome to compare; strings-sources.json'
	lines[ #lines + 1 ] = 'shows each scraped name, its page region, and whether it was excluded as noise.'

	LrDialogs.message( 'Species Tagger — Debug Lens', table.concat( lines, '\n' ), 'info' )
end

return M
