package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"math/big"
)

const (
	maximumRandomTokenBytes = 1024
	inviteCodeLength        = 12
	inviteCodeAlphabet      = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
)

const refreshTokenHashDomain = "gamebox/refresh-token-hash/v1"

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

// RandomInviteCode returns a twelve-character code made from upper-case ASCII
// letters and digits. Its roughly 62 bits of entropy keep online guessing
// impractical while remaining short enough to enter by hand.
func RandomInviteCode() (string, error) {
	return randomInviteCode(rand.Reader)
}

func randomInviteCode(entropy io.Reader) (string, error) {
	if entropy == nil {
		return "", ErrTokenGeneration
	}
	alphabetSize := big.NewInt(int64(len(inviteCodeAlphabet)))
	code := make([]byte, inviteCodeLength)
	for index := range code {
		alphabetIndex, err := rand.Int(entropy, alphabetSize)
		if err != nil {
			return "", ErrTokenGeneration
		}
		code[index] = inviteCodeAlphabet[alphabetIndex.Int64()]
	}
	return string(code), nil
}

// normalizeInviteCode makes only the current human-entered format
// case-insensitive. Legacy invitation credentials remain byte-for-byte
// compatible because their different lengths bypass normalization.
func normalizeInviteCode(code string) string {
	if len(code) != inviteCodeLength {
		return code
	}
	normalized := []byte(code)
	for index, character := range normalized {
		switch {
		case character >= 'A' && character <= 'Z':
		case character >= 'a' && character <= 'z':
			normalized[index] = character - ('a' - 'A')
		case character >= '0' && character <= '9':
		default:
			return code
		}
	}
	return string(normalized)
}

// HashToken returns a lower-case hexadecimal SHA-256 digest. Length prefixes
// frame the pepper and plaintext as distinct fields so different input pairs
// cannot become the same byte stream before hashing.
func HashToken(pepper, plaintext string) (string, error) {
	return hashTokenWithDomain("gamebox/token-hash/v1", pepper, plaintext)
}

// HashRefreshToken keeps refresh credentials in a distinct hashing domain
// from invitations and future one-time credentials.
func HashRefreshToken(pepper, plaintext string) (string, error) {
	return hashTokenWithDomain(refreshTokenHashDomain, pepper, plaintext)
}

func hashTokenWithDomain(domain, pepper, plaintext string) (string, error) {
	if pepper == "" || plaintext == "" {
		return "", ErrInvalidTokenInput
	}
	hasher := sha256.New()
	_, _ = hasher.Write([]byte(domain))
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
