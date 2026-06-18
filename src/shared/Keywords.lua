--[[----------------------------------------------------------------------------
Keywords.lua
Turns a resolved taxon into a *keyword plan* the Lightroom layer can apply. Pure
and testable — it builds the plan; TagSpecies.lua (LR side) walks it with
LrCatalog:createKeyword / photo:addKeyword.

Modes (chosen in plugin settings):
  'flat'      : two top-level keywords — the common name and the Latin name.
  'hierarchy' : the GBIF chain Kingdom > … > Family > Species (genus omitted — it's
                already the first word of the binomial), attaching the species leaf
                (Latin name), with the common name as a synonym.
  'both'      : the hierarchy AND the two flat keywords (this project's default).

A plan node is { path = { 'Animalia', …, 'Octopus cyanea' }, synonyms = {…},
attach = <bool> }. The LR side ensures each element of `path` exists
(createKeyword … returnExisting) walking parent→child, sets `synonyms` on the
leaf, and attaches the leaf to the photo when `attach` is true. Ancestors are
created but not directly attached (Lightroom shows them as the keyword's path).
------------------------------------------------------------------------------]]

local M = {}

-- Genus is intentionally omitted: it is redundant with the binomial species name
-- (the "Fistularia" node over "Fistularia commersonii" adds nothing), so the species
-- leaf attaches directly under the family.
M.RANK_ORDER = { 'kingdom', 'phylum', 'class', 'order', 'family', 'species' }

-- Ordered classification names present on the taxon (species slot = Latin name).
function M.hierarchyLevels( taxon )
	local levels = {}
	local function push( v )
		if v and v ~= '' and levels[ #levels ] ~= v then levels[ #levels + 1 ] = v end
	end
	for _, rank in ipairs( M.RANK_ORDER ) do
		if rank == 'species' then
			push( taxon.scientificName or taxon.species )
		else
			push( taxon[ rank ] )
		end
	end
	-- guarantee the Latin name is the leaf even if classification was sparse
	push( taxon.scientificName )
	return levels
end

-- plan( taxon, opts ) -> { nodes = {...}, attachNames = {...}, mode = <string> }
--   opts.mode          : 'flat' | 'hierarchy' | 'both'   (default 'both')
--   opts.rootKeyword   : optional parent to nest the hierarchy under (e.g. 'Wildlife')
--   opts.flatRoot      : optional parent for the flat keywords (default top-level)
--   opts.commonAsSynonym : attach the common name as a synonym of the Latin leaf (default true)
function M.plan( taxon, opts )
	opts = opts or {}
	local mode = opts.mode or 'both'
	local commonAsSynonym = opts.commonAsSynonym ~= false
	local sci = taxon.scientificName
	local common = taxon.commonName

	local nodes, attachNames = {}, {}
	local function addNode( path, synonyms, attach )
		if #path == 0 then return end
		nodes[ #nodes + 1 ] = { path = path, synonyms = synonyms or {}, attach = attach and true or false }
		if attach then attachNames[ #attachNames + 1 ] = path[ #path ] end
	end

	if ( mode == 'hierarchy' or mode == 'both' ) and sci then
		local path = {}
		if opts.rootKeyword and opts.rootKeyword ~= '' then path[ #path + 1 ] = opts.rootKeyword end
		for _, lvl in ipairs( M.hierarchyLevels( taxon ) ) do path[ #path + 1 ] = lvl end
		local leafSyn = ( commonAsSynonym and common ) and { common } or {}
		addNode( path, leafSyn, true )
	end

	if mode == 'flat' or mode == 'both' then
		local function flatPath( name )
			if opts.flatRoot and opts.flatRoot ~= '' then return { opts.flatRoot, name } end
			return { name }
		end
		if common then
			addNode( flatPath( common ), ( sci and { sci } ) or {}, true )
		end
		if sci then
			addNode( flatPath( sci ), ( common and { common } ) or {}, true )
		end
	end

	return { nodes = nodes, attachNames = attachNames, mode = mode }
end

return M
