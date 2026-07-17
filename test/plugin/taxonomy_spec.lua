require 'support.fixtures'
local Taxonomy = require 'Taxonomy'
local fixtures = require 'support.fixtures'
local fakeHttp = require 'support.fake_http'
local T = Taxonomy._test

describe( 'Taxonomy pure parsers', function()
	it( 'normalizeMatch maps the GBIF fields we use', function()
		local d = assert( fixtures.loadJson( 'gbif/match_octopus_cyanea.json' ) )
		local t = T.normalizeMatch( d )
		assert.equal( 2289535, t.usageKey )
		assert.equal( 'Octopus cyanea', t.scientificName )
		assert.equal( 'Octopodidae', t.family )
		assert.equal( 'EXACT', t.matchType )
	end )

	it( 'acceptable gates on matchType, confidence and rank', function()
		assert.is_true( T.acceptable { matchType = 'EXACT', rank = 'SPECIES' } )
		assert.is_true( T.acceptable { matchType = 'FUZZY', rank = 'SPECIES', confidence = 96 } )
		assert.is_false( T.acceptable { matchType = 'FUZZY', rank = 'SPECIES', confidence = 80 } )
		assert.is_false( T.acceptable { matchType = 'NONE' } )
		assert.is_false( T.acceptable { matchType = 'EXACT', rank = 'FAMILY' } )
	end )

	it( 'pickVernacular returns an English name', function()
		local d = assert( fixtures.loadJson( 'gbif/vern_2289535.json' ) )
		-- GBIF marks none of this taxon's English names "preferred", so we take the
		-- first English one.
		assert.equal( "Cyane's octopus", T.pickVernacular( d ) )
	end )

	it( 'pickSearchResult chooses the backbone species matching the common name', function()
		local d = assert( fixtures.loadJson( 'gbif/search_lei_triggerfish.json' ) )
		local r = T.pickSearchResult( d, 'Lei triggerfish' )
		assert.equal( 'Sufflamen bursa', r.canonicalName )
		assert.equal( 2407198, r.usageKey )
		assert.equal( 'Lei triggerfish', r.commonName )
	end )

	it( 'normalizeMatch follows a SYNONYM to its accepted key + species', function()
		-- GBIF returns the synonym's own usageKey but the accepted binomial in `species`
		-- and the accepted key in `acceptedUsageKey`; we canonicalize to the accepted taxon.
		local t = T.normalizeMatch {
			usageKey = 111, matchType = 'EXACT', rank = 'SPECIES', status = 'SYNONYM',
			acceptedUsageKey = 222, canonicalName = 'Oldname vetus', species = 'Newname novus',
		}
		assert.equal( 222, t.usageKey )
		assert.equal( 'Newname novus', t.scientificName )
	end )

	it( 'acceptable admits GENUS and SUBSPECIES ranks, and the FUZZY floor is 92', function()
		assert.is_true( T.acceptable { matchType = 'EXACT', rank = 'GENUS' } )
		assert.is_true( T.acceptable { matchType = 'EXACT', rank = 'SUBSPECIES' } )
		assert.is_true( T.acceptable { matchType = 'FUZZY', rank = 'SPECIES', confidence = 92 } )
		assert.is_false( T.acceptable { matchType = 'FUZZY', rank = 'SPECIES', confidence = 91 } )
	end )

	it( 'pickVernacular prefers a GBIF "preferred" English name over the first', function()
		local d = { results = {
			{ language = 'eng', vernacularName = 'First name' },
			{ language = 'eng', vernacularName = 'Preferred name', preferred = true },
		} }
		assert.equal( 'Preferred name', T.pickVernacular( d ) )
	end )

	it( 'pickSearchResult rejects a result below the minimum signal (score < 3)', function()
		-- SPECIES + SCIENTIFIC nameType (+1) + a bare nubKey (+1) = 2; not ACCEPTED, not
		-- backbone, no vernacular agreement -> below the >=3 floor -> rejected.
		local d = { results = { {
			rank = 'SPECIES', canonicalName = 'Genus species', nubKey = 999,
			taxonomicStatus = 'DOUBTFUL', nameType = 'SCIENTIFIC',
		} } }
		assert.is_nil( T.pickSearchResult( d, 'whatever' ) )
	end )
end )

describe( 'Taxonomy httpGetJson caching (via matchScientific)', function()
	local function countingHttp( body )
		local calls = 0
		return {
			count = function() return calls end,
			get = function() calls = calls + 1; return body end,
		}
	end

	it( 'caches a decoded response so a repeat URL is not re-fetched', function()
		local http = countingHttp(
			'{"usageKey":1,"matchType":"EXACT","rank":"SPECIES","canonicalName":"Aaa bbb","species":"Aaa bbb"}' )
		local deps = { http = http, cache = {} }
		assert.is_not_nil( Taxonomy.matchScientific( 'Aaa bbb', deps ) )
		Taxonomy.matchScientific( 'Aaa bbb', deps )
		assert.equal( 1, http.count() )
	end )

	it( 'memoizes a miss as false so it is not re-fetched', function()
		local http = countingHttp( nil ) -- empty body -> decoded nil -> cache stores false
		local deps = { http = http, cache = {} }
		assert.is_nil( Taxonomy.matchScientific( 'Zzz zzz', deps ) )
		assert.is_nil( Taxonomy.matchScientific( 'Zzz zzz', deps ) )
		assert.equal( 1, http.count() )
	end )
end )

describe( 'Taxonomy.resolve (offline, fixture-backed)', function()
	local deps
	before_each( function() deps = { http = fakeHttp.new(), cache = {} } end )

	it( 'resolves a scientific binomial with vernacular + hierarchy', function()
		local t = Taxonomy.resolve( { name = 'Octopus cyanea', kind = 'scientific' }, deps )
		assert.equal( 'Octopus cyanea', t.scientificName )
		assert.equal( 2289535, t.usageKey )
		assert.equal( 'Octopodidae', t.family )
		assert.equal( "Cyane's octopus", t.commonName ) -- first English name (no GBIF "preferred")
	end )

	it( 'resolves a common name to the accepted species', function()
		local t = Taxonomy.resolve( { name = 'Lei triggerfish', kind = 'common' }, deps )
		assert.equal( 'Sufflamen bursa', t.scientificName )
		assert.equal( 2407198, t.usageKey )
		assert.equal( 'Lei triggerfish', t.commonName )
	end )

	it( 'rejects a junk binomial (GBIF returns NONE)', function()
		assert.is_nil( Taxonomy.resolve( { name = 'Lei triggerfish', kind = 'scientific' }, deps ) )
	end )

	it( 'with fetchVernacular=false leaves commonName unset for a bare scientific match', function()
		local t = Taxonomy.resolve( { name = 'Sufflamen bursa', kind = 'scientific' }, deps,
			{ fetchVernacular = false } )
		assert.equal( 'Sufflamen bursa', t.scientificName )
		assert.is_nil( t.commonName )
	end )
end )
