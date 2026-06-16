-- Luacheck configuration for the Species Tagger Lightroom plugin.
--
-- Convention: every Lua module `return`s its table (plain Lua 5.1). We do NOT
-- use the SDK-sample "define a global" style, so there is no project-globals
-- allowlist here — that keeps the static-analysis surface honest.
std = 'lua51'

-- Lightroom plugin runtime globals (only the .lrplugin/*.lua glue touches these;
-- the pure modules in src/shared/ never call `import` — they take injected deps).
read_globals = {
	'import',   -- LR namespace loader
	'LOC',      -- localization helper
	'_PLUGIN',  -- plugin object
}

ignore = {
	'212', -- unused argument (SDK callbacks have fixed signatures)
	'213', -- unused loop variable
	'542', -- empty if branch (used for readable "skip" cases)
}

max_line_length = false

-- The test suite uses the busted DSL (describe/it/assert/...).
files['spec'] = {
	std = '+busted',
	read_globals = { 'import', '_PLUGIN' },
}

-- Helper scripts are run with the pinned standalone Lua (have arg/io/os).
files['scripts'] = {
	globals = { 'arg' },
}
