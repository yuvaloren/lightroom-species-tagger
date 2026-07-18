--[[----------------------------------------------------------------------------
TagRun.lua
The burst-aware assist ORCHESTRATION, factored out of TagSpecies.lua so it can be
unit-tested without Lightroom. Pure: no Lr* imports, no I/O — every effect is
injected. TagSpecies.lua builds the real effects (render, GBIF resolve, catalog
write, the Lens helper) and calls TagRun.run; the specs pass fakes.

This exists because the whole point of the tool — "one identification per burst,
and the run BLOCKS on your Tag" — had no automated coverage: a regression where
the assist loop fired per-frame or never waited would (and did) reach the user.
The invariants below are what the spec pins:
  * `tag` is called ONCE per cluster, on the cluster's representative frame —
    never once per photo;
  * the loop is synchronous on `tag` (it consumes the return value before moving
    on — Skip/error/timeout leave the WHOLE cluster untouched);
  * a tagged cluster's keywords are applied to EVERY member, in one write.

run( deps ) -> summary
  deps.items        array (selection order) of
                    { id, photo, file = <path|false>, err, t, serial, label }
                    file=false / err set means that photo's render failed.
  deps.cfg          { burstDetect, burstGapSeconds, keywordMode, includeOnExport }
  deps.cluster      function(frames, {gapSeconds}) -> clusters (inject Burst.cluster)
  deps.hashFiles    function(files[]) -> hashes[]|nil  (parallel to files; each a
                    fingerprint string or false). Only called when burst detection
                    is on and there is more than one item. nil => no grouping.
  deps.tag          function(file, pos) -> name|nil, errKind   BLOCKS on the user.
  deps.cancelled    the errKind value `tag` returns for a user Skip (not an error).
  deps.resolve      function(name) -> { ok, taxon = { scientificName, commonName }, plan }
  deps.applyCluster function(memberItems[], plan) -> nil  (caller wraps ONE undo).
  deps.onClusterDone optional function(memberItems[]) -> nil  (e.g. free temp files).
  deps.progress     optional { canceled()->bool, caption(str), portion(done,total) }
  deps.log          optional { info(str), warn(str) }

returns { applied, skipped, clusters, tagFiles = { file, … }, lines = { … } }
  tagFiles is the ordered list of files actually handed to `tag` — its length is
  the number of Lens reads, which MUST equal the cluster count, not the photo
  count. The spec asserts exactly that.
------------------------------------------------------------------------------]]

local M = {}

local function noop() end
local function safeProgress( p )
	p = p or {}
	return {
		canceled = p.canceled or function() return false end,
		caption = p.caption or noop,
		portion = p.portion or noop,
	}
end
local function safeLog( l )
	l = l or {}
	return { info = l.info or noop, warn = l.warn or noop }
end

local function moreSuffix( n )
	return n > 1 and ( ' +' .. ( n - 1 ) .. ' more' ) or ''
end

function M.run( deps )
	local items = deps.items or {}
	local cfg = deps.cfg or {}
	local progress = safeProgress( deps.progress )
	local log = safeLog( deps.log )

	-- ── frames + fingerprints ────────────────────────────────────────────────
	local frames = {}
	for i, it in ipairs( items ) do
		frames[ i ] = { id = i, t = it.t, serial = it.serial }
	end
	if cfg.burstDetect and #items > 1 and not progress.canceled() then
		progress.caption( 'Detecting bursts…' )
		local files = {}
		for i, it in ipairs( items ) do files[ i ] = it.file or '' end
		local hashes = deps.hashFiles and deps.hashFiles( files ) or nil
		if hashes then
			for i = 1, #items do
				if hashes[ i ] then frames[ i ].hash = hashes[ i ] end
			end
		else
			-- no fingerprints -> every frame stays a singleton (per-photo behavior)
			log.warn( 'burst hashing unavailable — tagging photo by photo' )
		end
	end

	-- ── clusters ──────────────────────────────────────────────────────────────
	local clusters
	if cfg.burstDetect then
		clusters = deps.cluster( frames, { gapSeconds = cfg.burstGapSeconds } )
		local plan = {}
		for k, cl in ipairs( clusters ) do
			local names = {}
			for _, i in ipairs( cl ) do names[ #names + 1 ] = items[ i ].label or ( 'photo ' .. i ) end
			plan[ #plan + 1 ] = string.format( '  burst %d (%d photo%s): %s',
				k, #cl, #cl == 1 and '' or 's', table.concat( names, ' ' ) )
		end
		log.info( 'burst plan — ' .. #clusters .. ' group(s) from ' .. #items .. ' photo(s)\n'
			.. table.concat( plan, '\n' ) )
	else
		clusters = {}
		for i = 1, #items do clusters[ i ] = { i } end
	end

	-- ── assist loop: ONE tag per cluster, applied to every member ─────────────
	local applied, skipped = 0, 0
	local lines, tagFiles = {}, {}

	for k, cl in ipairs( clusters ) do
		if progress.canceled() then break end
		progress.portion( k - 1, #clusters )
		local rep = items[ cl[ 1 ] ] -- representative: first frame by capture time
		local repLabel = rep.label or ( 'photo ' .. cl[ 1 ] )
		progress.caption( repLabel )

		if not rep.file then
			skipped = skipped + #cl
			lines[ #lines + 1 ] = '✗ ' .. repLabel .. moreSuffix( #cl ) .. ' — ' .. tostring( rep.err )
			log.warn( 'render failed: ' .. tostring( rep.err ) )
		else
			local pos = ( #cl > 1 )
				and string.format( 'Burst %d of %d — %d photos', k, #clusters, #cl )
				or string.format( 'Photo %d of %d', k, #clusters )

			-- BLOCKS until the user Tags a selection (or Skips / times out).
			tagFiles[ #tagFiles + 1 ] = rep.file
			local name, aerr = deps.tag( rep.file, pos )

			if not name then
				skipped = skipped + #cl
				local why = ( aerr == deps.cancelled ) and 'skipped'
					or ( 'not tagged (' .. tostring( aerr ) .. ')' )
				lines[ #lines + 1 ] = '⊘ ' .. repLabel .. moreSuffix( #cl ) .. ' — ' .. why
				if aerr ~= deps.cancelled then log.warn( 'assist: ' .. tostring( aerr ) ) end
			else
				local res = deps.resolve( name )
				if res and res.ok then
					local members = {}
					for _, i in ipairs( cl ) do members[ #members + 1 ] = items[ i ] end
					deps.applyCluster( members, res.plan )
					applied = applied + #cl
					lines[ #lines + 1 ] = string.format( '✓ %s%s — %s (%s)', repLabel, moreSuffix( #cl ),
						res.taxon.commonName or res.taxon.scientificName, res.taxon.scientificName )
				else
					skipped = skipped + #cl
					lines[ #lines + 1 ] = '⊘ ' .. repLabel .. moreSuffix( #cl ) ..
						' — “' .. tostring( name ) .. '” not found in GBIF'
				end
			end
		end

		if deps.onClusterDone then
			local members = {}
			for _, i in ipairs( cl ) do members[ #members + 1 ] = items[ i ] end
			deps.onClusterDone( members )
		end
	end

	return {
		applied = applied,
		skipped = skipped,
		clusters = #clusters,
		tagFiles = tagFiles,
		lines = lines,
	}
end

return M
