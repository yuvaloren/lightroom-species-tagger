--[[----------------------------------------------------------------------------
PhotoMeta.lua
Reads the per-photo metadata the assist run needs from an LrPhoto: the display
label (file name) and — when burst detection is on — the capture time and
camera serial that Burst.cluster gates on. Pure in the shared/ sense: no Lr*
imports; the LrPhoto comes in as an argument and only its two documented
getters are called.

WHY THIS FILE EXISTS (the bug it pins): Lightroom's metadata getters
(getRawMetadata / getFormattedMetadata) YIELD internally — they suspend the
calling task while Lightroom takes catalog read access. Lua 5.1 cannot yield
across a plain pcall (it raises "attempt to yield across metamethod/C-call
boundary"), so wrapping these getters in pcall does not protect them — it
makes them FAIL EVERY TIME, silently. That is exactly what shipped: every
frame lost its capture time, Burst.cluster degraded every frame to a
singleton (its documented can't-prove-it fallback), and burst detection never
grouped anything in the field while every headless spec stayed green (fakes
don't yield). photometa_spec.lua reproduces the yield with coroutine fakes so
that regression stays caught.

So: NO pcall here, on purpose. These getters don't throw for valid literal
keys — and if one ever does, the run's top-level LrTasks.pcall (the menu
item's) surfaces it as an error dialog, which beats another 12 days of
silently-broken grouping.

read( photo, wantBurst ) -> { label, t, serial }
  label   file name, or '(photo)' when Lightroom has none to give
  t       capture time in seconds (getRawMetadata 'dateTimeOriginal'), only
          when wantBurst and the photo has one
  serial  camera serial string, only when wantBurst and non-empty
------------------------------------------------------------------------------]]

local M = {}

function M.read( photo, wantBurst )
	local out = {}
	out.label = photo:getFormattedMetadata( 'fileName' ) or '(photo)'
	if wantBurst then
		local tv = photo:getRawMetadata( 'dateTimeOriginal' )
		if type( tv ) == 'number' then out.t = tv end
		local sv = photo:getFormattedMetadata( 'cameraSerialNumber' )
		if type( sv ) == 'string' and sv ~= '' then out.serial = sv end
	end
	return out
end

return M
