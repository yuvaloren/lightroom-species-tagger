--[[----------------------------------------------------------------------------
Burst.lua
The burst-detection policy: cluster a selection of frames so one Lens
identification can tag a whole burst. Pure (no Lr* imports, no I/O) — the
pixels were already reduced to fingerprints by the helper's hash mode
(src/helper/imghash/); this module only decides who groups with whom.

A fingerprint is '<16-hex dHash>:<144-hex cell levels>' — two complementary
planes over the same 9×8 grayscale grid:
  * the GRADIENT plane (deadbanded dHash) sees structure and ignores
    absolute brightness,
  * the LEVEL plane (per-cell mean luma) sees absolute brightness and holds
    steady while structure shifts during a pan.
Either plane alone fails on real bursts: gradients alone can't tell two
different low-texture scenes apart (a bird on blue sky and an iguana on pale
sand measured 5 bits apart on the corpus); levels alone can't absorb fast
subject motion. A merge must pass BOTH.

Gates, evaluated pairwise over the frames in capture order (see the design
doc, PhotoManagement docs/burst-detection-design):
  1. time chain: gap to the previous frame <= cfg.gapSeconds (chained, so a
     long burst spans freely as long as no single gap exceeds the limit),
  2. near-identity: gradient distance <= HAMMING_THRESHOLD AND level
     distance <= LEVEL_THRESHOLD,
  3. camera split: two PRESENT-but-different serials never merge.
Anything that can't prove it belongs (no capture time, no fingerprint)
degrades to a singleton — i.e. to the plugin's per-photo behavior.

Determinism: frames sort by capture time with INPUT ORDER as the tie-break.
Cameras write many frames per EXIF second (a 12 fps burst shares seconds), and
the caller's order (Lightroom's grid order — filename/capture sort, stable
across runs) is the only faithful within-second sequence available; a
content-derived tie-break was tried and measurably shredded real bursts by
chaining non-consecutive frames (see the corpus history in the design doc).
Same selection in -> same clusters out, every run.
------------------------------------------------------------------------------]]

local M = {}

-- Merge ceilings, owned by the accuracy corpus (`just burst-accuracy --sweep`
-- reprints the tables they were read off; the 2026-06-25 Galapagos corpus, 292
-- frames / 36 truth clusters, gap 1 s):
--   * merges stayed 0 at EVERY swept (H, T) combination;
--   * H: within-burst gradient distance p95 was 10, but fast pans (a
--     plunge-dive tracked across cliff-then-water) reach the 20s–30s — H=20
--     absorbs most of a pan while different-subject neighbors are protected
--     by the level plane;
--   * T: the nearest DIFFERENT-subject near-in-time pair sat at level
--     distance 40.8 (bird-on-sky | iguana-on-sand) and every pair below 20
--     was the same subject re-aimed — T=20 keeps an 11-point margin;
--   * result at (20, 20): 0 merges, 47 predicted clusters vs 36 ideal on 292
--     frames — 83% of Lens reads saved.
-- Not user settings.
M.HAMMING_THRESHOLD = 20
M.LEVEL_THRESHOLD = 20

-- 16×16 popcount-of-XOR table for hex nibbles, built once with plain
-- arithmetic (Lightroom's Lua 5.1 has no bit ops).
local NIBBLE_DIST = {}
for a = 0, 15 do
	NIBBLE_DIST[ a ] = {}
	for b = 0, 15 do
		local x, d = a, 0
		local y = b
		for _ = 1, 4 do
			if ( x % 2 ) ~= ( y % 2 ) then d = d + 1 end
			x = math.floor( x / 2 )
			y = math.floor( y / 2 )
		end
		NIBBLE_DIST[ a ][ b ] = d
	end
end

local HEXVAL = {}
for i = 0, 9 do HEXVAL[ tostring( i ) ] = i end
for i, c in ipairs { 'a', 'b', 'c', 'd', 'e', 'f' } do
	HEXVAL[ c ] = 9 + i
	HEXVAL[ c:upper() ] = 9 + i
end

-- Split a fingerprint into its planes; nil, nil when malformed. A bare 16-hex
-- dHash (no level plane) is accepted with levels = nil.
local function planes( fp )
	if type( fp ) ~= 'string' then return nil, nil end
	local d, l = fp:match( '^(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x):(%x+)$' )
	if d then
		if #l == 144 then return d, l end
		return nil, nil
	end
	if #fp == 16 and fp:match( '^%x+$' ) then return fp, nil end
	return nil, nil
end

-- Gradient-plane Hamming distance between two fingerprints. Malformed input
-- counts as maximally distant (64) — it can only ever split, never merge.
function M.hamming( a, b )
	local da, db = planes( a ), planes( b )
	if not da or not db then return 64 end
	local d = 0
	for i = 1, 16 do
		d = d + NIBBLE_DIST[ HEXVAL[ da:sub( i, i ) ] ][ HEXVAL[ db:sub( i, i ) ] ]
	end
	return d
end

-- Level-plane distance: mean absolute per-cell luma difference, 0..255 scale.
-- A missing or malformed level plane is maximally distant (256) — same
-- split-never-merge degradation as hamming.
function M.levelDist( a, b )
	local _, la = planes( a )
	local _, lb = planes( b )
	if not la or not lb then return 256 end
	local sum = 0
	for i = 1, 144, 2 do
		local va = HEXVAL[ la:sub( i, i ) ] * 16 + HEXVAL[ la:sub( i + 1, i + 1 ) ]
		local vb = HEXVAL[ lb:sub( i, i ) ] * 16 + HEXVAL[ lb:sub( i + 1, i + 1 ) ]
		sum = sum + math.abs( va - vb )
	end
	return sum / 72
end

-- cluster( frames, cfg ) -> { { id, id, … }, … }
--   frames: array of { id = <caller's handle>, t = <capture seconds|nil>,
--                      hash = <fingerprint|nil>, serial = <string|nil> }
--   cfg:    { gapSeconds = <number> } (missing -> 1)
-- Clusters are ordered by earliest capture time (untimed singletons last, in
-- input order); members are in capture order.
function M.cluster( frames, cfg )
	local gap = ( cfg and tonumber( cfg.gapSeconds ) ) or 1
	local timed, untimed = {}, {}
	for i, fr in ipairs( frames ) do
		if type( fr.t ) == 'number' then
			timed[ #timed + 1 ] = { fr = fr, idx = i }
		else
			untimed[ #untimed + 1 ] = fr
		end
	end
	table.sort( timed, function( x, y )
		if x.fr.t ~= y.fr.t then return x.fr.t < y.fr.t end
		return x.idx < y.idx -- same EXIF second: input (grid) order IS capture order
	end )

	local clusters, prev = {}, nil
	for _, e in ipairs( timed ) do
		local fr = e.fr
		local joins = prev ~= nil
			and ( fr.t - prev.t ) <= gap
			and M.hamming( fr.hash, prev.hash ) <= M.HAMMING_THRESHOLD
			and M.levelDist( fr.hash, prev.hash ) <= M.LEVEL_THRESHOLD
			and not ( fr.serial and prev.serial and fr.serial ~= prev.serial )
		if joins then
			local cur = clusters[ #clusters ]
			cur[ #cur + 1 ] = fr.id
		else
			clusters[ #clusters + 1 ] = { fr.id }
		end
		prev = fr
	end
	for _, fr in ipairs( untimed ) do
		clusters[ #clusters + 1 ] = { fr.id }
	end
	return clusters
end

return M
