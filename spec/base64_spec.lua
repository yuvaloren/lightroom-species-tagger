require 'support.fixtures' -- ensure package.path includes src/shared via .busted
local Base64 = require 'Base64'

describe( 'Base64', function()
	it( 'encodes known vectors with correct padding', function()
		assert.equal( '', Base64.encode( '' ) )
		assert.equal( 'TQ==', Base64.encode( 'M' ) )
		assert.equal( 'TWE=', Base64.encode( 'Ma' ) )
		assert.equal( 'TWFu', Base64.encode( 'Man' ) )
		assert.equal( 'aGVsbG8=', Base64.encode( 'hello' ) )
	end )

	it( 'round-trips arbitrary bytes', function()
		local s = 'The quick brown fox \0\1\2\255 jumps! +/=?'
		assert.equal( s, Base64.decode( Base64.encode( s ) ) )
	end )
end )
