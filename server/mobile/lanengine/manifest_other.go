//go:build !darwin && !linux && !android

package lanengine

// Unsupported platforms safely ignore the non-authoritative manifest hint
// instead of using a weaker symlink-following reader.
func readManifestFile(string) ([]byte, error) {
	return nil, ErrInvalidConfiguration
}
