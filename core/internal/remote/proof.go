package remote

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
)

// Pairing with a core that serves its own certificate, which no authority
// vouches for, binds the pairing code to that certificate instead. The device
// never sends the code over a connection it cannot verify: it sends
// DeviceProof over the certificate it was shown, which the server checks
// against its own, so a certificate put in between fails and learns nothing
// it could pair with. The server answers with ServerProof, which only a
// holder of the code makes, before the device pins the certificate. The code
// is 130 random bits, which leaves nothing to guess offline.
const (
	deviceRole = "lumeo pair device"
	serverRole = "lumeo pair server"
)

// DeviceProof is what a device sends in place of the code.
func DeviceProof(code string, certificate []byte) string { return proof(code, deviceRole, certificate) }

// ServerProof is what the server answers with when the device's proof holds.
func ServerProof(code string, certificate []byte) string { return proof(code, serverRole, certificate) }

// ProofHolds compares two proofs in constant time.
func ProofHolds(want, got string) bool { return hmac.Equal([]byte(want), []byte(got)) }

func proof(code, role string, certificate []byte) string {
	sum := sha256.Sum256(certificate)
	mac := hmac.New(sha256.New, []byte(code))
	mac.Write([]byte(role))
	mac.Write([]byte{0})
	mac.Write(sum[:])
	return hex.EncodeToString(mac.Sum(nil))
}
