--[[----------------------------------------------------------------------------
burst-accuracy.lua — the offline clustering-accuracy gate for burst detection.

Runs the REAL helper (hash mode) over the labelled burst corpus
(test/plugin/fixtures/burst-corpus/: 256 px frames from real shoots +
manifest.lua ground truth), clusters through the REAL Burst.lua, and scores
pairwise against the labels. Deterministic, no network, runs in CI.

Gates (exit 1):
  * false-merge pairs MUST be 0 — a merge silently mis-tags photos.
  * predicted clusters <= 1.5x the truth clusters — false splits only cost
    an extra Lens read each, so the budget is on how many extra reads the
    detector charges, not on pair counts (pair counts grow quadratically
    with cluster size and punish one mid-burst split in a 20-frame pan out
    of all proportion to its cost).

Usage (from the repo root, after `just build` or with any compiled helper):
  lua build/burst-accuracy.lua --helper <path-to-lens-helper> [--sweep]
--sweep prints merges/splits per candidate threshold for BOTH planes, plus
the within/between distance margins — the data HAMMING_THRESHOLD and
LEVEL_THRESHOLD were chosen from.
------------------------------------------------------------------------------]]

package.path = table.concat( {
	'src/plugin/shared/?.lua', 'output/deps/?.lua', 'build/?.lua', package.path,
}, ';' )

local Burst = require 'Burst'
local json = require 'dkjson'

local CORPUS = 'test/plugin/fixtures/burst-corpus'

-- ── args ──────────────────────────────────────────────────────────────────────
local helperPath, sweep
do
	local i = 1
	while i <= #arg do
		if arg[ i ] == '--helper' then helperPath = arg[ i + 1 ]; i = i + 2
		elseif arg[ i ] == '--sweep' then sweep = true; i = i + 1
		elseif arg[ i ] == '--corpus' then CORPUS = arg[ i + 1 ]; i = i + 2
		else error( 'unknown argument: ' .. tostring( arg[ i ] ) ) end
	end
end
assert( helperPath, 'pass --helper <path-to-lens-helper>' )

local manifest = dofile( CORPUS .. '/manifest.lua' )
assert( type( manifest ) == 'table' and #manifest.sequences > 0, 'empty corpus manifest' )

-- ── hash every corpus frame with ONE real helper invocation ──────────────────
local allFiles, owners = {}, {}
for _, seq in ipairs( manifest.sequences ) do
	for _, fr in ipairs( seq.frames ) do
		allFiles[ #allFiles + 1 ] = CORPUS .. '/' .. fr.file
		owners[ #owners + 1 ] = fr
	end
end

local listPath = os.tmpname()
do
	local f = assert( io.open( listPath, 'wb' ) )
	f:write( table.concat( allFiles, '\n' ) .. '\n' )
	f:close()
end
local cmd = string.format( "LENS_HASH=1 LENS_HASH_LIST='%s' '%s' hash 2>/dev/null",
	listPath, helperPath )
local pipe = assert( io.popen( cmd ) )
local out = pipe:read( '*a' )
pipe:close()
os.remove( listPath )

local decoded = json.decode( out )
assert( type( decoded ) == 'table' and decoded.ok, 'helper hash mode failed: ' .. tostring( out ) )
for i, fr in ipairs( owners ) do
	local h = decoded.hashes and decoded.hashes[ i ]
	assert( type( h ) == 'string', 'no fingerprint for corpus frame ' .. fr.file .. ' (bad image?)' )
	fr.hash = h
end

-- ── truth bookkeeping ─────────────────────────────────────────────────────────
local nFrames, truthClusters = #owners, 0
do
	local seen = {}
	for _, seq in ipairs( manifest.sequences ) do
		for _, fr in ipairs( seq.frames ) do
			local key = seq.name .. '/' .. fr.cluster
			if not seen[ key ] then seen[ key ] = true; truthClusters = truthClusters + 1 end
		end
	end
end

-- ── score one full corpus pass at the current thresholds ─────────────────────
local function score()
	local sameTruth, falseMerges, falseSplits, predictedClusters = 0, 0, 0, 0
	local mergeDetails = {}
	for _, seq in ipairs( manifest.sequences ) do
		local frames = {}
		for i, fr in ipairs( seq.frames ) do
			frames[ i ] = { id = i, t = fr.t, hash = fr.hash, serial = fr.serial }
		end
		local clusters = Burst.cluster( frames, { gapSeconds = manifest.gapSeconds or 1 } )
		predictedClusters = predictedClusters + #clusters
		local predicted = {}
		for ci, cl in ipairs( clusters ) do
			for _, id in ipairs( cl ) do predicted[ id ] = ci end
		end
		for a = 1, #seq.frames do
			for b = a + 1, #seq.frames do
				local truthSame = seq.frames[ a ].cluster == seq.frames[ b ].cluster
				local predSame = predicted[ a ] == predicted[ b ]
				if truthSame then
					sameTruth = sameTruth + 1
					if not predSame then falseSplits = falseSplits + 1 end
				elseif predSame then
					falseMerges = falseMerges + 1
					mergeDetails[ #mergeDetails + 1 ] = string.format( '%s: %s | %s',
						seq.name, seq.frames[ a ].file, seq.frames[ b ].file )
				end
			end
		end
	end
	return sameTruth, falseMerges, falseSplits, predictedClusters, mergeDetails
end

-- ── the margin data: adjacent distances within vs across truth clusters ──────
local function margins( dist )
	local within, boundary = {}, {}
	for _, seq in ipairs( manifest.sequences ) do
		for i = 2, #seq.frames do
			local a, b = seq.frames[ i - 1 ], seq.frames[ i ]
			local d = dist( a.hash, b.hash )
			if a.cluster == b.cluster then
				within[ #within + 1 ] = d
			else
				boundary[ #boundary + 1 ] = d
			end
		end
	end
	table.sort( within ); table.sort( boundary )
	local function pct( t, p )
		if #t == 0 then return '-' end
		return t[ math.max( 1, math.ceil( #t * p ) ) ]
	end
	return within, boundary, pct
end

print( string.format( 'burst corpus: %d sequences, %d frames, %d truth clusters',
	#manifest.sequences, nFrames, truthClusters ) )

if sweep then
	local savedH, savedT = Burst.HAMMING_THRESHOLD, Burst.LEVEL_THRESHOLD
	print( '\n  gradient plane (level fixed at ' .. savedT .. '):' )
	print( '   H   merges  splits  clusters' )
	for h = 8, 28, 4 do
		Burst.HAMMING_THRESHOLD = h
		local _, fm, fs, pc = score()
		print( string.format( '  %2d   %6d  %6d  %8d%s', h, fm, fs, pc,
			h == savedH and '   <- HAMMING_THRESHOLD' or '' ) )
	end
	Burst.HAMMING_THRESHOLD = savedH
	print( '\n  level plane (gradient fixed at ' .. savedH .. '):' )
	print( '   T   merges  splits  clusters' )
	for l = 8, 28, 4 do
		Burst.LEVEL_THRESHOLD = l
		local _, fm, fs, pc = score()
		print( string.format( '  %2d   %6d  %6d  %8d%s', l, fm, fs, pc,
			l == savedT and '   <- LEVEL_THRESHOLD' or '' ) )
	end
	Burst.LEVEL_THRESHOLD = savedT
	for name, dist in pairs( { gradient = Burst.hamming, level = Burst.levelDist } ) do
		local within, boundary, pct = margins( dist )
		print( string.format(
			'\n%s: within-adjacent n=%d p50=%s p95=%s max=%s | boundary n=%d min=%s p25=%s',
			name, #within, tostring( pct( within, .5 ) ), tostring( pct( within, .95 ) ),
			tostring( within[ #within ] ), #boundary, tostring( boundary[ 1 ] ),
			tostring( pct( boundary, .25 ) ) ) )
	end
	print( '' )
end

local sameTruth, falseMerges, falseSplits, predictedClusters, mergeDetails = score()
print( string.format(
	'H=%d T=%d: %d predicted clusters (truth %d) | same-cluster pairs %d | false merges %d | false splits %d (%.1f%%)',
	Burst.HAMMING_THRESHOLD, Burst.LEVEL_THRESHOLD, predictedClusters, truthClusters,
	sameTruth, falseMerges, falseSplits,
	sameTruth > 0 and ( 100 * falseSplits / sameTruth ) or 0 ) )

local failed = false
if falseMerges > 0 then
	print( 'FAIL: false merges are never acceptable (they silently mis-tag photos):' )
	for _, d in ipairs( mergeDetails ) do print( '  ' .. d ) end
	failed = true
end
if predictedClusters > truthClusters * 1.5 then
	print( string.format( 'FAIL: %d predicted clusters exceeds the 1.5x budget over %d truth clusters',
		predictedClusters, truthClusters ) )
	failed = true
end
if failed then os.exit( 1 ) end
print( 'OK' )
