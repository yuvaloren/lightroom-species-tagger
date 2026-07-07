require 'support.fixtures'
local LensQuery = require 'LensQuery'

describe( 'LensQuery.build', function()
	it( 'prefixes the location with "in " so Lens reads it as context, not subject', function()
		assert.equal( 'in Monterey, California', LensQuery.build( nil, 'Monterey, California' ) )
		assert.equal( 'in Monterey, California', LensQuery.build( '', 'Monterey, California' ) )
	end )

	it( 'joins extra keywords with the "in <place>" location phrase', function()
		assert.equal( 'juvenile in Monterey, California',
			LensQuery.build( 'juvenile', 'Monterey, California' ) )
		assert.equal( 'reef fish in Hawaii', LensQuery.build( 'reef fish', 'Hawaii' ) )
	end )

	it( 'returns just the keywords when there is no location', function()
		assert.equal( 'juvenile', LensQuery.build( 'juvenile', nil ) )
		assert.equal( 'juvenile', LensQuery.build( 'juvenile', '' ) )
	end )

	it( 'returns nil when there is nothing to add', function()
		assert.is_nil( LensQuery.build( nil, nil ) )
		assert.is_nil( LensQuery.build( '', '   ' ) )
	end )

	it( 'trims stray whitespace on both parts', function()
		assert.equal( 'juvenile in Big Sur', LensQuery.build( '  juvenile  ', '  Big Sur  ' ) )
	end )

	it( 'allows overriding the preposition', function()
		assert.equal( 'found in Baja', LensQuery.build( nil, 'Baja', 'found in' ) )
	end )
end )

describe( 'LensQuery.compose (two fields + named framings)', function()
	it( 'defaults to the "in <place>" framing', function()
		assert.equal( 'in Monterey, California',
			LensQuery.compose { location = 'Monterey, California' } )
		assert.equal( LensQuery.DEFAULT_STRATEGY, 'in' )
	end )

	it( 'joins other identifying info before the framed location', function()
		assert.equal( 'juvenile in Serengeti',
			LensQuery.compose { other = 'juvenile', location = 'Serengeti', strategy = 'in' } )
	end )

	it( 'supports the operator-style framings the design tests', function()
		assert.equal( 'location: Hawaii',
			LensQuery.compose { location = 'Hawaii', strategy = 'location' } )
		assert.equal( 'location info: Hawaii',
			LensQuery.compose { location = 'Hawaii', strategy = 'location-info' } )
		assert.equal( 'photographed in Hawaii',
			LensQuery.compose { location = 'Hawaii', strategy = 'photographed' } )
		assert.equal( 'Hawaii', LensQuery.compose { location = 'Hawaii', strategy = 'bare' } )
	end )

	it( 'strategy "none" drops the location text but keeps other info', function()
		assert.is_nil( LensQuery.compose { location = 'Hawaii', strategy = 'none' } )
		assert.equal( 'juvenile',
			LensQuery.compose { other = 'juvenile', location = 'Hawaii', strategy = 'none' } )
	end )

	it( 'unknown strategy ids fall back to the default framing', function()
		assert.equal( 'in Hawaii',
			LensQuery.compose { location = 'Hawaii', strategy = 'nonsense' } )
	end )

	it( 'returns nil when both fields are empty, and trims whitespace', function()
		assert.is_nil( LensQuery.compose { location = '  ', other = '' } )
		assert.equal( 'in Big Sur', LensQuery.compose { location = '  Big Sur  ' } )
	end )

	it( 'every advertised strategy has a stable id + frame', function()
		for _, s in ipairs( LensQuery.STRATEGIES ) do
			assert.is_string( s.id )
			assert.is_function( s.frame )
			assert.equal( s, LensQuery.strategy( s.id ) )
		end
	end )
end )
