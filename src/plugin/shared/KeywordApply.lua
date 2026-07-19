--[[----------------------------------------------------------------------------
KeywordApply.lua
The pure translation of a Keywords.plan into catalog operations. It touches only two
methods on the objects it's handed —
  catalog:createKeyword( name, synonyms, includeOnExport, parent, returnExisting )
  photo:addKeyword( leaf )
— so it drives the real Lightroom catalog in the plugin and a recording mock in tests.
No Lr* imports, no I/O: the walk itself is unit-testable.

  KeywordApply.apply( catalog, photo, plan, cfg )        -- one photo
  KeywordApply.applyCluster( catalog, photos, plan, cfg ) -- a burst: one plan, every frame

`plan` is what Keywords.plan() returns: { nodes = { { path, synonyms, attach }, … } }.
`cfg.includeOnExport` is passed to every created keyword. Must be called inside
catalog:withWriteAccessDo — createKeyword needs catalog write access.

Bursts: a whole burst is tagged from ONE identification, so the same plan is
attached to every frame in one write transaction. The keywords are created ONCE
(ensurePlan) and the resulting leaf handles are attached to each frame — createKeyword
is never called twice for the same (name, parent) in the transaction. This is not an
optimization: a keyword created earlier in a still-open write transaction is not yet in
the index that createKeyword(returnExisting=true) consults, so a repeat create yields no
usable handle (createKeyword returns false), and the old per-photo loop silently dropped
the keywords on every frame past the first (Adobe forums: cache the handle, don't
re-create). See test/plugin/keywordapply_burst_spec.lua.
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

-- Create the plan's keywords ONCE and return the leaf handles to attach (in plan
-- order). Ancestors are created but not returned; only nodes marked attach yield a
-- handle. Call this a single time per plan inside a withWriteAccessDo.
local function ensurePlan( catalog, plan, cfg )
	local leaves = {}
	for _, node in ipairs( plan.nodes ) do
		local leaf = ensureLeaf( catalog, node.path, node.synonyms, cfg.includeOnExport )
		if node.attach and leaf then leaves[ #leaves + 1 ] = leaf end
	end
	return leaves
end

function M.apply( catalog, photo, plan, cfg )
	for _, leaf in ipairs( ensurePlan( catalog, plan, cfg ) ) do
		photo:addKeyword( leaf )
	end
end

-- Apply one plan to every photo in a burst, creating each keyword exactly once.
function M.applyCluster( catalog, photos, plan, cfg )
	local leaves = ensurePlan( catalog, plan, cfg )
	for _, photo in ipairs( photos ) do
		for _, leaf in ipairs( leaves ) do photo:addKeyword( leaf ) end
	end
end

M._test = { ensureLeaf = ensureLeaf, ensurePlan = ensurePlan }

return M
