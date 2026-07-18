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
    on): the next identification page is shown ONLY after the user Tags or Skips
    the current one;
  * a non-decision — the user closed the Chrome window, the wait timed out, or
    the helper failed — ABORTS the whole run rather than silently advancing;
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
  deps.aborted      the errKind value `tag` returns when the user closed the Lens
                    window (or the wait timed out) — a non-decision that stops the run.
  deps.resolve      function(name) -> { ok, taxon = { scientificName, commonName }, plan }
  deps.applyCluster function(memberItems[], plan) -> nil  (caller wraps ONE undo).
  deps.closeWindow  optional function() -> nil  (shut the reused Lens window). Called
                    ONCE at the end, and ONLY on a clean finish — never on an abort, so a
                    window the user is still reading (or a page that failed) is left open.
  deps.onClusterDone optional function(memberItems[]) -> nil  (e.g. free temp files).
  deps.progress     optional { canceled()->bool, caption(str), portion(done,total) }
  deps.log          optional { info(str), warn(str) }

returns { applied, skipped, clusters, tagFiles = { file, … }, lines = { … },
          aborted = <bool>, abortReason = <string|nil> }
  tagFiles is the ordered list of files actually handed to `tag` — its length is
  the number of Lens reads, which MUST equal the cluster count, not the photo
  count. The spec asserts exactly that. `aborted` is true when a non-decision
  stopped the run early (clusters after the abort point are left untouched).
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
	local aborted, abortReason = false, nil

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

			-- BLOCKS until the user Tags a selection, Skips, closes the window, or
			-- the wait times out.
			tagFiles[ #tagFiles + 1 ] = rep.file
			local name, aerr = deps.tag( rep.file, pos )

			if name then
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
			elseif aerr == deps.cancelled then
				-- Skip: this cluster is untouched, but the run continues.
				skipped = skipped + #cl
				lines[ #lines + 1 ] = '⊘ ' .. repLabel .. moreSuffix( #cl ) .. ' — skipped'
			else
				-- No decision was made (window closed, timed out, or the helper
				-- failed). Only a Tag or Skip may advance, so STOP the whole run
				-- rather than silently show the next cluster's page.
				abortReason = ( aerr == deps.aborted ) and 'the Chrome window was closed'
					or ( 'the identifier failed (' .. tostring( aerr ) .. ')' )
				lines[ #lines + 1 ] = '■ ' .. repLabel .. moreSuffix( #cl ) .. ' — run stopped: ' .. abortReason
				log.warn( 'assist run stopped: ' .. abortReason )
				aborted = true
			end
		end

		if aborted then break end

		if deps.onClusterDone then
			local members = {}
			for _, i in ipairs( cl ) do members[ #members + 1 ] = items[ i ] end
			deps.onClusterDone( members )
		end
	end

	-- Close the reused Lens window ONLY on a clean finish. On an abort (the user
	-- closed the window, or a photo could not be identified) leave it open so they
	-- can read what's there and act — never yank it away before a decision.
	if deps.closeWindow and not aborted then deps.closeWindow() end

	return {
		applied = applied,
		skipped = skipped,
		clusters = #clusters,
		tagFiles = tagFiles,
		lines = lines,
		aborted = aborted,
		abortReason = abortReason,
	}
end

return M
