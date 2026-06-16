--[[----------------------------------------------------------------------------
accuracy_spec.lua
The regression gate. Replays every labelled case in the fixture corpus through
the real pipeline (offline) and asserts the ground-truth species come out — both
recall (every expected species found) and precision (no confident false
positives). If a future change to the parser/scorer/resolver regresses accuracy,
this fails.
------------------------------------------------------------------------------]]

require 'support.fixtures'
local fixtures = require 'support.fixtures'
local harness = require 'support.harness'

describe( 'species-ID accuracy over the fixture corpus', function()
	for _, case in ipairs( fixtures.manifest() ) do
		describe( case.id, function()
			local result = harness.runCase( case )
			local m = harness.metrics( case, result )

			it( 'auto-applies (decision == apply)', function()
				assert.equal( 'apply', m.decision )
			end )
			it( 'finds every expected species (recall == 1.0)', function()
				assert.equal( m.total, m.found )
			end )
			it( 'produces no confident false positives', function()
				assert.equal( 0, m.falsePositives )
			end )
			it( 'gets genus and family right for each match', function()
				assert.equal( m.total, m.genus )
				assert.equal( m.total, m.family )
			end )
		end )
	end
end )
