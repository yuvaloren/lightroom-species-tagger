local Render = require 'Render'

--[[
Pins the export settings TagSpecies hands LrExportSession. These replaced
photo:requestJpegThumbnail, whose preview-cache answers were unreliable in the
Develop module (blank/stale first callback, "error loading thumb", or no
callback at all — see shared/Render.lua). The specs can't drive a real export;
what they CAN guard is that the settings keep every promise the plugin makes:
a downsized sRGB JPEG, EXIF/GPS stripped, written to our folder and never
re-imported — and that a settings edit can't silently open a dialog
(collision "ask") or enlarge a small photo.
]]

describe( 'Render.exportSettings', function()
	local s = Render.exportSettings { maxEdge = 1024, outDir = '/tmp/speciestagger-run' }

	it( 'renders to the hard-drive service as an sRGB JPEG', function()
		assert.equal( 'com.adobe.ag.export.file', s.LR_exportServiceProvider )
		assert.equal( 'JPEG', s.LR_format )
		assert.equal( 'sRGB', s.LR_export_colorSpace )
		assert.is_true( s.LR_jpeg_quality > 0.5 and s.LR_jpeg_quality <= 1 )
		assert.is_false( s.LR_jpeg_useLimitSize )
	end )

	it( 'fits the photo inside maxEdge on both axes and never enlarges', function()
		assert.is_true( s.LR_size_doConstrain )
		assert.is_true( s.LR_size_doNotEnlarge )
		assert.equal( 'wh', s.LR_size_resizeType )
		assert.equal( 1024, s.LR_size_maxWidth )
		assert.equal( 1024, s.LR_size_maxHeight )
		assert.equal( 'pixels', s.LR_size_units )
		assert.is_false( s.LR_outputSharpeningOn )
	end )

	it( 'honours a different maxEdge', function()
		local t = Render.exportSettings { maxEdge = 2048, outDir = '/x' }
		assert.equal( 2048, t.LR_size_maxWidth )
		assert.equal( 2048, t.LR_size_maxHeight )
	end )

	it( 'strips EXIF, camera, location and face metadata (the privacy promise)', function()
		assert.equal( 'copyrightOnly', s.LR_embeddedMetadataOption )
		assert.is_true( s.LR_minimizeEmbeddedMetadata )
		assert.is_true( s.LR_removeLocationMetadata )
		assert.is_true( s.LR_removeFaceMetadata )
		assert.is_false( s.LR_includeFaceTagsAsKeywords )
		assert.is_false( s.LR_useWatermark )
	end )

	it( 'writes into our own folder, keeps original names, renames collisions', function()
		assert.equal( 'specificFolder', s.LR_export_destinationType )
		assert.equal( '/tmp/speciestagger-run', s.LR_export_destinationPathPrefix )
		assert.is_false( s.LR_export_useSubfolder )
		assert.is_false( s.LR_renamingTokensOn )
		-- "ask" would pop a dialog mid-run; "overwrite"/"skip" would alias two
		-- same-named photos from different folders onto one file.
		assert.equal( 'rename', s.LR_collisionHandling )
	end )

	it( 'never re-imports, post-processes, or includes video', function()
		assert.is_false( s.LR_reimportExportedPhoto )
		assert.equal( 'doNothing', s.LR_export_postProcessing )
		assert.is_false( s.LR_includeVideoFiles )
	end )

	it( 'requires an output folder (a nil prefix would export who-knows-where)', function()
		assert.has_error( function() Render.exportSettings { maxEdge = 1024 } end )
		assert.has_error( function() Render.exportSettings { maxEdge = 1024, outDir = '' } end )
	end )

	it( 'defaults maxEdge to 1024 when absent or unparsable', function()
		assert.equal( 1024, Render.exportSettings( { outDir = '/x' } ).LR_size_maxWidth )
		assert.equal( 1024, Render.exportSettings( { outDir = '/x', maxEdge = 'abc' } ).LR_size_maxWidth )
	end )
end )
