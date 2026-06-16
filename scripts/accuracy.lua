#!/usr/bin/env lua
--[[----------------------------------------------------------------------------
scripts/accuracy.lua
Prints the species-ID accuracy report over the offline fixture corpus and exits
non-zero if accuracy regresses (recall < 100% or any confident false positive).
Run from the repo root:  lua scripts/accuracy.lua   (or `just accuracy`).

This is the human-readable companion to accuracy_spec.lua and runs in CI as a
guard so a parser/scorer change that quietly drops accuracy fails the build.
------------------------------------------------------------------------------]]

package.path = table.concat( {
	'src/shared/?.lua', 'build/.deps/?.lua', 'spec/?.lua', package.path,
}, ';' )

local fixtures = require 'support.fixtures'
local harness = require 'support.harness'

local manifest = fixtures.manifest()
local totalFound, totalExpected, totalFP, cases, top1Hits = 0, 0, 0, 0, 0
local failed = false

print( 'Species-ID accuracy — offline fixture corpus' )
print( ('='):rep( 78 ) )
print( string.format( '%-34s %-8s %-8s %-7s %-7s %s',
	'case', 'recall', 'top-1', 'genus', 'family', 'false+' ) )
print( ('-'):rep( 78 ) )

for _, case in ipairs( manifest ) do
	local result = harness.runCase( case )
	local m = harness.metrics( case, result )
	cases = cases + 1
	totalFound = totalFound + m.found
	totalExpected = totalExpected + m.total
	totalFP = totalFP + m.falsePositives
	if m.top1 then top1Hits = top1Hits + 1 end
	if m.found < m.total or m.falsePositives > 0 then failed = true end

	print( string.format( '%-34s %d/%-6d %-8s %d/%-5d %d/%-5d %d',
		case.id, m.found, m.total, m.top1 and 'yes' or 'no',
		m.genus, m.total, m.family, m.total, m.falsePositives ) )
end

print( ('-'):rep( 78 ) )
print( string.format( 'TOTAL  recall %d/%d (%.0f%%)   top-1 %d/%d   confident false positives: %d',
	totalFound, totalExpected, 100 * totalFound / math.max( 1, totalExpected ),
	top1Hits, cases, totalFP ) )

if failed then
	print( '\nREGRESSION: recall below 100% or a confident false positive appeared.' )
	os.exit( 1 )
end
print( '\nOK — corpus fully recovered, no false positives.' )
