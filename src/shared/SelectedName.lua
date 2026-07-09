--[[----------------------------------------------------------------------------
SelectedName.lua
Assistive mode. The user reads Google Lens themselves and HIGHLIGHTS one species name;
this turns that single highlighted string into a resolved taxon + a keyword plan.

There is no scraping and no scoring of competing candidates here — the human already
chose the answer, so all we do is canonicalize their pick through GBIF (accepted Latin
name, preferred common name, full classification), exactly like the rest of the
pipeline. That is the whole point of assistive mode: the plugin never reads Google's
results; it only resolves the text the user selected.

Pure and network-free: the GBIF resolver is injected via `deps` (deps.http, deps.cache),
so it unit-tests offline against the same fixtures as Taxonomy.
------------------------------------------------------------------------------]]

local Taxonomy = require 'Taxonomy'
local Keywords = require 'Keywords'

local M = {}

local function trim( s ) return ( s:gsub( '^%s+', '' ):gsub( '%s+$', '' ) ) end

-- Clean a raw highlighted selection into a name candidate: collapse whitespace, fold
-- curly quotes to ASCII, drop surrounding quotes and a trailing "(...)" the user may
-- have caught. NB: curly quotes are normalised BEFORE any [...] match, because Lua
-- patterns match BYTES and a multibyte char placed inside a class corrupts it (the
-- class would match its individual UTF-8 bytes anywhere in the string).
local function clean( text )
	if type( text ) ~= 'string' then return '' end
	local s = ( text:gsub( '%s+', ' ' ) )
	s = s:gsub( '\226\128\156', '"' ):gsub( '\226\128\157', '"' )   -- “ ” -> "
	s = s:gsub( '\226\128\152', "'" ):gsub( '\226\128\153', "'" )   -- ‘ ’ -> '
	s = trim( s )
	s = s:gsub( '^[\'"]+', '' ):gsub( '[\'"]+$', '' )               -- surrounding ASCII quotes
	s = s:gsub( '%s*%b()%s*$', '' )                                 -- a trailing "(...)"
	s = s:gsub( '[\'"]+$', '' )                                     -- a closing quote the "(...)" had hidden
	return trim( s )
end
M._clean = clean

-- Does the cleaned selection LOOK like a scientific binomial ("Genus species": a
-- capitalised word, then a lowercase word, nothing else)? This is only a hint for which
-- GBIF channel to try FIRST — the surface form is ambiguous (a real common name like
-- "Lei triggerfish" looks binomial), so GBIF, not the capitalisation, actually decides.
local function looksBinomial( s )
	local genus, species = s:match( '^(%u%l+)%s+(%l[%l%-]+)$' )
	return genus ~= nil and #genus >= 3 and #species >= 3
end
M._looksBinomial = looksBinomial

-- resolve( text, deps [, cfg] ) -> result
--   deps : { http = <adapter>, cache = <table?> }  (same shape Taxonomy.resolve takes)
--   cfg  : { keywordMode=, commonAsSynonym= }
-- result: { ok=true,  taxon=, plan=, kind=, name= }   (kind = how GBIF resolved it)
--       | { ok=false, reason=, name= }
function M.resolve( text, deps, cfg )
	cfg = cfg or {}
	local cleaned = clean( text )
	if cleaned == '' then return { ok = false, reason = 'empty selection', name = '' } end

	-- Try the likely channel first, then fall back to the other. A real common name can
	-- look binomial ("Lei triggerfish") and vice versa, so we let GBIF be the gate rather
	-- than trusting the surface form — same philosophy as the main parser -> GBIF path.
	local order = looksBinomial( cleaned ) and { 'scientific', 'common' } or { 'common', 'scientific' }
	local taxon, usedKind
	for _, k in ipairs( order ) do
		local t = Taxonomy.resolve( { name = cleaned, kind = k }, deps )
		if t then taxon = t; usedKind = k; break end
	end
	if not taxon then
		return { ok = false, reason = 'not found in GBIF', name = cleaned }
	end

	local plan = Keywords.plan( taxon, {
		mode = cfg.keywordMode,
		commonAsSynonym = cfg.commonAsSynonym,
	} )
	return { ok = true, taxon = taxon, plan = plan, kind = usedKind, name = cleaned }
end

M._test = { clean = clean, looksBinomial = looksBinomial }

return M
