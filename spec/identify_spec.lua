require 'support.fixtures'
local Identify = require 'Identify'

-- A tiny synthetic resolver: maps candidate names to canned taxa.
local OCTO = { usageKey = 1, scientificName = 'Octopus cyanea', commonName = 'Day octopus',
	kingdom = 'Animalia', genus = 'Octopus', family = 'Octopodidae', rank = 'SPECIES', matchType = 'EXACT' }

local function resolverFrom( map )
	return function( c ) return map[ c.kind .. ':' .. c.name ] end
end

describe( 'Identify.confidence', function()
	it( 'is monotonic and bounded in (0,1)', function()
		assert.is_true( Identify.confidence( 0 ) == 0 )
		assert.is_true( Identify.confidence( 2 ) < Identify.confidence( 8 ) )
		assert.is_true( Identify.confidence( 100 ) < 1 )
	end )
end )

describe( 'Identify.run', function()
	it( 'is confident when a scientific AND common candidate agree on a taxon', function()
		local obs = {
			{ text = 'Octopus cyanea', kind = 'label', weight = 1.0 },
			{ text = 'Day octopus', kind = 'label', weight = 1.0 },
		}
		local resolve = resolverFrom {
			[ 'scientific:Octopus cyanea' ] = OCTO,
			[ 'common:Day octopus' ] = OCTO,
			[ 'common:Octopus cyanea' ] = OCTO,
		}
		local r = Identify.run( obs, { resolve = resolve } )
		assert.equal( 'apply', r.decision )
		assert.equal( 1, r.top.taxon.usageKey )
		assert.is_true( r.top.confident )
		assert.is_true( r.top.sci and r.top.common )
	end )

	it( 'prefers an observed common name over the scientific lookup vernacular', function()
		-- The scientific lookup returns GBIF's arbitrary first English name; the
		-- common candidate carries the name the image search actually surfaced.
		local sciTaxon = { usageKey = 1, scientificName = 'Octopus cyanea', commonName = "Cyane's octopus",
			kingdom = 'Animalia', genus = 'Octopus', family = 'Octopodidae', rank = 'SPECIES', matchType = 'EXACT' }
		local commonTaxon = { usageKey = 1, scientificName = 'Octopus cyanea', commonName = 'Day octopus',
			kingdom = 'Animalia', genus = 'Octopus', family = 'Octopodidae', rank = 'SPECIES', matchType = 'EXACT' }
		local obs = {
			{ text = 'Octopus cyanea', kind = 'label', weight = 1.0 },
			{ text = 'Day octopus', kind = 'label', weight = 1.0 },
		}
		local r = Identify.run( obs, { resolve = resolverFrom {
			[ 'scientific:Octopus cyanea' ] = sciTaxon,
			[ 'common:Day octopus' ] = commonTaxon,
		} } )
		assert.equal( 'Day octopus', r.top.taxon.commonName )
	end )

	it( 'trusts only the authoritative answer, suppressing title-only lookalikes', function()
		-- The AI Overview (authoritative) names Octopus cyanea; the visual-match
		-- titles surface a binomial-bearing lookalike (Octopus rubescens) that WOULD
		-- otherwise auto-apply as a false positive.
		local A = { usageKey = 1, scientificName = 'Octopus cyanea', genus = 'Octopus',
			family = 'Octopodidae', kingdom = 'Animalia', rank = 'SPECIES', matchType = 'EXACT' }
		local B = { usageKey = 2, scientificName = 'Octopus rubescens', genus = 'Octopus',
			family = 'Octopodidae', kingdom = 'Animalia', rank = 'SPECIES', matchType = 'EXACT' }
		local resolve = resolverFrom {
			[ 'scientific:Octopus cyanea' ] = A,
			[ 'scientific:Octopus rubescens' ] = B,
		}
		local lookalikeTitles = {
			{ text = 'Red octopus (Octopus rubescens) - Wikipedia', kind = 'title', weight = 0.35 },
			{ text = 'Red octopus (Octopus rubescens) - iNaturalist', kind = 'title', weight = 0.35 },
			{ text = 'Pacific red octopus (Octopus rubescens) - guide', kind = 'title', weight = 0.35 },
		}

		-- without an authoritative answer, the well-supported lookalike IS confident
		local plain = { { text = 'octopus (Octopus rubescens)', kind = 'title', weight = 0.35 } }
		for _, t in ipairs( lookalikeTitles ) do plain[ #plain + 1 ] = t end
		local r0 = Identify.run( plain, { resolve = resolve } )
		local c0 = {}; for _, a in ipairs( r0.confident ) do c0[ a.taxon.scientificName ] = true end
		assert.is_true( c0[ 'Octopus rubescens' ] )

		-- add the authoritative AI Overview naming a DIFFERENT species: now only it is confident
		local obs = { { text = 'This is a day octopus (Octopus cyanea).', kind = 'label',
			weight = 2.0, authoritative = true } }
		for _, t in ipairs( lookalikeTitles ) do obs[ #obs + 1 ] = t end
		local r = Identify.run( obs, { resolve = resolve } )
		local c = {}; for _, a in ipairs( r.confident ) do c[ a.taxon.scientificName ] = true end
		assert.is_true( c[ 'Octopus cyanea' ] )       -- the authoritative answer
		assert.is_nil( c[ 'Octopus rubescens' ] )     -- title-only lookalike suppressed
	end )

	it( 'falls back to review when nothing resolves', function()
		local r = Identify.run(
			{ { text = 'Coral reef', kind = 'label', weight = 1.0 } },
			{ resolve = function() return nil end } )
		assert.equal( 'review', r.decision )
		assert.equal( 0, #r.confident )
	end )

	it( 'does not auto-apply a single weak common-only hit', function()
		local r = Identify.run(
			{ { text = 'Some creature', kind = 'title', weight = 0.3 } },
			{ resolve = resolverFrom { [ 'common:Some creature' ] = {
				usageKey = 9, scientificName = 'Genus species', commonName = 'Some creature',
				kingdom = 'Animalia', rank = 'SPECIES', matchType = 'FUZZY' } } } )
		assert.equal( 'review', r.decision )
	end )
end )
