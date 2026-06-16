--[[----------------------------------------------------------------------------
spec/support/harness.lua
Runs the full offline pipeline for a manifest case (provider.parse -> Identify ->
Taxonomy over the fixture-backed fake http) and scores the result against the
case's ground truth. Shared by spec/accuracy_spec.lua and scripts/accuracy.lua.
------------------------------------------------------------------------------]]

local Providers = require 'Providers'
local Identify = require 'Identify'
local Taxonomy = require 'Taxonomy'
local fixtures = require 'support.fixtures'
local fakeHttp = require 'support.fake_http'

local M = {}

-- runCase( case [, cfg] ) -> identifyResult, observations
function M.runCase( case, cfg )
	local decoded = assert( fixtures.loadJson( case.response ) )
	local provider = assert( Providers.get( case.provider ), 'unknown provider: ' .. tostring( case.provider ) )
	local obs = provider.parse( decoded )
	local deps = { http = fakeHttp.new(), cache = {} }
	local result = Identify.run( obs, {
		resolve = function( c ) return Taxonomy.resolve( c, deps ) end,
	}, cfg )
	return result, obs
end

-- metrics( case, result ) -> table of per-case accuracy figures
function M.metrics( case, result )
	local confident = {}
	for _, a in ipairs( result.confident ) do
		confident[ a.taxon.scientificName ] = a
	end
	local expSet = {}
	for _, e in ipairs( case.expected ) do expSet[ e.scientific ] = true end

	local found, genus, family = 0, 0, 0
	for _, exp in ipairs( case.expected ) do
		local a = confident[ exp.scientific ]
		if a then
			found = found + 1
			if a.taxon.genus == exp.genus then genus = genus + 1 end
			if a.taxon.family == exp.family then family = family + 1 end
		end
	end

	local falsePositives = 0
	for sci in pairs( confident ) do
		if not expSet[ sci ] then falsePositives = falsePositives + 1 end
	end

	local top1 = result.top ~= nil and expSet[ result.top.taxon.scientificName ] == true

	return {
		total = #case.expected,
		found = found,
		recall = ( #case.expected > 0 ) and ( found / #case.expected ) or 0,
		genus = genus,
		family = family,
		falsePositives = falsePositives,
		top1 = top1,
		decision = result.decision,
	}
end

return M
