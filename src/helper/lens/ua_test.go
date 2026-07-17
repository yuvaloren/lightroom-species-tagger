package lens

import (
	"encoding/json"
	"testing"

	"github.com/yuvaloren/lightroom-species-tagger/helper/chrome"
)

// Golden tests for the UA + Client Hints surface. This is invisible to the
// fake-Google integration tests in any obvious way — but when it's wrong,
// real Google serves a degraded Lens page. Pin every platform's exact output.
func TestUserAgentGoldens(t *testing.T) {
	ver := chrome.Version{Full: "138.0.7204.49", Major: "138"}
	cases := []struct {
		goos, goarch string
		wantUA       string
		wantMD       string
	}{
		{
			"darwin", "arm64",
			"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
			`{"brands":[{"brand":"Chromium","version":"138"},{"brand":"Google Chrome","version":"138"},{"brand":"Not?A_Brand","version":"24"}],"fullVersion":"138.0.7204.49","fullVersionList":[{"brand":"Chromium","version":"138.0.7204.49"},{"brand":"Google Chrome","version":"138.0.7204.49"},{"brand":"Not?A_Brand","version":"24.0.0.0"}],"platform":"macOS","platformVersion":"15.0.0","architecture":"arm","bitness":"64","model":"","mobile":false}`,
		},
		{
			"windows", "amd64",
			"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
			`{"brands":[{"brand":"Chromium","version":"138"},{"brand":"Google Chrome","version":"138"},{"brand":"Not?A_Brand","version":"24"}],"fullVersion":"138.0.7204.49","fullVersionList":[{"brand":"Chromium","version":"138.0.7204.49"},{"brand":"Google Chrome","version":"138.0.7204.49"},{"brand":"Not?A_Brand","version":"24.0.0.0"}],"platform":"Windows","platformVersion":"10.0.0","architecture":"x86","bitness":"64","model":"","mobile":false}`,
		},
		{
			"windows", "arm64",
			"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
			`{"brands":[{"brand":"Chromium","version":"138"},{"brand":"Google Chrome","version":"138"},{"brand":"Not?A_Brand","version":"24"}],"fullVersion":"138.0.7204.49","fullVersionList":[{"brand":"Chromium","version":"138.0.7204.49"},{"brand":"Google Chrome","version":"138.0.7204.49"},{"brand":"Not?A_Brand","version":"24.0.0.0"}],"platform":"Windows","platformVersion":"10.0.0","architecture":"arm","bitness":"64","model":"","mobile":false}`,
		},
		{
			"linux", "amd64",
			"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
			`{"brands":[{"brand":"Chromium","version":"138"},{"brand":"Google Chrome","version":"138"},{"brand":"Not?A_Brand","version":"24"}],"fullVersion":"138.0.7204.49","fullVersionList":[{"brand":"Chromium","version":"138.0.7204.49"},{"brand":"Google Chrome","version":"138.0.7204.49"},{"brand":"Not?A_Brand","version":"24.0.0.0"}],"platform":"Linux","platformVersion":"","architecture":"x86","bitness":"64","model":"","mobile":false}`,
		},
	}
	for _, c := range cases {
		ua, md := UserAgentFor(c.goos, c.goarch, ver)
		if ua != c.wantUA {
			t.Errorf("%s/%s UA:\n got %s\nwant %s", c.goos, c.goarch, ua, c.wantUA)
		}
		got, err := json.Marshal(md)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != c.wantMD {
			t.Errorf("%s/%s metadata:\n got %s\nwant %s", c.goos, c.goarch, got, c.wantMD)
		}
	}
}
