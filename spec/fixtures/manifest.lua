--[[----------------------------------------------------------------------------
spec/fixtures/manifest.lua
The labelled test corpus. Each case pairs a recorded provider response with the
ground-truth species that should come out of the pipeline. The offline harness
(spec/accuracy_spec.lua + scripts/accuracy.lua) replays these — no network, no
API keys — so accuracy is a deterministic regression gate.

The species + images come from the @yuvalsaw Instagram captions (the owner's own
posts; see spec/fixtures/groundtruth/yuvalsaw.lua for the full labelled set).
Add or refresh cases with scripts/build-corpus.lua.

NOTE: the GBIF fixtures are REAL captures from api.gbif.org (so genus/family are
authoritative). The Lens responses are REPRESENTATIVE — each mirrors the JSON
Google embeds in a Lens results page (the AF_initDataCallback `data` array the
direct backend harvests), seeded from the real species names plus noise — so the
suite runs offline out of the box. Record live ones with scripts/record-fixture.lua
from a residential connection (Google blocks datacenter IPs). The `common` field
is GBIF's preferred vernacular and is informational; the gate checks scientific,
genus and family.
------------------------------------------------------------------------------]]

return {
	{
		id = 'spotfin_porcupinefish_lens',
		image = '18118084048758540.jpg',
		provider = 'lens',
		response = 'lens/spotfin_porcupinefish.json',
		expected = {
			{ common = 'Spot-fin porcupinefish', scientific = 'Diodon hystrix', genus = 'Diodon', family = 'Diodontidae' },
		},
	},
	{
		id = 'spotted_linckia_lens',
		image = '18398736889152502.jpg',
		provider = 'lens',
		response = 'lens/spotted_linckia.json',
		expected = {
			{ common = 'Multipore sea star', scientific = 'Linckia multifora', genus = 'Linckia', family = 'Ophidiasteridae' },
		},
	},
	{
		id = 'reef_octopus_triggerfish_lens',
		image = '18169200037427762.jpg',
		provider = 'lens',
		response = 'lens/reef_octopus_triggerfish.json',
		expected = {
			{ common = 'Day octopus', scientific = 'Octopus cyanea', genus = 'Octopus', family = 'Octopodidae' },
			{ common = 'Lei triggerfish', scientific = 'Sufflamen bursa', genus = 'Sufflamen', family = 'Balistidae' },
		},
	},
	{
		id = 'snowflake_moray_lens',
		image = '18097003880239640.jpg',
		provider = 'lens',
		response = 'lens/snowflake_moray.json',
		expected = {
			{ common = 'Snowflake moray', scientific = 'Echidna nebulosa', genus = 'Echidna', family = 'Muraenidae' },
		},
	},
	{
		id = 'african_buffalo_lens',
		image = '18123724987543504.jpg',
		provider = 'lens',
		response = 'lens/african_buffalo.json',
		expected = {
			{ common = 'African buffalo', scientific = 'Syncerus caffer', genus = 'Syncerus', family = 'Bovidae' },
		},
	},
	{
		id = 'california_golden_gorgonian_lens',
		image = '17905787328167859.jpg',
		provider = 'lens',
		response = 'lens/california_golden_gorgonian.json',
		expected = {
			{ common = 'California golden gorgonian', scientific = 'Muricea californica', genus = 'Muricea', family = 'Plexauridae' },
		},
	},
	{
		id = 'ocean_sunfish_lens',
		image = '18049851059441667.jpg',
		provider = 'lens',
		response = 'lens/ocean_sunfish.json',
		expected = {
			{ common = 'Ocean sunfish', scientific = 'Mola mola', genus = 'Mola', family = 'Molidae' },
		},
	},
	{
		id = 'hooded_nudibranch_lens',
		image = '18137893420479323.jpg',
		provider = 'lens',
		response = 'lens/hooded_nudibranch.json',
		expected = {
			{ common = 'Hooded nudibranch', scientific = 'Melibe leonina', genus = 'Melibe', family = 'Tethydidae' },
		},
	},
	{
		id = 'bornean_orangutan_lens',
		image = '18103507690702609.jpg',
		provider = 'lens',
		response = 'lens/bornean_orangutan.json',
		expected = {
			{ common = 'Bornean orangutan', scientific = 'Pongo pygmaeus', genus = 'Pongo', family = 'Hominidae' },
		},
	},
	{
		id = 'wolf_eel_lens',
		image = '18052542377412770.jpg',
		provider = 'lens',
		response = 'lens/wolf_eel.json',
		expected = {
			{ common = 'Wolf-eel', scientific = 'Anarrhichthys ocellatus', genus = 'Anarrhichthys', family = 'Anarhichadidae' },
		},
	},
	{
		id = 'bald_eagle_lens',
		image = '18061071692296720.jpg',
		provider = 'lens',
		response = 'lens/bald_eagle.json',
		expected = {
			{ common = 'Bald eagle', scientific = 'Haliaeetus leucocephalus', genus = 'Haliaeetus', family = 'Accipitridae' },
		},
	},
	{
		-- Same dive frame, the Vision backend (representative Web Detection response).
		id = 'reef_octopus_triggerfish_vision',
		image = '18169200037427762.jpg',
		provider = 'vision',
		response = 'vision/reef_octopus_triggerfish.json',
		expected = {
			{ common = 'Day octopus', scientific = 'Octopus cyanea', genus = 'Octopus', family = 'Octopodidae' },
			{ common = 'Lei triggerfish', scientific = 'Sufflamen bursa', genus = 'Sufflamen', family = 'Balistidae' },
		},
	},
}
