package imghash

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"math/bits"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// deterministic synthetic images (no math/rand: a fixed LCG keeps the pixel
// stream identical everywhere, forever)

type lcg uint64

func (l *lcg) next() uint64 { *l = *l*6364136223846793005 + 1442695040888963407; return uint64(*l) }

func synthetic(w, h int, seed uint64, gradient bool) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	r := lcg(seed)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			var v uint8
			if gradient {
				v = uint8((x*255/w + y*64/h) % 256)
			} else {
				v = uint8(r.next() >> 32)
			}
			img.Set(x, y, color.RGBA{v, v, v, 255})
		}
	}
	return img
}

func flat(w, h int, v uint8) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{v, v, v, 255})
		}
	}
	return img
}

func encodeJPEG(t *testing.T, img image.Image, quality int) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: quality}); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func writeJPEG(t *testing.T, dir, name string, img image.Image, quality int) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, encodeJPEG(t, img, quality), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// fingerprint plane helpers, mirroring Burst.lua's reading side

func splitFP(t *testing.T, fp string) (uint64, []byte) {
	t.Helper()
	parts := strings.Split(fp, ":")
	if len(parts) != 2 || len(parts[0]) != 16 || len(parts[1]) != 144 {
		t.Fatalf("malformed fingerprint %q", fp)
	}
	d, err := strconv.ParseUint(parts[0], 16, 64)
	if err != nil {
		t.Fatalf("bad dHash hex %q: %v", parts[0], err)
	}
	levels := make([]byte, 72)
	for i := 0; i < 72; i++ {
		v, err := strconv.ParseUint(parts[1][2*i:2*i+2], 16, 8)
		if err != nil {
			t.Fatalf("bad level hex: %v", err)
		}
		levels[i] = byte(v)
	}
	return d, levels
}

func gradientDist(t *testing.T, a, b string) int {
	t.Helper()
	da, _ := splitFP(t, a)
	db, _ := splitFP(t, b)
	return bits.OnesCount64(da ^ db)
}

func levelDist(t *testing.T, a, b string) float64 {
	t.Helper()
	_, la := splitFP(t, a)
	_, lb := splitFP(t, b)
	sum := 0.0
	for i := range la {
		d := int(la[i]) - int(lb[i])
		if d < 0 {
			d = -d
		}
		sum += float64(d)
	}
	return sum / 72
}

// ---------------------------------------------------------------------------
// fingerprint properties

func TestHashFileIdenticalBytesIdenticalFingerprint(t *testing.T) {
	dir := t.TempDir()
	img := synthetic(320, 240, 7, true)
	a := writeJPEG(t, dir, "a.jpg", img, 85)
	b := writeJPEG(t, dir, "b.jpg", img, 85)
	ha, err := HashFile(a)
	if err != nil {
		t.Fatal(err)
	}
	hb, err := HashFile(b)
	if err != nil {
		t.Fatal(err)
	}
	if ha != hb {
		t.Fatalf("same pixels, different fingerprint: %s vs %s", ha, hb)
	}
	splitFP(t, ha) // asserts the '<16 hex>:<144 hex>' shape
}

func TestReencodedVariantStaysNear(t *testing.T) {
	// The same frame through a different JPEG quality must stay well inside
	// the merge gates — this is the "burst frame re-rendered" regime.
	dir := t.TempDir()
	img := synthetic(320, 240, 7, true)
	ha, err := HashFile(writeJPEG(t, dir, "q85.jpg", img, 85))
	if err != nil {
		t.Fatal(err)
	}
	hb, err := HashFile(writeJPEG(t, dir, "q40.jpg", img, 40))
	if err != nil {
		t.Fatal(err)
	}
	if d := gradientDist(t, ha, hb); d > 6 {
		t.Fatalf("re-encode moved the gradient plane %d bits (want <= 6)", d)
	}
	if d := levelDist(t, ha, hb); d > 6 {
		t.Fatalf("re-encode moved the level plane %.1f (want <= 6)", d)
	}
}

func TestDifferentScenesFailTheMergeGate(t *testing.T) {
	// Mirrors Burst.lua's merge gate (gradient <= 20 AND level <= 20): two
	// unrelated scenes must fail at least one plane.
	dir := t.TempDir()
	grad := synthetic(320, 240, 7, true)
	noise := synthetic(320, 240, 99, false)
	ha, err := HashFile(writeJPEG(t, dir, "grad.jpg", grad, 85))
	if err != nil {
		t.Fatal(err)
	}
	hb, err := HashFile(writeJPEG(t, dir, "noise.jpg", noise, 85))
	if err != nil {
		t.Fatal(err)
	}
	if gradientDist(t, ha, hb) <= 20 && levelDist(t, ha, hb) <= 20 {
		t.Fatalf("unrelated scenes pass the merge gate: gradient=%d level=%.1f",
			gradientDist(t, ha, hb), levelDist(t, ha, hb))
	}
}

func TestFlatScenesDifferOnlyByLevel(t *testing.T) {
	// The corpus case that forced the two-plane design: two featureless
	// scenes have (deadbanded) gradient distance ~0, and ONLY the level
	// plane can split them. See Burst.lua's header.
	dir := t.TempDir()
	ha, err := HashFile(writeJPEG(t, dir, "dark.jpg", flat(320, 240, 90), 85))
	if err != nil {
		t.Fatal(err)
	}
	hb, err := HashFile(writeJPEG(t, dir, "light.jpg", flat(320, 240, 200), 85))
	if err != nil {
		t.Fatal(err)
	}
	if d := gradientDist(t, ha, hb); d != 0 {
		t.Fatalf("flat scenes should have identical gradient planes, got distance %d", d)
	}
	if d := levelDist(t, ha, hb); d < 60 {
		t.Fatalf("flat scenes 110 luma steps apart measure only %.1f on the level plane", d)
	}
}

func TestDeadbandAbsorbsLowTextureNoise(t *testing.T) {
	// Same flat level, different noise seeds: without the gradient deadband
	// these coin-flip up to ~30 bits; with it they must stay identical.
	dir := t.TempDir()
	mkNoisy := func(name string, seed uint64) string {
		img := image.NewRGBA(image.Rect(0, 0, 320, 240))
		r := lcg(seed)
		for y := 0; y < 240; y++ {
			for x := 0; x < 320; x++ {
				v := uint8(124 + (r.next() >> 61)) // 124..131: sensor-noise scale
				img.Set(x, y, color.RGBA{v, v, v, 255})
			}
		}
		return writeJPEG(t, dir, name, img, 85)
	}
	ha, err := HashFile(mkNoisy("n1.jpg", 1))
	if err != nil {
		t.Fatal(err)
	}
	hb, err := HashFile(mkNoisy("n2.jpg", 2))
	if err != nil {
		t.Fatal(err)
	}
	if d := gradientDist(t, ha, hb); d > 2 {
		t.Fatalf("noise flipped %d gradient bits despite the deadband", d)
	}
	if d := levelDist(t, ha, hb); d > 4 {
		t.Fatalf("noise moved the level plane %.1f", d)
	}
}

func TestTinyImageDoesNotPanic(t *testing.T) {
	// smaller than the 9×8 grid — the degenerate 1-px bands must hold
	dir := t.TempDir()
	if _, err := HashFile(writeJPEG(t, dir, "tiny.jpg", synthetic(4, 3, 1, true), 85)); err != nil {
		t.Fatal(err)
	}
}

// ---------------------------------------------------------------------------
// Run (the LENS_HASH list contract)

func writeList(t *testing.T, dir string, lines ...string) string {
	t.Helper()
	p := filepath.Join(dir, "list.txt")
	body := ""
	for _, l := range lines {
		body += l + "\n"
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRunHashesEveryLineInOrder(t *testing.T) {
	dir := t.TempDir()
	a := writeJPEG(t, dir, "a.jpg", synthetic(64, 48, 1, true), 85)
	b := writeJPEG(t, dir, "b.jpg", synthetic(64, 48, 2, false), 85)
	res := Run(writeList(t, dir, a, b))
	if !res.OK || len(res.Hashes) != 2 || res.Hashes[0] == nil || res.Hashes[1] == nil {
		t.Fatalf("unexpected result: %+v", res)
	}
	splitFP(t, *res.Hashes[0])
	splitFP(t, *res.Hashes[1])
}

func TestRunMissingAndUndecodableBecomeNil(t *testing.T) {
	dir := t.TempDir()
	a := writeJPEG(t, dir, "a.jpg", synthetic(64, 48, 1, true), 85)
	notJpeg := filepath.Join(dir, "not.jpg")
	if err := os.WriteFile(notJpeg, []byte("plain text"), 0o644); err != nil {
		t.Fatal(err)
	}
	res := Run(writeList(t, dir, filepath.Join(dir, "missing.jpg"), a, notJpeg))
	if !res.OK || len(res.Hashes) != 3 {
		t.Fatalf("unexpected result: %+v", res)
	}
	if res.Hashes[0] != nil || res.Hashes[1] == nil || res.Hashes[2] != nil {
		t.Fatalf("nil placement wrong: %+v", res.Hashes)
	}
}

func TestRunToleratesCRLFAndBlankLines(t *testing.T) {
	dir := t.TempDir()
	a := writeJPEG(t, dir, "a.jpg", synthetic(64, 48, 1, true), 85)
	res := Run(writeList(t, dir, a+"\r", ""))
	if !res.OK || len(res.Hashes) != 2 || res.Hashes[0] == nil || res.Hashes[1] != nil {
		t.Fatalf("unexpected result: %+v", res)
	}
}

func TestRunEmptyListIsOKAndMarshalsAsArray(t *testing.T) {
	dir := t.TempDir()
	res := Run(writeList(t, dir))
	if !res.OK || len(res.Hashes) != 0 {
		t.Fatalf("unexpected result: %+v", res)
	}
	// omitempty drops an empty slice: the Lua side must still see ok:true
	line, err := json.Marshal(res)
	if err != nil {
		t.Fatal(err)
	}
	var back struct {
		OK bool `json:"ok"`
	}
	if err := json.Unmarshal(line, &back); err != nil || !back.OK {
		t.Fatalf("marshalled line unusable: %s", line)
	}
}

func TestRunUnreadableListFails(t *testing.T) {
	res := Run(filepath.Join(t.TempDir(), "nope.txt"))
	if res.OK || res.Error == "" {
		t.Fatalf("expected failure, got %+v", res)
	}
	if Run("").OK {
		t.Fatal("empty list path must fail")
	}
}

// ---------------------------------------------------------------------------
// cross-platform goldens — real corpus frames, fingerprints pinned on every CI
// OS. Pins BOTH the stdlib JPEG decoder's determinism and the algorithm
// (deadband, grid, quantization). Regenerate ONLY on a deliberate algorithm
// change, with:  UPDATE_GOLDEN=1 go test ./imghash -run TestGolden

func TestGoldenCorpusFingerprints(t *testing.T) {
	goldenPath := filepath.Join("testdata", "golden.json")
	raw, err := os.ReadFile(goldenPath)
	if os.IsNotExist(err) {
		t.Skip("no goldens yet (testdata/golden.json absent)")
	}
	if err != nil {
		t.Fatal(err)
	}
	var golden map[string]string
	if err := json.Unmarshal(raw, &golden); err != nil {
		t.Fatal(err)
	}
	if len(golden) == 0 {
		t.Fatal("golden.json exists but is empty")
	}
	update := os.Getenv("UPDATE_GOLDEN") == "1"
	changed := false
	for name, want := range golden {
		got, err := HashFile(filepath.Join("testdata", name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if got != want {
			if update {
				golden[name] = got
				changed = true
				continue
			}
			t.Errorf("%s: fingerprint drifted: got %s want %s (decoder or algorithm change!)", name, got, want)
		}
	}
	if update && changed {
		out, _ := json.MarshalIndent(golden, "", "  ")
		if err := os.WriteFile(goldenPath, append(out, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
