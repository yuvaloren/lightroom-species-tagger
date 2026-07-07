require 'support.fixtures'
local SelectedName = require 'SelectedName'
local fakeHttp = require 'support.fake_http'

describe( 'SelectedName._test.looksBinomial (channel hint only)', function()
	local looksBinomial = SelectedName._test.looksBinomial
	it( 'is true for a Genus species form', function()
		assert.is_true( looksBinomial( 'Octopus cyanea' ) )
	end )
	it( 'is false for a 3-word phrase', function()
		assert.is_false( looksBinomial( 'wild turkey chick' ) )
	end )
	it( 'is false for two lowercase words', function()
		assert.is_false( looksBinomial( 'wild turkey' ) )
	end )
end )

describe( 'SelectedName._test.clean', function()
	local clean = SelectedName._test.clean
	it( 'strips surrounding quotes and a trailing parenthetical', function()
		assert.equal( 'Octopus cyanea', clean( '  "Octopus cyanea (day octopus)"  ' ) )
	end )
	it( 'folds curly quotes without byte-class corruption', function()
		assert.equal( 'Meleagris gallopavo', clean( '\226\128\156Meleagris gallopavo\226\128\157' ) )
	end )
	it( 'returns empty for whitespace-only text', function()
		assert.equal( '', clean( '   \n  ' ) )
	end )
end )

describe( 'SelectedName.resolve (offline, fixture-backed)', function()
	local deps
	before_each( function() deps = { http = fakeHttp.new(), cache = {} } end )

	it( 'resolves a highlighted binomial to a taxon + flat keyword plan', function()
		local r = SelectedName.resolve( 'Octopus cyanea', deps, { keywordMode = 'flat' } )
		assert.is_true( r.ok )
		assert.equal( 'scientific', r.kind )
		assert.equal( 'Octopus cyanea', r.taxon.scientificName )
		assert.equal( "Cyane's octopus", r.taxon.commonName )
		local attached = {}
		for _, n in ipairs( r.plan.attachNames ) do attached[ n ] = true end
		assert.is_true( attached[ 'Octopus cyanea' ] )
	end )

	it( 'resolves a highlighted common name to the accepted species', function()
		local r = SelectedName.resolve( 'Lei triggerfish', deps )
		assert.is_true( r.ok )
		assert.equal( 'common', r.kind )
		assert.equal( 'Sufflamen bursa', r.taxon.scientificName )
	end )

	it( 'reports not-found when GBIF does not recognise the selection', function()
		local r = SelectedName.resolve( 'Related searches', deps )
		assert.is_false( r.ok )
	end )

	it( 'reports empty for a blank selection', function()
		assert.is_false( SelectedName.resolve( '   ', deps ).ok )
	end )
end )
