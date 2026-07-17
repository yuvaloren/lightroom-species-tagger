require 'support.fixtures'
local Log = require 'Log'

describe( 'Log.redact', function()
	it( 'redacts a Cookie header value (the Lens session cookie)', function()
		assert.equal( 'Cookie: <redacted>', Log.redact( 'Cookie: NID=abc; AEC=def; SOCS=ghi' ) )
	end )

	it( 'redacts generic key= / api-key= URL params defensively', function()
		assert.equal( 'https://example.test/x?key=<key>',
			Log.redact( 'https://example.test/x?key=AIzaSyABC123_def' ) )
		assert.equal( 'https://example.test/y?lang=en&api-key=<key>',
			Log.redact( 'https://example.test/y?lang=en&api-key=2b10SECRET' ) )
	end )

	it( 'redacts bare AIza... Google keys', function()
		assert.equal( 'using <google-key> now', Log.redact( 'using AIzaSyABC-123_def now' ) )
	end )

	it( 'passes through non-strings and clean text', function()
		assert.equal( 'nothing secret here', Log.redact( 'nothing secret here' ) )
		assert.equal( 42, Log.redact( 42 ) )
	end )
end )

describe( 'Log.new (headless)', function()
	it( 'degrades to a silent no-op logger when the Lr import global is absent', function()
		-- In the test runner there is no `import`, so new() takes the makeNoop() path.
		local logger = Log.new( 'SpeciesTagger' )
		assert.equal( 'function', type( logger.info ) )
		assert.has_no.errors( function()
			logger:enable( 'logfile' )
			logger:trace( 't' ); logger:info( 'i' ); logger:warn( 'w' ); logger:error( 'e' )
		end )
	end )
end )
