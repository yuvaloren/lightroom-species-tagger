// lens-helper — assistive Google Lens helper for the Species Tagger
// Lightroom plugin. No scraping, no paid API, no login: it opens Google's
// real results in the user's VISIBLE Chrome and returns only the text the
// user highlighted. Go replacement for the old bundled-Node lens-search.js —
// same argv/env contract, same one-JSON-line stdout contract.
//
//	lens-helper <image.jpg>          tag one photo (blocks on the user)
//	LENS_ASSIST_CLOSE=1 lens-helper  close the reused window cleanly
//
// Output (stdout): { ok:true, name } | { ok:false, cancelled|error } |
// { ok:true, closed:true }. ALWAYS exit 0 — the Lua caller reads the JSON,
// not the exit code (see src/shared/Http.lua runHelper).
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/yuvaloren/lightroom-species-tagger/helper/lens"
)

func main() {
	cfg := lens.FromEnv(os.Args[1:])
	res := lens.Run(cfg)
	line, err := json.Marshal(res)
	if err != nil { // unreachable in practice; keep the contract anyway
		line = []byte(`{"ok":false,"error":"helper could not encode its result"}`)
	}
	fmt.Println(string(line))
	os.Exit(0)
}
