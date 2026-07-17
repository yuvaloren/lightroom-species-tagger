require 'support.fixtures'
local Burst = require 'Burst'

-- Fingerprint builder: '<16-hex dHash>:<144-hex levels>' with a uniform level
-- plane, so level distance between two builds is exactly |levelA - levelB|.
local function fp( dhash, level )
	return dhash .. ':' .. string.rep( string.format( '%02x', level or 128 ), 72 )
end

-- dHash segments with EXACT, known Hamming distances from a base of all
-- zeros ('f' nibble = 4 bits, '1' nibble = 1 bit).
local D0 = '0000000000000000'
local D2 = '0000000000000003' -- 2 bits from D0
local D64 = 'ffffffffffffffff' -- 64 bits from D0
local D_AT = '00000000000fffff' -- 20 bits from D0 (== HAMMING_THRESHOLD)
local D_PAST = '00000000001fffff' -- 21 bits from D0

local ZERO = fp( D0 )
local NEAR = fp( D2 )
local FAR = fp( D64 )

describe( 'Burst.hamming (gradient plane)', function()
	it( 'computes exact distances', function()
		assert.equal( 0, Burst.hamming( ZERO, ZERO ) )
		assert.equal( 2, Burst.hamming( ZERO, NEAR ) )
		assert.equal( 20, Burst.hamming( ZERO, fp( D_AT ) ) )
		assert.equal( 21, Burst.hamming( ZERO, fp( D_PAST ) ) )
		assert.equal( 64, Burst.hamming( ZERO, FAR ) )
	end )
	it( 'is symmetric', function()
		assert.equal( Burst.hamming( NEAR, FAR ), Burst.hamming( FAR, NEAR ) )
	end )
	it( 'accepts upper-case hex and a bare dHash without a level plane', function()
		assert.equal( 64, Burst.hamming( ZERO, 'FFFFFFFFFFFFFFFF' ) )
		assert.equal( 2, Burst.hamming( D0, D2 ) )
	end )
	it( 'treats malformed or missing fingerprints as maximally distant (split, never merge)', function()
		assert.equal( 64, Burst.hamming( nil, ZERO ) )
		assert.equal( 64, Burst.hamming( 'abc', ZERO ) )
		assert.equal( 64, Burst.hamming( D0 .. ':abc', ZERO ) ) -- truncated level plane
		assert.equal( 64, Burst.hamming( 'zzzzzzzzzzzzzzzz', ZERO ) )
		assert.equal( 64, Burst.hamming( 12345, ZERO ) )
	end )
end )

describe( 'Burst.levelDist (level plane)', function()
	it( 'is the mean absolute per-cell difference', function()
		assert.equal( 0, Burst.levelDist( fp( D0, 100 ), fp( D0, 100 ) ) )
		assert.equal( 20, Burst.levelDist( fp( D0, 100 ), fp( D0, 120 ) ) )
		assert.equal( 255, Burst.levelDist( fp( D0, 0 ), fp( D0, 255 ) ) )
	end )
	it( 'treats a missing or malformed level plane as maximally distant', function()
		assert.equal( 256, Burst.levelDist( D0, fp( D0 ) ) ) -- bare dHash: no levels
		assert.equal( 256, Burst.levelDist( nil, fp( D0 ) ) )
		assert.equal( 256, Burst.levelDist( D0 .. ':1234', fp( D0 ) ) )
	end )
end )

-- frame( id, t, hash, serial ) — terse builder
local function frame( id, t, hash, serial )
	return { id = id, t = t, hash = hash, serial = serial }
end

describe( 'Burst.cluster', function()
	it( 'chains a simple burst into one cluster', function()
		local c = Burst.cluster( {
			frame( 'a', 0.0, ZERO ), frame( 'b', 0.4, NEAR ), frame( 'c', 0.8, ZERO ),
			frame( 'd', 1.2, NEAR ), frame( 'e', 1.6, ZERO ),
		}, { gapSeconds = 1 } )
		assert.same( { { 'a', 'b', 'c', 'd', 'e' } }, c )
	end )

	it( 'joins at exactly the gap and splits just past it', function()
		assert.same( { { 'a', 'b' } },
			Burst.cluster( { frame( 'a', 0, ZERO ), frame( 'b', 1.0, ZERO ) }, { gapSeconds = 1 } ) )
		assert.same( { { 'a' }, { 'b' } },
			Burst.cluster( { frame( 'a', 0, ZERO ), frame( 'b', 1.1, ZERO ) }, { gapSeconds = 1 } ) )
	end )

	it( 'defaults the gap to 1 second when cfg is missing', function()
		assert.same( { { 'a', 'b' }, { 'c' } },
			Burst.cluster( { frame( 'a', 0, ZERO ), frame( 'b', 1.0, ZERO ), frame( 'c', 2.5, ZERO ) } ) )
	end )

	it( 'joins at exactly the Hamming threshold and splits one bit past it', function()
		assert.same( { { 'a', 'b' } },
			Burst.cluster( { frame( 'a', 0, ZERO ), frame( 'b', 0.5, fp( D_AT ) ) }, { gapSeconds = 1 } ) )
		assert.same( { { 'a' }, { 'b' } },
			Burst.cluster( { frame( 'a', 0, ZERO ), frame( 'b', 0.5, fp( D_PAST ) ) }, { gapSeconds = 1 } ) )
	end )

	it( 'joins at exactly the level threshold and splits one step past it', function()
		assert.same( { { 'a', 'b' } },
			Burst.cluster( { frame( 'a', 0, fp( D0, 100 ) ), frame( 'b', 0.5, fp( D0, 120 ) ) },
				{ gapSeconds = 1 } ) )
		assert.same( { { 'a' }, { 'b' } },
			Burst.cluster( { frame( 'a', 0, fp( D0, 100 ) ), frame( 'b', 0.5, fp( D0, 121 ) ) },
				{ gapSeconds = 1 } ) )
	end )

	it( 'splits two different flat scenes on the level plane alone (the sky/sand case)', function()
		-- Both frames are featureless: identical (deadbanded) gradient hashes.
		-- Only the absolute level plane can tell blue sky from pale sand — the
		-- corpus measured such a pair at gradient distance 5 but level 40.8.
		local sky = fp( D0, 90 )
		local sand = fp( D0, 200 )
		assert.equal( 0, Burst.hamming( sky, sand ) )
		assert.same( { { 'a' }, { 'b' } },
			Burst.cluster( { frame( 'a', 0, sky ), frame( 'b', 0.5, sand ) }, { gapSeconds = 1 } ) )
	end )

	it( 'splits when the subject changes even one second apart (the gradient gate)', function()
		local c = Burst.cluster( {
			frame( 'g1', 0.0, ZERO ), frame( 'g2', 0.5, NEAR ),
			frame( 'h1', 1.0, FAR ), frame( 'h2', 1.5, FAR ),
		}, { gapSeconds = 1 } )
		assert.same( { { 'g1', 'g2' }, { 'h1', 'h2' } }, c )
	end )

	it( 'never merges two different present serials, but missing serials do not split', function()
		assert.same( { { 'a' }, { 'b' } },
			Burst.cluster( { frame( 'a', 0, ZERO, 'CAM1' ), frame( 'b', 0.5, ZERO, 'CAM2' ) },
				{ gapSeconds = 1 } ) )
		assert.same( { { 'a', 'b' } },
			Burst.cluster( { frame( 'a', 0, ZERO, 'CAM1' ), frame( 'b', 0.5, ZERO ) },
				{ gapSeconds = 1 } ) )
		assert.same( { { 'a', 'b' } },
			Burst.cluster( { frame( 'a', 0, ZERO ), frame( 'b', 0.5, ZERO ) }, { gapSeconds = 1 } ) )
	end )

	it( 'chains a long burst across a span far beyond the gap (chain, not window)', function()
		local frames = {}
		for i = 1, 30 do frames[ i ] = frame( i, ( i - 1 ) * 0.7, ( i % 2 == 0 ) and NEAR or ZERO ) end
		local c = Burst.cluster( frames, { gapSeconds = 1 } )
		assert.equal( 1, #c )
		assert.equal( 30, #c[ 1 ] )
	end )

	it( 'degrades frames without capture time to trailing singletons in input order', function()
		local c = Burst.cluster( {
			frame( 'x', nil, ZERO ), frame( 'a', 0, ZERO ), frame( 'b', 0.5, ZERO ), frame( 'y' ),
		}, { gapSeconds = 1 } )
		assert.same( { { 'a', 'b' }, { 'x' }, { 'y' } }, c )
	end )

	it( 'a frame whose fingerprint failed becomes a singleton AND breaks the chain (accepted false split)', function()
		-- b's render/hash failed: a|b and b|c both fail the identity gate, so the
		-- burst a..c costs one extra Lens read. Splits are always preferred to merges.
		local c = Burst.cluster( {
			frame( 'a', 0, ZERO ), frame( 'b', 0.5, nil ), frame( 'c', 1.0, ZERO ),
		}, { gapSeconds = 1 } )
		assert.same( { { 'a' }, { 'b' }, { 'c' } }, c )
	end )

	it( 'orders clusters by earliest capture time with members in capture order', function()
		local c = Burst.cluster( {
			frame( 'late', 100, ZERO ), frame( 'b', 0.5, NEAR ), frame( 'a', 0, ZERO ),
		}, { gapSeconds = 1 } )
		assert.same( { { 'a', 'b' }, { 'late' } }, c )
	end )

	it( 'is deterministic: the same input always clusters the same way', function()
		local function build()
			return {
				frame( 'a1', 0.0, ZERO ), frame( 'a2', 0.5, NEAR ), frame( 'a3', 1.0, ZERO ),
				frame( 'b1', 10.0, FAR ), frame( 'b2', 10.5, FAR ),
				frame( 's1', 30.0, fp( D_AT ) ),
				frame( 'c1', 40.0, ZERO, 'CAM1' ), frame( 'c2', 40.0, NEAR, 'CAM2' ),
			}
		end
		local expected = Burst.cluster( build(), { gapSeconds = 1 } )
		for _ = 1, 5 do
			assert.same( expected, Burst.cluster( build(), { gapSeconds = 1 } ) )
		end
	end )

	it( 'breaks same-second ties by input order (grid order IS capture order)', function()
		-- a 12 fps camera writes many frames into one EXIF second; the caller's
		-- order is the only faithful within-second sequence, so it must be kept
		local c = Burst.cluster( {
			frame( 'f1', 5, ZERO ), frame( 'f2', 5, NEAR ), frame( 'f3', 5, ZERO ),
			frame( 'f4', 6, NEAR ),
		}, { gapSeconds = 1 } )
		assert.same( { { 'f1', 'f2', 'f3', 'f4' } }, c )
	end )

	it( 'returns an empty list for an empty selection', function()
		assert.same( {}, Burst.cluster( {}, { gapSeconds = 1 } ) )
	end )
end )
