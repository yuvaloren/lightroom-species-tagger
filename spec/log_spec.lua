require 'support.fixtures'
local Log = require 'Log'

describe( 'Log.redact', function()
	it( 'redacts Vision key= and Pl@ntNet api-key= URL params', function()
		assert.equal( 'https://vision.googleapis.com/v1/images:annotate?key=<key>',
			Log.redact( 'https://vision.googleapis.com/v1/images:annotate?key=AIzaSyABC123_def' ) )
		assert.equal( 'https://my-api.plantnet.org/v2/identify/all?lang=en&api-key=<key>',
			Log.redact( 'https://my-api.plantnet.org/v2/identify/all?lang=en&api-key=2b10SECRET' ) )
	end )

	it( 'redacts bare AIza... Google keys', function()
		assert.equal( 'using <google-key> now', Log.redact( 'using AIzaSyABC-123_def now' ) )
	end )

	it( 'redacts a Cookie header value (the Lens session cookie)', function()
		assert.equal( 'Cookie: <redacted>', Log.redact( 'Cookie: NID=abc; AEC=def; SOCS=ghi' ) )
	end )

	it( 'passes through non-strings and clean text', function()
		assert.equal( 'nothing secret here', Log.redact( 'nothing secret here' ) )
		assert.equal( 42, Log.redact( 42 ) )
	end )
end )
