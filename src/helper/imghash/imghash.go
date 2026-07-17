// Package imghash is the helper's hash mode (LENS_HASH=1): perceptual dHash
// fingerprints for the plugin's burst detection. It reads a list file of
// JPEG paths (LENS_HASH_LIST) and prints one hash per line-entry.
//
// This mode NEVER touches Chrome: no cdp, no chrome, no network — it must
// stay importable-by-main only alongside those, never importing them. The
// clustering policy (thresholds, time gates) lives in the Lua plugin
// (src/plugin/shared/Burst.lua); this package only turns pixels into bits.
//
// Determinism is load-bearing: the inputs are always the plugin's own
// freshly-rendered JPEGs, decoded with Go's stdlib decoder and reduced with
// pure integer math, so a given file hashes identically on every OS/arch.
// The golden tests pin that (see imghash_test.go).
package imghash

import (
	"fmt"
	"image"
	"image/jpeg"
	"os"
	"strings"
)

// Result is hash mode's single stdout JSON line.
// Hashes[k] corresponds to line k of the list file; nil marks a file that
// could not be read or decoded (the plugin treats that frame as a singleton).
type Result struct {
	OK     bool      `json:"ok"`
	Hashes []*string `json:"hashes,omitempty"`
	Error  string    `json:"error,omitempty"`
}

// dHash geometry: 9×8 grayscale cells → 8 horizontal gradients per row → 64 bits.
const (
	hashCols = 9
	hashRows = 8
)

// cellGrid area-averages the image to the 9×8 grayscale grid both planes of
// the fingerprint are computed from.
func cellGrid(img image.Image) [hashRows][hashCols]uint64 {
	var cells [hashRows][hashCols]uint64
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	for ty := 0; ty < hashRows; ty++ {
		y0, y1 := b.Min.Y+ty*h/hashRows, b.Min.Y+(ty+1)*h/hashRows
		if y1 <= y0 {
			y1 = y0 + 1 // degenerate (image smaller than the grid): 1-px band
		}
		for tx := 0; tx < hashCols; tx++ {
			x0, x1 := b.Min.X+tx*w/hashCols, b.Min.X+(tx+1)*w/hashCols
			if x1 <= x0 {
				x1 = x0 + 1
			}
			var sum, n uint64
			for y := y0; y < y1; y++ {
				for x := x0; x < x1; x++ {
					r, g, bl, _ := img.At(x, y).RGBA()
					// integer Rec.601 luma on the 16-bit channels
					sum += (299*uint64(r) + 587*uint64(g) + 114*uint64(bl)) / 1000
					n++
				}
			}
			cells[ty][tx] = sum / n
		}
	}
	return cells
}

// DHash computes the 64-bit difference hash of an image: one bit per
// horizontally adjacent cell pair (row-major, MSB first), set when the right
// cell is brighter than the left by MORE than the gradient deadband. The
// deadband keeps low-texture cells (open water, sky) from flipping bits on
// sensor noise — without it, real burst frames of rippling water measured
// 15–25 bits apart on the corpus (see build/burst-accuracy.lua --sweep).
func DHash(img image.Image) uint64 {
	cells := cellGrid(img)
	const eps = uint64(gradientDeadband)
	var hash uint64
	for ty := 0; ty < hashRows; ty++ {
		for tx := 0; tx < hashCols-1; tx++ {
			hash <<= 1
			if cells[ty][tx+1] > cells[ty][tx]+eps {
				hash |= 1
			}
		}
	}
	return hash
}

// gradientDeadband is the 16-bit-luma delta below which two adjacent cells
// count as equal in DHash. Tuned on the burst corpus (`just burst-accuracy
// --sweep`); not user-configurable.
const gradientDeadband = 2048

// Levels returns the 72 cell means quantized to bytes, row-major — the
// fingerprint's second plane. Gradient signs alone cannot tell two DIFFERENT
// low-texture scenes apart (blue sky and pale sand both hash to ~no
// gradients); absolute levels can, and burst frames of the SAME scene keep
// nearly identical levels even while panning.
func Levels(img image.Image) []byte {
	cells := cellGrid(img)
	out := make([]byte, 0, hashRows*hashCols)
	for ty := 0; ty < hashRows; ty++ {
		for tx := 0; tx < hashCols; tx++ {
			out = append(out, byte(cells[ty][tx]>>8))
		}
	}
	return out
}

// Fingerprint is what hash mode emits per image: "<16-hex dHash>:<144-hex
// levels>". Burst.lua gates a merge on BOTH planes agreeing.
func Fingerprint(img image.Image) string {
	return fmt.Sprintf("%016x:%x", DHash(img), Levels(img))
}

// HashFile decodes one JPEG and returns its fingerprint (see Fingerprint).
// Only JPEG is supported by design — the inputs are the plugin's own renders.
func HashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	img, err := jpeg.Decode(f)
	if err != nil {
		return "", err
	}
	return Fingerprint(img), nil
}

// Run executes hash mode over a list file (one image path per line; CRLF
// tolerated; a blank line yields a nil entry). Per-file failures degrade to
// nil entries — the run itself only fails when the list can't be read.
func Run(listPath string) Result {
	if listPath == "" {
		return Result{OK: false, Error: "LENS_HASH_LIST not set"}
	}
	raw, err := os.ReadFile(listPath)
	if err != nil {
		return Result{OK: false, Error: "could not read hash list: " + err.Error()}
	}
	lines := strings.Split(string(raw), "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1] // final newline, not an entry
	}
	hashes := make([]*string, 0, len(lines))
	for _, line := range lines {
		p := strings.TrimRight(line, "\r")
		if p == "" {
			hashes = append(hashes, nil)
			continue
		}
		hx, err := HashFile(p)
		if err != nil {
			hashes = append(hashes, nil) // unreadable/undecodable → singleton upstream
			continue
		}
		hashes = append(hashes, &hx)
	}
	return Result{OK: true, Hashes: hashes}
}
