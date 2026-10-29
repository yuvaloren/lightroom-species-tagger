--[[----------------------------------------------------------------------------
Render.lua
The export settings the plugin hands Lightroom to render each selected photo
into the downsized JPEG that Google Lens is shown. Pure (no Lr* imports): it
only builds the settings table; TagSpecies.lua feeds it to LrExportSession.

WHY THE EXPORT PIPELINE AND NOT photo:requestJpegThumbnail (the bug it pins):
requestJpegThumbnail answers from Lightroom's PREVIEW CACHE, and that cache is
not a reliable picture of the photo. In the Develop module — or in Library
right after a Develop edit, before Lightroom has rebuilt the preview — the call
is known (Adobe SDK forums, many plugin authors) to:
  * fire its callback with a placeholder first (a blank/white image, or the
    stale pre-edit preview) and only later with the real render — our wait
    took the FIRST answer as final, so Lens was shown a blank or an old crop;
  * answer "error loading thumb" while the preview is being rebuilt;
  * never call back at all when it has to build the preview from scratch,
    which stalled the run 60 s per photo and then reported a timeout.
A real export renders from the negative with the CURRENT develop settings, in
every module, and yields exactly one file per photo — or a definite error.

exportSettings( opts ) -> table   opts = { maxEdge = <px>, outDir = <folder> }
  Fits the photo inside maxEdge × maxEdge (never enlarged), sRGB JPEG, no
  sharpening, no watermark, EXIF/camera/GPS/face metadata stripped (the
  copyright field is the one thing Lightroom cannot be told to drop), written
  to outDir under the original file name with collisions renamed, nothing
  re-imported. Every key is a documented export-preset key.
------------------------------------------------------------------------------]]

local M = {}

M.DEFAULT_QUALITY = 0.85

function M.exportSettings( opts )
	opts = opts or {}
	local maxEdge = tonumber( opts.maxEdge ) or 1024
	assert( type( opts.outDir ) == 'string' and opts.outDir ~= '', 'Render.exportSettings: outDir is required' )
	return {
		-- the built-in "Hard Drive" service: render to files, no upload step
		LR_exportServiceProvider = 'com.adobe.ag.export.file',
		LR_exportServiceProviderTitle = 'Hard Drive',

		-- file
		LR_format = 'JPEG',
		LR_jpeg_quality = M.DEFAULT_QUALITY,
		LR_jpeg_useLimitSize = false,
		LR_export_colorSpace = 'sRGB',
		LR_extensionCase = 'lowercase',

		-- size: fit inside maxEdge × maxEdge, never enlarge
		LR_size_doConstrain = true,
		LR_size_doNotEnlarge = true,
		LR_size_resizeType = 'wh',
		LR_size_maxWidth = maxEdge,
		LR_size_maxHeight = maxEdge,
		LR_size_units = 'pixels',
		LR_size_resolution = 72,
		LR_size_resolutionUnits = 'inch',
		LR_outputSharpeningOn = false,

		-- metadata: strip everything Lightroom lets us strip
		LR_embeddedMetadataOption = 'copyrightOnly',
		LR_minimizeEmbeddedMetadata = true,
		LR_removeLocationMetadata = true,
		LR_removeFaceMetadata = true,
		LR_includeFaceTagsAsKeywords = false,
		LR_includeFaceTagsInIptc = false,
		LR_useWatermark = false,

		-- destination: a private folder of ours, original names, collisions renamed
		LR_export_destinationType = 'specificFolder',
		LR_export_destinationPathPrefix = opts.outDir,
		LR_export_useSubfolder = false,
		LR_export_useParentFolder = false,
		LR_collisionHandling = 'rename',
		LR_renamingTokensOn = false,

		-- never touch the catalog or launch anything afterwards
		LR_reimportExportedPhoto = false,
		LR_export_postProcessing = 'doNothing',
		LR_includeVideoFiles = false,
		LR_export_videoFileHandling = 'exclude',
	}
end

return M
