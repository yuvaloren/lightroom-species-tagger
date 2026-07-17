package lens

import (
	"fmt"

	"github.com/yuvaloren/lightroom-species-tagger/helper/cdp"
	"github.com/yuvaloren/lightroom-species-tagger/helper/chrome"
)

// UserAgentFor builds the UA string + Client Hints metadata matched to the
// REAL installed Chrome, so Google serves the normal results page (a
// HeadlessChrome UA, or a UA whose major disagrees with the Client Hints,
// gets a degraded/blocked variant). About rendering the real page correctly,
// not disguise — the window is visible the whole time.
//
// goos/goarch are parameters (not runtime.GOOS) so the golden tests can pin
// every platform's exact output from any CI runner.
func UserAgentFor(goos, goarch string, ver chrome.Version) (string, *cdp.UAMetadata) {
	var uaOS, chPlatform, chPlatformVer string
	switch goos {
	case "windows":
		uaOS, chPlatform, chPlatformVer = "Windows NT 10.0; Win64; x64", "Windows", "10.0.0"
	case "darwin":
		uaOS, chPlatform, chPlatformVer = "Macintosh; Intel Mac OS X 10_15_7", "macOS", "15.0.0"
	default:
		uaOS, chPlatform, chPlatformVer = "X11; Linux x86_64", "Linux", ""
	}
	ua := fmt.Sprintf("Mozilla/5.0 (%s) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s.0.0.0 Safari/537.36",
		uaOS, ver.Major)
	arch := "x86"
	if goarch == "arm64" {
		arch = "arm"
	}
	md := &cdp.UAMetadata{
		Brands: []cdp.Brand{
			{Brand: "Chromium", Version: ver.Major},
			{Brand: "Google Chrome", Version: ver.Major},
			{Brand: "Not?A_Brand", Version: "24"},
		},
		FullVersion: ver.Full,
		FullVersionList: []cdp.Brand{
			{Brand: "Chromium", Version: ver.Full},
			{Brand: "Google Chrome", Version: ver.Full},
			{Brand: "Not?A_Brand", Version: "24.0.0.0"},
		},
		Platform:        chPlatform,
		PlatformVersion: chPlatformVer,
		Architecture:    arch,
		Bitness:         "64",
		Model:           "",
		Mobile:          false,
	}
	return ua, md
}
