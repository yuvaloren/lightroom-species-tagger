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
	it( 'applies curly-quote fold + surrounding-quote strip + paren strip together', function()
		-- whole selection wrapped in curly quotes, with a trailing common-name gloss
		assert.equal( 'Octopus cyanea',
			clean( '\226\128\156Octopus cyanea (day octopus)\226\128\157' ) )
	end )
	it( 'strips a closing quote that a trailing parenthetical had hidden', function()
		-- name quoted, then an UNquoted gloss: the closing quote is interior until the
		-- "(...)" is removed, so a second quote-strip must catch it (both orderings work).
		assert.equal( 'Octopus cyanea', clean( '\226\128\156Octopus cyanea\226\128\157 (day octopus)' ) )
		assert.equal( 'Octopus cyanea', clean( '"Octopus cyanea" (day octopus)' ) )
	end )
	it( 'collapses interior whitespace (newline/tabs) to single spaces', function()
		assert.equal( 'Meleagris gallopavo', clean( 'Meleagris\n\tgallopavo' ) )
	end )
	it( 'returns empty for a non-string selection', function()
		assert.equal( '', clean( nil ) )
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

	it( 'falls back to the common channel for a binomial-LOOKING common name', function()
		-- 'Lei triggerfish' passes looksBinomial (Capital + lowercase word), so the
		-- scientific channel is tried FIRST (GBIF returns NONE) and the common channel
		-- resolves it — proving GBIF, not the surface form, is the gate.
		assert.is_true( SelectedName._test.looksBinomial( 'Lei triggerfish' ) )
		local r = SelectedName.resolve( 'Lei triggerfish', deps )
		assert.equal( 'common', r.kind )
	end )

	it( 'passes cfg (mode, rootKeyword, flatRoot) through into the keyword plan', function()
		local r = SelectedName.resolve( 'Octopus cyanea', deps,
			{ keywordMode = 'both', rootKeyword = 'Life', flatRoot = 'Wildlife' } )
		assert.is_true( r.ok )
		assert.equal( 'both', r.plan.mode )
		assert.equal( 'Life', r.plan.nodes[ 1 ].path[ 1 ] ) -- hierarchy nested under rootKeyword
		local sawFlatRoot = false
		for _, n in ipairs( r.plan.nodes ) do
			if n.path[ 1 ] == 'Wildlife' then sawFlatRoot = true end -- flat keywords under flatRoot
		end
		assert.is_true( sawFlatRoot )
	end )

	it( 'reports not-found when GBIF does not recognise the selection', function()
		local r = SelectedName.resolve( 'Related searches', deps )
		assert.is_false( r.ok )
	end )

	it( 'reports empty for a blank selection', function()
		assert.is_false( SelectedName.resolve( '   ', deps ).ok )
	end )
end )
