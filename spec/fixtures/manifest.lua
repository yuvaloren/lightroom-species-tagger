--[[----------------------------------------------------------------------------
spec/fixtures/manifest.lua
The labelled test corpus. Each case pairs a recorded Google Lens response with the
ground-truth species that should come out of the pipeline. The offline harness
(spec/accuracy_spec.lua + scripts/accuracy.lua) replays these — no network, no
API keys — so accuracy is a deterministic regression gate.

The corpus is a hand-picked set of well-known species spanning several phyla
(fish, cephalopods, echinoderms, cnidarians, mammals, birds). None of the data is
tied to any person or account: the `image` fields are descriptive slugs (the
offline suite replays recorded JSON, not pixels), the GBIF responses are REAL
captures from api.gbif.org (so genus/family are authoritative), and the Lens
responses are REPRESENTATIVE — each mirrors the shape of what the Lens helper
harvests (an AI-Overview line naming the species + visual-match titles), seeded
from the correct names plus realistic noise, so the suite runs offline out of the
box. Rebuild the representative fixtures with `scripts/build-corpus.lua --corpus`;
record REAL Lens captures with `scripts/record-fixture.lua` from a residential
connection (Google blocks datacenter IPs). The `common` field is informational;
the gate checks scientific name, genus and family.
------------------------------------------------------------------------------]]

return {
	{
		id = 'spotfin_porcupinefish_lens',
		image = 'spotfin_porcupinefish.jpg',
		provider = 'lens',
		response = 'lens/spotfin_porcupinefish.json',
		expected = {
			{ common = 'Spot-fin porcupinefish', scientific = 'Diodon hystrix', genus = 'Diodon', family = 'Diodontidae' },
		},
	},
	{
		id = 'spotted_linckia_lens',
		image = 'spotted_linckia.jpg',
		provider = 'lens',
		response = 'lens/spotted_linckia.json',
		expected = {
			{ common = 'Multipore sea star', scientific = 'Linckia multifora', genus = 'Linckia', family = 'Ophidiasteridae' },
		},
	},
	{
		id = 'reef_octopus_triggerfish_lens',
		image = 'reef_octopus_triggerfish.jpg',
		provider = 'lens',
		response = 'lens/reef_octopus_triggerfish.json',
		expected = {
			{ common = 'Day octopus', scientific = 'Octopus cyanea', genus = 'Octopus', family = 'Octopodidae' },
			{ common = 'Lei triggerfish', scientific = 'Sufflamen bursa', genus = 'Sufflamen', family = 'Balistidae' },
		},
	},
	{
		id = 'snowflake_moray_lens',
		image = 'snowflake_moray.jpg',
		provider = 'lens',
		response = 'lens/snowflake_moray.json',
		expected = {
			{ common = 'Snowflake moray', scientific = 'Echidna nebulosa', genus = 'Echidna', family = 'Muraenidae' },
		},
	},
	{
		id = 'african_buffalo_lens',
		image = 'african_buffalo.jpg',
		provider = 'lens',
		response = 'lens/african_buffalo.json',
		expected = {
			{ common = 'African buffalo', scientific = 'Syncerus caffer', genus = 'Syncerus', family = 'Bovidae' },
		},
	},
	{
		id = 'california_golden_gorgonian_lens',
		image = 'california_golden_gorgonian.jpg',
		provider = 'lens',
		response = 'lens/california_golden_gorgonian.json',
		expected = {
			{ common = 'California golden gorgonian', scientific = 'Muricea californica', genus = 'Muricea', family = 'Plexauridae' },
		},
	},
	{
		id = 'ocean_sunfish_lens',
		image = 'ocean_sunfish.jpg',
		provider = 'lens',
		response = 'lens/ocean_sunfish.json',
		expected = {
			{ common = 'Ocean sunfish', scientific = 'Mola mola', genus = 'Mola', family = 'Molidae' },
		},
	},
	{
		id = 'hooded_nudibranch_lens',
		image = 'hooded_nudibranch.jpg',
		provider = 'lens',
		response = 'lens/hooded_nudibranch.json',
		expected = {
			{ common = 'Hooded nudibranch', scientific = 'Melibe leonina', genus = 'Melibe', family = 'Tethydidae' },
		},
	},
	{
		id = 'bornean_orangutan_lens',
		image = 'bornean_orangutan.jpg',
		provider = 'lens',
		response = 'lens/bornean_orangutan.json',
		expected = {
			{ common = 'Bornean orangutan', scientific = 'Pongo pygmaeus', genus = 'Pongo', family = 'Hominidae' },
		},
	},
	{
		id = 'wolf_eel_lens',
		image = 'wolf_eel.jpg',
		provider = 'lens',
		response = 'lens/wolf_eel.json',
		expected = {
			{ common = 'Wolf-eel', scientific = 'Anarrhichthys ocellatus', genus = 'Anarrhichthys', family = 'Anarhichadidae' },
		},
	},
	{
		id = 'bald_eagle_lens',
		image = 'bald_eagle.jpg',
		provider = 'lens',
		response = 'lens/bald_eagle.json',
		expected = {
			{ common = 'Bald eagle', scientific = 'Haliaeetus leucocephalus', genus = 'Haliaeetus', family = 'Accipitridae' },
		},
	},
}
