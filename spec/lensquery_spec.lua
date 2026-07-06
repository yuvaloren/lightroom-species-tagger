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
