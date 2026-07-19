require 'support.fixtures'
local KeywordApply = require 'KeywordApply'
local Keywords = require 'Keywords'

--[[
Burst keyword-apply regression (field bug 2026-07-18: "keywords are not saved
for photos past the first photo of the burst").

Root cause: TagSpecies applied the plan by calling KeywordApply per PHOTO inside a
single catalog:withWriteAccessDo. Each call re-ran createKeyword for the same
(name, parent). In Lightroom, a keyword created earlier in the SAME, still-open
write transaction is not yet in the index that createKeyword(returnExisting=true)
consults, so the repeat create yields no usable handle — createKeyword returns
false (johnrellis, Adobe forums: don't call createKeyword repeatedly in one
withWriteAccessDo; cache the handle). KeywordApply's `if ... and leaf` guard then
silently skipped photo:addKeyword — the first frame kept its keywords, every
later frame lost them.

The catalog fake below reproduces exactly that constraint: the FIRST create of a
(parent, name) in an open transaction returns a handle; a REPEAT create of the
same (parent, name) in the same transaction returns false; committed keywords are
returned by returnExisting only across transactions. A fake that de-dupes
silently (like keywordapply_spec's) would hide the bug, so the first test proves
this fake actually bites.
]]

-- A catalog that models Lightroom's one-create-per-(name,parent)-per-transaction
-- rule. `created` logs every createKeyword call so we can assert keywords are
-- built once for the whole burst, not once per frame.
local function newTxnCatalog()
	local catalog = { created = {}, _committed = {}, _inTxn = false, _txnCreated = nil }

	function catalog:createKeyword( name, synonyms, includeOnExport, parent, returnExisting )
		self.created[ #self.created + 1 ] = {
			name = name, synonyms = synonyms, parentName = parent and parent.name or nil,
			returnExisting = returnExisting,
		}
		-- A child of something that isn't a real keyword can't be created (the
		-- parent chain already failed above it this transaction).
		if parent == false then return false end
		local key = ( parent and parent.__key or '' ) .. '>' .. name

		if self._inTxn and self._txnCreated[ key ] then
			-- Same (name,parent) already created earlier in THIS open transaction:
			-- returnExisting can't see it yet and a duplicate can't be made. This is
			-- the field failure — the repeat yields no handle.
			return false
		end
		if self._committed[ key ] then
			return returnExisting and self._committed[ key ] or false
		end

		local kw = { name = name, parent = parent, __key = key }
		if self._inTxn then self._txnCreated[ key ] = kw else self._committed[ key ] = kw end
		return kw
	end

	function catalog:withWriteAccessDo( _label, fn, _opts )
		self._inTxn, self._txnCreated = true, {}
		fn()
		for k, v in pairs( self._txnCreated ) do self._committed[ k ] = v end -- commit
		self._inTxn, self._txnCreated = false, nil
	end

	return catalog
end

local function newPhoto()
	local photo = { names = {} }
	function photo:addKeyword( leaf ) self.names[ #self.names + 1 ] = leaf.name end
	return photo
end

-- Brown booby — one of the birds from the 2026-07-18 field burst (flat mode:
-- common name + Latin name, the shipping default).
local BOOBY = { scientificName = 'Sula leucogaster', commonName = 'Brown booby' }
local CFG = { includeOnExport = true }

describe( 'KeywordApply — burst (one plan, every frame)', function()
	it( 'reproduces the field bug: the old per-photo apply drops keywords on every frame past the first', function()
		local catalog = newTxnCatalog()
		local p1, p2, p3 = newPhoto(), newPhoto(), newPhoto()
		local plan = Keywords.plan( BOOBY, { mode = 'flat' } )

		-- Exactly what TagSpecies used to do: one transaction, apply per photo.
		catalog:withWriteAccessDo( 'Tag species (3 photos)', function()
			for _, p in ipairs( { p1, p2, p3 } ) do KeywordApply.apply( catalog, p, plan, CFG ) end
		end )

		assert.same( { 'Brown booby', 'Sula leucogaster' }, p1.names ) -- first frame: fine
		assert.same( {}, p2.names )                                    -- BUG: silently dropped
		assert.same( {}, p3.names )                                    -- BUG: silently dropped
	end )

	it( 'applyCluster writes the plan keywords to EVERY frame of the burst', function()
		local catalog = newTxnCatalog()
		local p1, p2, p3 = newPhoto(), newPhoto(), newPhoto()
		local plan = Keywords.plan( BOOBY, { mode = 'flat' } )

		catalog:withWriteAccessDo( 'Tag species (3 photos)', function()
			KeywordApply.applyCluster( catalog, { p1, p2, p3 }, plan, CFG )
		end )

		assert.same( { 'Brown booby', 'Sula leucogaster' }, p1.names )
		assert.same( { 'Brown booby', 'Sula leucogaster' }, p2.names )
		assert.same( { 'Brown booby', 'Sula leucogaster' }, p3.names )
	end )

	it( 'creates each keyword ONCE for the whole burst, not once per frame', function()
		local catalog = newTxnCatalog()
		local p1, p2, p3 = newPhoto(), newPhoto(), newPhoto()
		local plan = Keywords.plan( BOOBY, { mode = 'flat' } ) -- two keywords

		catalog:withWriteAccessDo( 'Tag species (3 photos)', function()
			KeywordApply.applyCluster( catalog, { p1, p2, p3 }, plan, CFG )
		end )

		assert.equal( 2, #catalog.created ) -- two keywords, NOT 2 × 3 frames
	end )

	it( 'applyCluster tags every frame in hierarchy mode (ancestors created once, attached to all)', function()
		local OCTOPUS = {
			scientificName = 'Octopus cyanea', commonName = 'Day octopus',
			kingdom = 'Animalia', phylum = 'Mollusca', class = 'Cephalopoda',
			order = 'Octopoda', family = 'Octopodidae',
		}
		local catalog = newTxnCatalog()
		local p1, p2 = newPhoto(), newPhoto()
		local plan = Keywords.plan( OCTOPUS, { mode = 'hierarchy' } )

		catalog:withWriteAccessDo( 'Tag species (2 photos)', function()
			KeywordApply.applyCluster( catalog, { p1, p2 }, plan, CFG )
		end )

		assert.same( { 'Octopus cyanea' }, p1.names ) -- only the leaf attaches
		assert.same( { 'Octopus cyanea' }, p2.names )
	end )

	it( 'applyCluster on a single-frame cluster still tags it', function()
		local catalog = newTxnCatalog()
		local p1 = newPhoto()
		local plan = Keywords.plan( BOOBY, { mode = 'flat' } )

		catalog:withWriteAccessDo( 'Tag species', function()
			KeywordApply.applyCluster( catalog, { p1 }, plan, CFG )
		end )

		assert.same( { 'Brown booby', 'Sula leucogaster' }, p1.names )
	end )
end )
