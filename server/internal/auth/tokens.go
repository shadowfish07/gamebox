package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
)

const maximumRandomTokenBytes = 1024

var (
	ErrInvalidTokenLength = errors.New("invalid token length")
	ErrInvalidTokenInput  = errors.New("invalid token input")
	ErrTokenGeneration    = errors.New("token generation failed")
)

// RandomToken returns an unpadded URL-safe representation of byteCount bytes
// read from crypto/rand. The argument is entropy bytes, not encoded characters;
// RandomToken(32), for example, returns 43 text characters.
func RandomToken(byteCount int) (string, error) {
	return randomToken(byteCount, rand.Reader)
}

func randomToken(byteCount int, entropy io.Reader) (string, error) {
	if byteCount <= 0 || byteCount > maximumRandomTokenBytes {
		return "", ErrInvalidTokenLength
	}
	randomBytes := make([]byte, byteCount)
	if _, err := io.ReadFull(entropy, randomBytes); err != nil {
		return "", ErrTokenGeneration
	}
	return base64.RawURLEncoding.EncodeToString(randomBytes), nil
}

// HashToken returns a lower-case hexadecimal SHA-256 digest. Length prefixes
// frame the pepper and plaintext as distinct fields so different input pairs
// cannot become the same byte stream before hashing.
func HashToken(pepper, plaintext string) (string, error) {
	if pepper == "" || plaintext == "" {
		return "", ErrInvalidTokenInput
	}
	hasher := sha256.New()
	_, _ = hasher.Write([]byte("gamebox/token-hash/v1"))
	writeHashField(hasher, []byte(pepper))
	writeHashField(hasher, []byte(plaintext))
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

type hashWriter interface {
	Write([]byte) (int, error)
}

func writeHashField(destination hashWriter, field []byte) {
	var length [8]byte
	binary.BigEndian.PutUint64(length[:], uint64(len(field)))
	_, _ = destination.Write(length[:])
	_, _ = destination.Write(field)
}
