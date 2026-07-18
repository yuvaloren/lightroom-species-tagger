--[[----------------------------------------------------------------------------
photometa_spec.lua
Pins PhotoMeta.read against the Lightroom behavior that broke burst detection
in the field: LrPhoto metadata getters YIELD (they suspend the task while
Lightroom takes catalog read access). Lua 5.1 cannot yield across a plain
pcall, so a pcall-wrapped getter fails on EVERY call — every frame loses its
capture time, and Burst.cluster (correctly) degrades every frame to a
singleton. Headless fakes that return immediately can never see this; these
fakes yield first, exactly like the real SDK, and the harness plays
Lightroom's task scheduler.
------------------------------------------------------------------------------]]

local PhotoMeta = require 'PhotoMeta'

-- A fake LrPhoto whose getters yield once before answering — the shape of the
-- real SDK call. `meta` maps key -> value for both getters.
local function yieldingPhoto( meta )
	return {
		getFormattedMetadata = function( _, key )
			coroutine.yield( 'read-access' )
			return meta[ key ]
		end,
		getRawMetadata = function( _, key )
			coroutine.yield( 'read-access' )
			return meta[ key ]
		end,
	}
end

-- Run `fn` the way Lightroom runs plugin code: on a task the scheduler resumes
-- whenever it yields. Errors propagate, like the SDK's.
local function runAsLightroomTask( fn )
	local co = coroutine.create( fn )
	local ok, res = coroutine.resume( co )
	while ok and coroutine.status( co ) ~= 'dead' do
		ok, res = coroutine.resume( co )
	end
	assert( ok, res )
	return res
end

describe( 'PhotoMeta.read', function()

	it( 'reads label, capture time and serial through yielding getters', function()
		-- 0G2A2982.CR3, the real field case: same-second burst frame whose
		-- capture time never survived the pcall wrapper.
		local photo = yieldingPhoto {
			fileName = '0G2A2982.CR3',
			dateTimeOriginal = 772717960,
			cameraSerialNumber = '143202100162',
		}
		local got = runAsLightroomTask( function() return PhotoMeta.read( photo, true ) end )
		assert.same( { label = '0G2A2982.CR3', t = 772717960, serial = '143202100162' }, got )
	end )

	it( 'skips the burst reads when burst detection is off', function()
		local calls = 0
		local photo = {
			getFormattedMetadata = function( _, key )
				coroutine.yield( 'read-access' )
				calls = calls + 1
				assert.equal( 'fileName', key ) -- never cameraSerialNumber
				return 'IMG_0001.JPG'
			end,
			getRawMetadata = function()
				error( 'getRawMetadata must not be called when burst detection is off' )
			end,
		}
		local got = runAsLightroomTask( function() return PhotoMeta.read( photo, false ) end )
		assert.same( { label = 'IMG_0001.JPG' }, got )
		assert.equal( 1, calls )
	end )

	it( 'degrades missing metadata to absent fields, not errors', function()
		-- No capture time, no serial (e.g. a scan): the frame must come back
		-- untimed — Burst.cluster then makes it a singleton, by design.
		local photo = yieldingPhoto { fileName = 'scan-042.tif' }
		local got = runAsLightroomTask( function() return PhotoMeta.read( photo, true ) end )
		assert.same( { label = 'scan-042.tif' }, got )
	end )

	it( 'falls back to a placeholder label when Lightroom has no file name', function()
		local got = runAsLightroomTask( function()
			return PhotoMeta.read( yieldingPhoto {}, false )
		end )
		assert.same( { label = '(photo)' }, got )
	end )

	it( 'treats an empty serial as absent', function()
		local photo = yieldingPhoto {
			fileName = 'a.jpg', dateTimeOriginal = 100, cameraSerialNumber = '',
		}
		local got = runAsLightroomTask( function() return PhotoMeta.read( photo, true ) end )
		assert.same( { label = 'a.jpg', t = 100 }, got )
	end )
end )
