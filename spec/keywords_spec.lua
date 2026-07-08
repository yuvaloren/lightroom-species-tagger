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
	it( 'orders kingdom..family then the species leaf (genus omitted, de-dups)', function()
		local lv = Keywords.hierarchyLevels( OCTOPUS )
		assert.same( { 'Animalia', 'Mollusca', 'Cephalopoda', 'Octopoda',
			'Octopodidae', 'Octopus cyanea' }, lv )
	end )
	it( 'skips missing ranks (e.g. absent class) and the redundant genus', function()
		local t = { scientificName = 'Sufflamen bursa', kingdom = 'Animalia',
			phylum = 'Chordata', order = 'Tetraodontiformes', family = 'Balistidae',
			genus = 'Sufflamen' }
		assert.same( { 'Animalia', 'Chordata', 'Tetraodontiformes', 'Balistidae',
			'Sufflamen bursa' }, Keywords.hierarchyLevels( t ) )
	end )
	it( 'guarantees the Latin name as the leaf when classification is sparse', function()
		assert.same( { 'Octopus cyanea' },
			Keywords.hierarchyLevels { scientificName = 'Octopus cyanea' } )
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
	it( 'flat mode nests both keywords under flatRoot when set', function()
		local p = Keywords.plan( OCTOPUS, { mode = 'flat', flatRoot = 'Wildlife' } )
		assert.equal( 2, #p.nodes )
		for _, node in ipairs( p.nodes ) do
			assert.equal( 'Wildlife', node.path[ 1 ] )
			assert.equal( 2, #node.path )
		end
	end )
	it( 'hierarchy mode with commonAsSynonym=false omits the common-name synonym', function()
		local p = Keywords.plan( OCTOPUS, { mode = 'hierarchy', commonAsSynonym = false } )
		assert.same( {}, p.nodes[ 1 ].synonyms )
	end )
	it( 'flat mode with only a common name emits just that keyword (no synonym)', function()
		local p = Keywords.plan( { commonName = 'Wolf eel' }, { mode = 'flat' } )
		assert.equal( 1, #p.nodes )
		assert.same( { 'Wolf eel' }, p.nodes[ 1 ].path )
		assert.same( {}, p.nodes[ 1 ].synonyms )
	end )
	it( 'flat mode with only a scientific name emits just that keyword', function()
		local p = Keywords.plan( { scientificName = 'Anarrhichthys ocellatus' }, { mode = 'flat' } )
		assert.equal( 1, #p.nodes )
		assert.same( { 'Anarrhichthys ocellatus' }, p.nodes[ 1 ].path )
	end )
	it( 'hierarchy mode with no scientific name produces no nodes', function()
		local p = Keywords.plan( { commonName = 'Wolf eel' }, { mode = 'hierarchy' } )
		assert.equal( 0, #p.nodes )
	end )
end )
