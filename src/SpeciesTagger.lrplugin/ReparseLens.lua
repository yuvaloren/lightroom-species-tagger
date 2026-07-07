--[[----------------------------------------------------------------------------
ReparseLens.lua
The "correct the tagging" action (issue 8). With "Keep the browser open" on, each
photo's Lens results stay in its own tab, stamped with the photo it belongs to. Fix
as many as you like — refine the search in any tab(s) (Lens lets you add words, crop,
pick a different match) — then run this command once: it sweeps EVERY tab still on
Google Lens, re-runs the exact same parser → GBIF → scorer pipeline on each, and
re-tags each tab's own photo. No marking, no per-photo selection.

New keywords are added; it does not remove keywords you (or a previous run) applied
— delete a wrong one from the Keyword List if needed.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrPrefs = import 'LrPrefs'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'

local Config = require 'Config'
local Lens = require 'ProviderGoogleLens'
local Identify = require 'Identify'
local Taxonomy = require 'Taxonomy'
local Http = require 'Http'
local TagSpecies = require 'TagSpecies'

local M = {}

local function nameOf( photo )
	local ok, n = pcall( function() return photo:getFormattedMetadata( 'fileName' ) end )
	return ok and n or 'photo'
end

-- Resolve the photo a re-parsed tab belongs to. Prefer the path stamped on the tab
-- at search time; fall back to the selected photo when a single tab carries no stamp
-- (e.g. an older tab, or one you opened by hand).
local function photoForTab( catalog, tab, singleTab )
	if tab.photoPath and tab.photoPath ~= '' then
		local ok, p = pcall( function() return catalog:findPhotoByPath( tab.photoPath ) end )
		if ok and p then return p end
	end
	if singleTab then
		return catalog:getTargetPhoto() or ( catalog:getTargetPhotos() or {} )[ 1 ]
	end
	return nil
end

function M.run( _ )
	local catalog = LrApplication.activeCatalog()

	local cfg = Config.load( LrPrefs.prefsForPlugin() )
	local reparse = Http.lensReparseAdapter {
		helperPath = LrPathUtils.child( _PLUGIN.path, 'lens/lens-search.js' ),
	}

	LrDialogs.showBezel( 'Re-parsing every open Lens tab…' )
	local tabs, err = reparse()
	if not tabs then
		LrDialogs.message( 'Species Tagger — Re-parse',
			'Could not re-parse: ' .. tostring( err ) .. '\n\nRun "Identify and Tag Species" with ' ..
			'"Keep the browser open" enabled first, refine the search(es) in the tab(s), then try this again.', 'warning' )
		return
	end
	if #tabs == 0 then
		LrDialogs.message( 'Species Tagger — Re-parse',
			'No open Lens tabs had recognisable results to re-parse. Refine a search and retry.', 'info' )
		return
	end

	local http = Http.lrAdapter()
	local resolveCache = {} -- shared GBIF cache across every tab
	local single = ( #tabs == 1 )
	local nApplied, nReview, nUnmatched = 0, 0, 0
	local lines = {}

	for _, tab in ipairs( tabs ) do
		local photo = photoForTab( catalog, tab, single )
		if not photo then
			nUnmatched = nUnmatched + 1
			lines[ #lines + 1 ] = '⚠ ' .. ( tab.photoName ~= '' and tab.photoName or 'a tab' ) ..
				' — could not match to a photo (re-run Identify to re-open its tab)'
		else
			local obs = Lens.parse( { overview = tab.overview, strings = tab.strings } )
			if not obs or #obs == 0 then
				nReview = nReview + 1
				lines[ #lines + 1 ] = '? ' .. nameOf( photo ) .. ' — nothing to re-parse in its tab'
			else
				local result = Identify.run( obs, {
					resolve = function( c ) return Taxonomy.resolve( c, { http = http, cache = resolveCache } ) end,
				}, { autoApplyThreshold = cfg.autoApplyThreshold } )
				local decision, line = TagSpecies.applyResult( catalog, photo, result, cfg )
				if decision == 'apply' then nApplied = nApplied + 1 else nReview = nReview + 1 end
				lines[ #lines + 1 ] = line
			end
		end
	end

	-- Non-modal: the re-tagged keywords are visible in the Keyword List; a brief bezel
	-- is enough (no annoying summary modal).
	LrDialogs.showBezel( string.format( 'Re-parsed %d tab%s — tagged %d, review %d%s',
		#tabs, #tabs == 1 and '' or 's', nApplied, nReview,
		nUnmatched > 0 and ( ', unmatched ' .. nUnmatched ) or '' ), 4 )
end

return M
