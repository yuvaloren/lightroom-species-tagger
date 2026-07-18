require 'support.fixtures'
local TagRun = require 'TagRun'

local CANCELLED = '__cancelled__'

-- Build N items with rendered files, in selection order.
local function items( n, opts )
	opts = opts or {}
	local out = {}
	for i = 1, n do
		local failed = ( opts.failRender == i )
		out[ i ] = {
			id = i,
			photo = { id = i }, -- opaque handle
			file = failed and false or ( '/tmp/img' .. i .. '.jpg' ), -- see below; failed handled next line
			err = failed and 'render boom' or nil,
			t = i * 0.1,
			label = 'IMG_' .. i,
		}
		if failed then out[ i ].file = false end -- `x and false or y` yields y in Lua; set explicitly
	end
	return out
end

-- A recording assist: `tag` returns queued results (default: a name per call),
-- records every (file,pos); `applyCluster` records the member ids it got.
local function recorder( tagResults )
	local rec = { tagCalls = {}, applied = {} }
	rec.deps = {
		cancelled = CANCELLED,
		tag = function( file, pos )
			rec.tagCalls[ #rec.tagCalls + 1 ] = { file = file, pos = pos }
			local r = tagResults and tagResults[ #rec.tagCalls ]
			if r == nil then return 'Some species' end -- default: always a name
			if r == false then return nil, CANCELLED end -- Skip
			if type( r ) == 'table' and r.err then return nil, r.err end -- helper error
			return r -- a name string
		end,
		resolve = function( name )
			if name == '__miss__' then return { ok = false } end
			return { ok = true, plan = { name = name }, taxon = { scientificName = name, commonName = name } }
		end,
		applyCluster = function( members, plan )
			local ids = {}
			for _, m in ipairs( members ) do ids[ #ids + 1 ] = m.id end
			rec.applied[ #rec.applied + 1 ] = { ids = ids, plan = plan }
		end,
	}
	return rec
end

-- A cluster function that returns a fixed shape (isolates orchestration from the
-- clustering math, which has its own spec).
local function fixedClusters( shape )
	return function() return shape end
end

local function baseCfg( over )
	local c = { burstDetect = true, burstGapSeconds = 1 }
	for k, v in pairs( over or {} ) do c[ k ] = v end
	return c
end

describe( 'TagRun.run — one Lens read per cluster', function()
	it( 'calls tag ONCE per cluster, on the representative — not once per photo', function()
		local r = recorder()
		local out = TagRun.run {
			items = items( 5 ), cfg = baseCfg(),
			cluster = fixedClusters { { 1, 2, 3 }, { 4, 5 } },
			hashFiles = function( f ) local h = {}; for i = 1, #f do h[ i ] = 'x' end; return h end,
			tag = r.deps.tag, cancelled = r.deps.cancelled,
			resolve = r.deps.resolve, applyCluster = r.deps.applyCluster,
		}
		-- the regression guard: 2 clusters => 2 Lens reads, NOT 5
		assert.equal( 2, #out.tagFiles )
		assert.equal( 2, out.clusters )
		assert.same( { '/tmp/img1.jpg', '/tmp/img4.jpg' }, out.tagFiles ) -- representatives
		assert.equal( 5, out.applied )
		assert.equal( 0, out.skipped )
	end )

	it( 'applies the resolved keywords to EVERY member of a tagged cluster, in one write each', function()
		local r = recorder()
		TagRun.run {
			items = items( 5 ), cfg = baseCfg(),
			cluster = fixedClusters { { 1, 2, 3 }, { 4, 5 } },
			hashFiles = function( f ) local h = {}; for i = 1, #f do h[ i ] = 'x' end; return h end,
			tag = r.deps.tag, cancelled = r.deps.cancelled,
			resolve = r.deps.resolve, applyCluster = r.deps.applyCluster,
		}
		assert.equal( 2, #r.applied ) -- one write per cluster
		assert.same( { 1, 2, 3 }, r.applied[ 1 ].ids )
		assert.same( { 4, 5 }, r.applied[ 2 ].ids )
	end )
end )

describe( 'TagRun.run — the loop blocks on and consumes each tag result', function()
	it( 'a Skip on cluster 1 leaves ALL its members untouched; cluster 2 still tags', function()
		-- if the loop fire-and-forgot (never waited / ignored the result), cluster 1
		-- would get tagged anyway. This proves it gates on the return value.
		local r = recorder { false, 'Sula nebouxii' } -- cluster1=Skip, cluster2=name
		local out = TagRun.run {
			items = items( 4 ), cfg = baseCfg(),
			cluster = fixedClusters { { 1, 2 }, { 3, 4 } },
			hashFiles = function( f ) local h = {}; for i = 1, #f do h[ i ] = 'x' end; return h end,
			tag = r.deps.tag, cancelled = r.deps.cancelled,
			resolve = r.deps.resolve, applyCluster = r.deps.applyCluster,
		}
		assert.equal( 2, #r.tagCalls ) -- still one tag per cluster
		assert.equal( 1, #r.applied ) -- only cluster 2 written
		assert.same( { 3, 4 }, r.applied[ 1 ].ids )
		assert.equal( 2, out.applied )
		assert.equal( 2, out.skipped )
	end )

	it( 'a helper error on a cluster leaves it untouched (distinct from a Skip)', function()
		local r = recorder { { err = 'chrome missing' }, nil }
		local out = TagRun.run {
			items = items( 4 ), cfg = baseCfg(),
			cluster = fixedClusters { { 1, 2 }, { 3, 4 } },
			hashFiles = function( f ) local h = {}; for i = 1, #f do h[ i ] = 'x' end; return h end,
			tag = r.deps.tag, cancelled = r.deps.cancelled,
			resolve = r.deps.resolve, applyCluster = r.deps.applyCluster,
		}
		assert.equal( 1, #r.applied )
		assert.same( { 3, 4 }, r.applied[ 1 ].ids )
		assert.equal( 2, out.skipped )
		assert.truthy( out.lines[ 1 ]:match( 'not tagged' ) ) -- error, not "skipped"
	end )

	it( 'a GBIF miss leaves the cluster untouched', function()
		local r = recorder { '__miss__' }
		local out = TagRun.run {
			items = items( 2 ), cfg = baseCfg(),
			cluster = fixedClusters { { 1, 2 } },
			hashFiles = function( f ) return { 'x', 'x' } end,
			tag = r.deps.tag, cancelled = r.deps.cancelled,
			resolve = r.deps.resolve, applyCluster = r.deps.applyCluster,
		}
		assert.equal( 0, #r.applied )
		assert.equal( 2, out.skipped )
		assert.truthy( out.lines[ 1 ]:match( 'not found in GBIF' ) )
	end )
end )

describe( 'TagRun.run — degradation and controls', function()
	it( 'a render-failed representative is skipped WITHOUT calling tag', function()
		local r = recorder()
		local out = TagRun.run {
			items = items( 2, { failRender = 1 } ), cfg = baseCfg(),
			cluster = fixedClusters { { 1 }, { 2 } },
			hashFiles = function( f ) return { false, 'x' } end,
			tag = r.deps.tag, cancelled = r.deps.cancelled,
			resolve = r.deps.resolve, applyCluster = r.deps.applyCluster,
		}
		assert.equal( 1, #r.tagCalls ) -- only the renderable one reached tag
		assert.same( { '/tmp/img2.jpg' }, out.tagFiles )
		assert.equal( 1, out.applied )
		assert.equal( 1, out.skipped )
	end )

	it( 'with burst detection OFF, every photo is its own Lens read (per-photo behavior)', function()
		local r = recorder()
		local clusterCalled = false
		local out = TagRun.run {
			items = items( 3 ), cfg = baseCfg { burstDetect = false },
			cluster = function() clusterCalled = true; return {} end,
			hashFiles = function() error( 'must not hash when detection is off' ) end,
			tag = r.deps.tag, cancelled = r.deps.cancelled,
			resolve = r.deps.resolve, applyCluster = r.deps.applyCluster,
		}
		assert.is_false( clusterCalled ) -- no clustering when off
		assert.equal( 3, #r.tagCalls )
		assert.equal( 3, out.clusters )
	end )

	it( 'stops issuing tags once progress is canceled', function()
		local r = recorder()
		local n = 0
		local out = TagRun.run {
			items = items( 6 ), cfg = baseCfg(),
			cluster = fixedClusters { { 1, 2 }, { 3, 4 }, { 5, 6 } },
			hashFiles = function( f ) local h = {}; for i = 1, #f do h[ i ] = 'x' end; return h end,
			progress = { canceled = function() n = n + 1; return n > 2 end }, -- cancel after cluster 1
			tag = r.deps.tag, cancelled = r.deps.cancelled,
			resolve = r.deps.resolve, applyCluster = r.deps.applyCluster,
		}
		assert.equal( 1, #r.tagCalls )
		assert.equal( 2, out.applied )
	end )

	it( 'hashes once over all files and feeds the fingerprints into clustering', function()
		local seenFrames, seenFiles
		TagRun.run {
			items = items( 3 ), cfg = baseCfg(),
			hashFiles = function( files ) seenFiles = files; return { 'h1', 'h2', 'h3' } end,
			cluster = function( frames ) seenFrames = frames; return { { 1, 2, 3 } } end,
			tag = function() return 'X' end, cancelled = CANCELLED,
			resolve = function( n ) return { ok = true, plan = {}, taxon = { scientificName = n } } end,
			applyCluster = function() end,
		}
		assert.same( { '/tmp/img1.jpg', '/tmp/img2.jpg', '/tmp/img3.jpg' }, seenFiles )
		assert.equal( 'h1', seenFrames[ 1 ].hash )
		assert.equal( 'h3', seenFrames[ 3 ].hash )
	end )

	it( 'falls back to per-photo when fingerprinting is unavailable (hashFiles -> nil)', function()
		-- real clustering with no hashes => every frame a singleton
		local Burst = require 'Burst'
		local r = recorder()
		local out = TagRun.run {
			items = items( 3 ), cfg = baseCfg(),
			hashFiles = function() return nil end, -- helper couldn't run
			cluster = Burst.cluster,
			tag = r.deps.tag, cancelled = r.deps.cancelled,
			resolve = r.deps.resolve, applyCluster = r.deps.applyCluster,
		}
		assert.equal( 3, out.clusters ) -- singletons
		assert.equal( 3, #r.tagCalls )
	end )
end )
