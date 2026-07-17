require 'support.fixtures'
local Config = require 'Config'

describe( 'Config.load', function()
	it( 'returns defaults when prefs is nil', function()
		local c = Config.load( nil )
		assert.equal( 'flat', c.keywordMode )
		assert.is_false( c.firstRunDone )
		assert.is_true( c.includeOnExport )
		assert.equal( 1024, c.maxEdge )
	end )
	it( 'overlays stored prefs on the defaults', function()
		local c = Config.load { keywordMode = 'both', maxEdge = 2048 }
		assert.equal( 'both', c.keywordMode )
		assert.equal( 2048, c.maxEdge )
		assert.is_true( c.includeOnExport ) -- untouched default
	end )
	it( 'preserves a stored false (does not snap back to the true default)', function()
		-- the `pv == nil` guard is what makes a turned-off toggle survive a reload
		local c = Config.load { includeOnExport = false }
		assert.is_false( c.includeOnExport )
	end )
	it( 'ignores stored keys that are not part of DEFAULTS', function()
		local c = Config.load { keywordMode = 'flat', bogusRetiredKey = 'x' }
		assert.is_nil( c.bogusRetiredKey )
	end )
	it( 'has no retired scrape / scoring / review settings', function()
		local c = Config.load( nil )
		assert.is_nil( c.backend )
		assert.is_nil( c.autoApplyThreshold )
		assert.is_nil( c.needsReviewKeyword )
		assert.is_nil( c.lensKeepOpen )
		assert.is_nil( c.locationAssistRetry )
	end )
end )
