package cdp

import "encoding/json"

// Brand is one entry of a Sec-CH-UA brand list.
type Brand struct {
	Brand   string `json:"brand"`
	Version string `json:"version"`
}

// UAMetadata mirrors Emulation.setUserAgentOverride's userAgentMetadata —
// the Client Hints that must agree with the UA string, or Google serves the
// degraded Lens page. Field-for-field the shape puppeteer sends.
type UAMetadata struct {
	Brands          []Brand `json:"brands"`
	FullVersion     string  `json:"fullVersion"`
	FullVersionList []Brand `json:"fullVersionList"`
	Platform        string  `json:"platform"`
	PlatformVersion string  `json:"platformVersion"`
	Architecture    string  `json:"architecture"`
	Bitness         string  `json:"bitness"`
	Model           string  `json:"model"`
	Mobile          bool    `json:"mobile"`
}

// TargetInfo is one entry from Target.getTargets.
type TargetInfo struct {
	TargetID string `json:"targetId"`
	Type     string `json:"type"`
	URL      string `json:"url"`
	Attached bool   `json:"attached"`
}

// RemoteObject is Runtime.evaluate's result object (the subset we use).
type RemoteObject struct {
	Type     string          `json:"type"`
	Subtype  string          `json:"subtype"`
	Value    json.RawMessage `json:"value"`
	ObjectID string          `json:"objectId"`
}

// FrameNavigatedParams is Page.frameNavigated's payload (subset).
type FrameNavigatedParams struct {
	Frame struct {
		ID       string `json:"id"`
		ParentID string `json:"parentId"`
		URL      string `json:"url"`
	} `json:"frame"`
}
