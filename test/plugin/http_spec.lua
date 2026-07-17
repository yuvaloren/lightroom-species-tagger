require 'support.fixtures'
local Http = require 'Http'
local T = Http._test

-- Http.lua's SDK-bound parts (lrAdapter, runHelper, close) need LrHttp/LrTasks and
-- real subprocesses, so they're driven by the Go helper's integration suite
-- (helper/lens/integration_test.go), not here. These specs cover the PURE seams
-- factored out for exactly this reason.

describe( 'Http._test.shQuote', function()
	it( 'POSIX-quotes and escapes an embedded single quote', function()
		assert.equal( "'abc'", T.shQuote( 'abc', false ) )
		assert.equal( [['a'\''b']], T.shQuote( "a'b", false ) )
	end )
	it( 'Windows-quotes and strips embedded double quotes', function()
		assert.equal( '"abc"', T.shQuote( 'abc', true ) )
		assert.equal( '"ab"', T.shQuote( 'a"b', true ) )
	end )
	it( 'coerces non-strings via tostring', function()
		assert.equal( "'123'", T.shQuote( 123, false ) )
	end )
end )

describe( 'Http._test.resolveHelper', function()
	it( 'returns the preferred candidate even when nothing exists on disk', function()
		-- No bundle on the test box: the probe exhausts and returns candidate #1
		-- (win-x64) so runHelper's "reinstall" error can name the missing path.
		assert.equal( 'C:\\P\\SpeciesTagger.lrplugin\\helper\\win-x64\\lens-helper.exe',
			T.resolveHelper( true, 'C:\\P\\SpeciesTagger.lrplugin' ) )
	end )
	it( 'is nil when no plugin path is available (headless / pure runs)', function()
		assert.is_nil( T.resolveHelper( true, nil ) )
	end )
end )

describe( 'Http._test.bundledHelperCandidates', function()
	it( 'lists the Windows paths — x64 FIRST (x64 runs everywhere; arm64 only on ARM)', function()
		assert.same( {
			'C:\\P\\SpeciesTagger.lrplugin\\helper\\win-x64\\lens-helper.exe',
			'C:\\P\\SpeciesTagger.lrplugin\\helper\\win-arm64\\lens-helper.exe',
		}, T.bundledHelperCandidates( true, 'C:\\P\\SpeciesTagger.lrplugin' ) )
	end )
	it( 'lists the macOS bundle paths (universal preferred)', function()
		assert.same( {
			'/p/SpeciesTagger.lrplugin/helper/darwin-universal/lens-helper',
			'/p/SpeciesTagger.lrplugin/helper/darwin-arm64/lens-helper',
			'/p/SpeciesTagger.lrplugin/helper/darwin-x64/lens-helper',
		}, T.bundledHelperCandidates( false, '/p/SpeciesTagger.lrplugin' ) )
	end )
	it( 'is empty when no plugin path is given (headless / pure runs)', function()
		assert.same( {}, T.bundledHelperCandidates( true, nil ) )
		assert.same( {}, T.bundledHelperCandidates( false, '' ) )
	end )
end )

describe( 'Http._test.interpretTagResult (helper stdout -> tag() contract)', function()
	it( 'returns the highlighted name on a successful tag', function()
		local name, err = T.interpretTagResult( { ok = true, name = 'Octopus cyanea' } )
		assert.equal( 'Octopus cyanea', name )
		assert.is_nil( err )
	end )
	it( 'maps a cancelled result to the LENS_CANCELLED sentinel (a Skip, not an error)', function()
		local name, err = T.interpretTagResult( { ok = false, cancelled = true } )
		assert.is_nil( name )
		assert.equal( Http.LENS_CANCELLED, err )
	end )
	it( 'surfaces the helper error message when a tag failed', function()
		local name, err = T.interpretTagResult( { ok = false, error = 'no species tagged' } )
		assert.is_nil( name )
		assert.is_truthy( err:find( 'no species tagged', 1, true ) )
	end )
	it( 'treats an empty name as an error', function()
		local name, err = T.interpretTagResult( { ok = true, name = '' } )
		assert.is_nil( name )
		assert.is_string( err )
	end )
	it( 'passes a runHelper error (nil decoded) through unchanged', function()
		local name, err = T.interpretTagResult( nil, 'helper produced no output' )
		assert.is_nil( name )
		assert.equal( 'helper produced no output', err )
	end )
end )

describe( 'Http._test.toLrHeaders', function()
	it( 'returns nil for no headers', function()
		assert.is_nil( T.toLrHeaders( nil ) )
	end )
	it( 'converts a header map to LrHttp {field,value} pairs', function()
		local arr = T.toLrHeaders { ['X-A'] = '1' }
		assert.equal( 1, #arr )
		assert.equal( 'X-A', arr[ 1 ].field )
		assert.equal( '1', arr[ 1 ].value )
	end )
end )
