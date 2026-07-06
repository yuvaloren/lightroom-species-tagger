require 'support.fixtures'
local Providers = require 'Providers'
local Lens = require 'ProviderGoogleLens'
local fixtures = require 'support.fixtures'

local function find( obs, text )
	for _, o in ipairs( obs ) do if o.text == text then return o end end
	return nil
end

local function texts( obs )
	local t = {}
	for _, o in ipairs( obs ) do t[ o.text ] = true end
	return t
end

describe( 'Providers registry', function()
	it( 'registers the keyless Google Lens backend', function()
		assert.is_truthy( Providers.get( 'lens' ) )
		assert.equal( 1, #Providers.all() )
	end )
	it( 'defaults to the Google Lens backend first', function()
		assert.equal( 'lens', Providers.ids()[ 1 ] )
	end )
	it( 'has no other backends registered', function()
		assert.is_nil( Providers.get( 'vision' ) )
		assert.is_nil( Providers.get( 'plantnet' ) )
	end )
end )

describe( 'ProviderGoogleLens', function()
	it( 'harvests page-title / name strings from the embedded results JSON', function()
		local d = assert( fixtures.loadJson( 'lens/reef_octopus_triggerfish.json' ) )
		local obs = Lens.parse( d )
		local t = texts( obs )
		assert.is_truthy( t[ 'Day octopus (Octopus cyanea) - Wikipedia' ] )
		assert.is_truthy( t[ 'Sufflamen bursa - iNaturalist' ] )
		assert.is_truthy( t[ 'Day octopus' ] )
		assert.equal( 'title', find( obs, 'Day octopus' ).kind )
	end )

	it( 'drops URLs and obvious non-names', function()
		-- a hand-made blob with the kinds of tokens a real page carries
		local blob = { { 'Day octopus (Octopus cyanea) - Wikipedia',
			'https://en.wikipedia.org/wiki/Octopus_cyanea',
			'dGhpcyBpcyBhIGJhc2U2NCBibG9iIHRoYXQgc2hvdWxkIGJlIGlnbm9yZWQ', 'ds:0' } }
		local t = texts( Lens.parse( blob ) )
		assert.is_truthy( t[ 'Day octopus (Octopus cyanea) - Wikipedia' ] )
		assert.is_nil( t[ 'https://en.wikipedia.org/wiki/Octopus_cyanea' ] )
		assert.is_nil( t[ 'dGhpcyBpcyBhIGJhc2U2NCBibG9iIHRoYXQgc2hvdWxkIGJlIGlnbm9yZWQ' ] )
		assert.is_nil( t[ 'ds:0' ] )
	end )

	it( 'isCandidate accepts names and rejects tokens/urls', function()
		assert.is_true( Lens._isCandidate( 'Day octopus' ) )
		assert.is_true( Lens._isCandidate( 'Sufflamen bursa' ) )
		assert.is_false( Lens._isCandidate( 'https://example.com/x' ) )
		assert.is_false( Lens._isCandidate( 'AIzaSyDr2UxVnv0123456789abcdef' ) ) -- long single token
		assert.is_false( Lens._isCandidate( '12345' ) )
		assert.is_false( Lens._isCandidate( 'a' ) )
	end )

	it( 'identify() weights the AI Overview high and harvests match titles low', function()
		local helper = function( file )
			assert.equal( '/tmp/x.jpg', file )
			return {
				overview = 'The fish pictured is a Giant Frogfish (Antennarius commerson).',
				strings = { 'Frogfish - Wikipedia', 'https://en.wikipedia.org/wiki/Frogfish', 'Reef life' },
			}
		end
		local obs, err = Lens.identify( { imageFile = '/tmp/x.jpg' }, { lensSearch = helper } )
		assert.is_nil( err )
		local ai = find( obs, 'The fish pictured is a Giant Frogfish (Antennarius commerson).' )
		assert.is_truthy( ai )
		assert.equal( 'label', ai.kind )
		assert.is_true( ai.weight >= 1.5 )                         -- AI Overview is the strong signal
		assert.is_truthy( find( obs, 'Frogfish - Wikipedia' ) )    -- titles harvested too
		assert.is_nil( find( obs, 'https://en.wikipedia.org/wiki/Frogfish' ) ) -- URL dropped
	end )

	it( 'parse() also accepts a plain string list (representative fixtures)', function()
		local obs = Lens.parse { 'Day octopus (Octopus cyanea) - Wikipedia', 'https://x/y' }
		assert.is_truthy( find( obs, 'Day octopus (Octopus cyanea) - Wikipedia' ) )
		assert.is_nil( find( obs, 'https://x/y' ) )
	end )

	it( 'identify() surfaces the helper error and never crashes', function()
		local obs, err = Lens.identify( { imageFile = '/tmp/x.jpg' },
			{ lensSearch = function() return nil, 'Lens helper: blocked' end } )
		assert.equal( 0, #obs )
		assert.matches( 'blocked', err )
	end )

	it( 'identify() errors clearly when no helper is wired in', function()
		local _, err = Lens.identify( { imageFile = '/tmp/x.jpg' }, {} )
		assert.matches( 'helper', err )
	end )
end )
