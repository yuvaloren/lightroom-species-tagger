require 'support.fixtures'
local SpeciesParser = require 'SpeciesParser'
local T = SpeciesParser._test

local function hasName( list, name )
	for _, e in ipairs( list ) do if e.name == name then return e end end
	return nil
end

describe( 'extractScientific', function()
	it( 'finds a parenthetical binomial and marks it strong', function()
		local got = T.extractScientific( 'Lei triggerfish (Sufflamen bursa) - Wikipedia' )
		local e = hasName( got, 'Sufflamen bursa' )
		assert.is_truthy( e )
		assert.is_true( e.strong )
	end )
	it( 'rejects stop-worded first tokens like "Day octopus"', function()
		assert.is_nil( hasName( T.extractScientific( 'Day octopus' ), 'Day octopus' ) )
	end )
	it( 'normalizes a capitalized-second-word genus to "Genus species"', function()
		local e = hasName( T.extractScientific( 'Octopus cyanea Gray, 1849' ), 'Octopus cyanea' )
		assert.is_truthy( e )
	end )
	it( 'rejects pseudo-binomials whose epithet is an English function word', function()
		-- range prose the "Genus species" regex would otherwise mine into a fake binomial
		assert.is_nil( hasName( T.extractScientific( 'native to India and Sri Lanka' ), 'India and' ) )
		assert.is_nil( hasName( T.extractScientific( 'found in Mexico and Central America' ), 'Mexico and' ) )
		assert.is_nil( hasName( T.extractScientific( 'areas like Namibia and Botswana' ), 'Namibia and' ) )
	end )
	it( 'still accepts a real binomial sitting next to function words', function()
		assert.is_truthy( hasName( T.extractScientific( 'the frog Scinax hayii is common here' ), 'Scinax hayii' ) )
	end )
end )

describe( 'cleanCommon', function()
	it( 'strips a trailing scientific parenthetical', function()
		assert.equal( 'Lei triggerfish', T.cleanCommon( 'Lei triggerfish (Sufflamen bursa)' ) )
	end )
	it( 'rejects strings with digits and pure site noise', function()
		assert.is_nil( T.cleanCommon( 'Canon EOS 5D sample' ) )
		assert.is_nil( T.cleanCommon( 'Wikipedia' ) )
	end )
end )

describe( 'candidates', function()
	it( 'mines a lower-case bestGuess label into a scientific candidate', function()
		local cands = SpeciesParser.candidates( {
			{ text = 'sufflamen bursa', kind = 'label', weight = 1.3 },
		} )
		assert.is_truthy( hasName( cands, 'Sufflamen bursa' ) )
	end )

	it( 'ranks a repeated scientific name above a single common name', function()
		local cands = SpeciesParser.candidates( {
			{ text = 'Octopus cyanea', kind = 'label', weight = 1.0 },
			{ text = 'Octopus cyanea - Wikipedia', kind = 'title', weight = 0.5 },
			{ text = 'Cephalopod', kind = 'label', weight = 1.0 },
		} )
		assert.equal( 'Octopus cyanea', cands[ 1 ].name )
		assert.equal( 'scientific', cands[ 1 ].kind )
		assert.is_true( cands[ 1 ].hits >= 2 )
	end )
end )
