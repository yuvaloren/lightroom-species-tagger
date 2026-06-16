require 'support.fixtures'
local Keywords = require 'Keywords'

local OCTOPUS = {
	scientificName = 'Octopus cyanea', commonName = 'Day octopus',
	kingdom = 'Animalia', phylum = 'Mollusca', class = 'Cephalopoda',
	order = 'Octopoda', family = 'Octopodidae', genus = 'Octopus',
	species = 'Octopus cyanea',
}

local function attachSet( plan )
	local s = {}
	for _, n in ipairs( plan.attachNames ) do s[ n ] = true end
	return s
end

describe( 'Keywords.hierarchyLevels', function()
	it( 'orders kingdom..species and de-dups', function()
		local lv = Keywords.hierarchyLevels( OCTOPUS )
		assert.same( { 'Animalia', 'Mollusca', 'Cephalopoda', 'Octopoda',
			'Octopodidae', 'Octopus', 'Octopus cyanea' }, lv )
	end )
	it( 'skips missing ranks (e.g. absent class)', function()
		local t = { scientificName = 'Sufflamen bursa', kingdom = 'Animalia',
			phylum = 'Chordata', order = 'Tetraodontiformes', family = 'Balistidae',
			genus = 'Sufflamen' }
		assert.same( { 'Animalia', 'Chordata', 'Tetraodontiformes', 'Balistidae',
			'Sufflamen', 'Sufflamen bursa' }, Keywords.hierarchyLevels( t ) )
	end )
end )

describe( 'Keywords.plan', function()
	it( 'flat mode attaches common + Latin as top-level keywords', function()
		local p = Keywords.plan( OCTOPUS, { mode = 'flat' } )
		local a = attachSet( p )
		assert.is_true( a[ 'Day octopus' ] )
		assert.is_true( a[ 'Octopus cyanea' ] )
		assert.equal( 2, #p.nodes )
	end )
	it( 'hierarchy mode attaches the species leaf with the common name as a synonym', function()
		local p = Keywords.plan( OCTOPUS, { mode = 'hierarchy' } )
		assert.equal( 1, #p.nodes )
		local node = p.nodes[ 1 ]
		assert.equal( 'Octopus cyanea', node.path[ #node.path ] )
		assert.equal( 'Animalia', node.path[ 1 ] )
		assert.same( { 'Day octopus' }, node.synonyms )
		assert.is_true( node.attach )
	end )
	it( 'both mode = hierarchy + the two flat keywords, with optional root', function()
		local p = Keywords.plan( OCTOPUS, { mode = 'both', rootKeyword = 'Wildlife' } )
		assert.equal( 'Wildlife', p.nodes[ 1 ].path[ 1 ] )
		local a = attachSet( p )
		assert.is_true( a[ 'Day octopus' ] )
		assert.is_true( a[ 'Octopus cyanea' ] )
		assert.is_true( #p.nodes >= 3 )
	end )
end )
