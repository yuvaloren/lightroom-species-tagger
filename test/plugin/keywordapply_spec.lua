require 'support.fixtures'
local KeywordApply = require 'KeywordApply'
local Keywords = require 'Keywords'

-- Recording stand-ins for the Lightroom catalog + photo. The catalog mock mimics
-- createKeyword's returnExisting: a keyword is keyed by (parent, name), so a repeat
-- create of the same node under the same parent returns the SAME handle — exactly the
-- de-dup the real API does. Every call is logged so we can assert the walk.
local function newCatalogMock()
	local created, byKey = {}, {}
	local catalog = {}
	function catalog:createKeyword( name, synonyms, includeOnExport, parent, returnExisting )
		created[ #created + 1 ] = {
			name = name, synonyms = synonyms, includeOnExport = includeOnExport,
			parentName = parent and parent.name or nil, returnExisting = returnExisting,
		}
		local key = ( parent and parent.name or '' ) .. '>' .. name
		if returnExisting and byKey[ key ] then return byKey[ key ] end
		local kw = { name = name, parent = parent }
		byKey[ key ] = kw
		return kw
	end
	return catalog, created
end

local function newPhotoMock()
	local attached = {}
	local photo = {}
	function photo:addKeyword( leaf ) attached[ #attached + 1 ] = leaf.name end
	return photo, attached
end

local OCTOPUS = {
	scientificName = 'Octopus cyanea', commonName = 'Day octopus',
	kingdom = 'Animalia', phylum = 'Mollusca', class = 'Cephalopoda',
	order = 'Octopoda', family = 'Octopodidae', species = 'Octopus cyanea',
}

describe( 'KeywordApply.apply', function()
	it( 'flat plan creates + attaches both top-level keywords with includeOnExport', function()
		local catalog, created = newCatalogMock()
		local photo, attached = newPhotoMock()
		KeywordApply.apply( catalog, photo, Keywords.plan( OCTOPUS, { mode = 'flat' } ),
			{ includeOnExport = true } )
		assert.same( { 'Day octopus', 'Octopus cyanea' }, attached )
		for _, c in ipairs( created ) do assert.is_true( c.includeOnExport ) end
	end )

	it( 'hierarchy plan creates ancestors parent->child and attaches only the leaf', function()
		local catalog, created = newCatalogMock()
		local photo, attached = newPhotoMock()
		KeywordApply.apply( catalog, photo, Keywords.plan( OCTOPUS, { mode = 'hierarchy' } ),
			{ includeOnExport = false } )
		assert.equal( 'Animalia', created[ 1 ].name )       -- root created first
		assert.is_nil( created[ 1 ].parentName )            -- ...with no parent
		assert.equal( 'Octopus cyanea', created[ #created ].name )     -- leaf created last
		assert.equal( 'Octopodidae', created[ #created ].parentName )  -- under the family
		assert.same( { 'Octopus cyanea' }, attached )       -- only the leaf attaches
		for _, c in ipairs( created ) do assert.is_false( c.includeOnExport ) end
	end )

	it( 'sets synonyms only on the leaf; ancestors are plain containers', function()
		local catalog, created = newCatalogMock()
		local photo = newPhotoMock()
		KeywordApply.apply( catalog, photo, Keywords.plan( OCTOPUS, { mode = 'hierarchy' } ),
			{ includeOnExport = true } )
		assert.same( {}, created[ 1 ].synonyms )                    -- Animalia: none
		assert.same( { 'Day octopus' }, created[ #created ].synonyms ) -- leaf: common as synonym
	end )

	it( 'creates every keyword with returnExisting so the catalog can de-dupe repeats', function()
		local catalog, created = newCatalogMock()
		local photo = newPhotoMock()
		KeywordApply.apply( catalog, photo, Keywords.plan( OCTOPUS, { mode = 'hierarchy' } ),
			{ includeOnExport = true } )
		assert.is_true( #created > 0 )
		for _, c in ipairs( created ) do assert.is_true( c.returnExisting ) end
	end )

	it( 'attaches nothing for an empty plan', function()
		local catalog, created = newCatalogMock()
		local photo, attached = newPhotoMock()
		KeywordApply.apply( catalog, photo, { nodes = {} }, { includeOnExport = true } )
		assert.same( {}, attached )
		assert.same( {}, created )
	end )
end )
