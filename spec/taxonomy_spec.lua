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
		-- first English one. (When the image search surfaces a common name, Identify
		-- prefers that instead — see identify_spec.)
		assert.equal( "Cyane's octopus", T.pickVernacular( d ) )
	end )

	it( 'pickSearchResult chooses the backbone species matching the common name', function()
		local d = assert( fixtures.loadJson( 'gbif/search_lei_triggerfish.json' ) )
		local r = T.pickSearchResult( d, 'Lei triggerfish' )
		assert.equal( 'Sufflamen bursa', r.canonicalName )
		assert.equal( 2407198, r.usageKey )
		assert.equal( 'Lei triggerfish', r.commonName )
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
end )
