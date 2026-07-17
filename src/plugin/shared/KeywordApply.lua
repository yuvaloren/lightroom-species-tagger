--[[----------------------------------------------------------------------------
KeywordApply.lua
The pure translation of a Keywords.plan into catalog operations. It touches only two
methods on the objects it's handed —
  catalog:createKeyword( name, synonyms, includeOnExport, parent, returnExisting )
  photo:addKeyword( leaf )
— so it drives the real Lightroom catalog in the plugin and a recording mock in tests.
No Lr* imports, no I/O: the walk itself is unit-testable.

  KeywordApply.apply( catalog, photo, plan, cfg )

`plan` is what Keywords.plan() returns: { nodes = { { path, synonyms, attach }, … } }.
`cfg.includeOnExport` is passed to every created keyword. Must be called inside
catalog:withWriteAccessDo — createKeyword needs catalog write access.
------------------------------------------------------------------------------]]

local M = {}

-- Ensure a keyword path exists (creating ancestors as needed, parent -> child) and
-- return the leaf. Only the leaf carries synonyms; ancestors are plain containers.
-- returnExisting = true means an existing keyword of the same name/parent is reused.
local function ensureLeaf( catalog, path, synonyms, includeOnExport )
	local parent, leaf
	for idx, name in ipairs( path ) do
		local isLeaf = ( idx == #path )
		leaf = catalog:createKeyword( name, isLeaf and ( synonyms or {} ) or {},
			includeOnExport, parent, true ) -- returnExisting = true
		parent = leaf
	end
	return leaf
end

function M.apply( catalog, photo, plan, cfg )
	for _, node in ipairs( plan.nodes ) do
		local leaf = ensureLeaf( catalog, node.path, node.synonyms, cfg.includeOnExport )
		if node.attach and leaf then photo:addKeyword( leaf ) end
	end
end

M._test = { ensureLeaf = ensureLeaf }

return M
