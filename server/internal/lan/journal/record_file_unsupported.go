//go:build !android && !darwin && !linux

package journal

import "errors"

func readCommittedRecord(string, string, int) ([]byte, error) {
	return nil, errors.New("atomic committed journal reads are unsupported on this platform")
}
