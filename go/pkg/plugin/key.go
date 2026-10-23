// SPDX-License-Identifier: Apache-2.0

package plugin

import (
	"os"

	"google.golang.org/protobuf/encoding/protodelim"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// KeyOnStdinEnv is the variable the daemon sets to 1 in a plugin's
// environment when it writes a SetCredentialRequest before the
// StreamDescriptor. The daemon goes by the installed manifest, which may name a
// credential_provider the one built into the binary does not, so the variable
// is what a plugin trusts (docs/reference/writing-a-decoder.md, "The key").
const KeyOnStdinEnv = "LEYLINE_KEY_ON_STDIN"

// expectsKey reports whether a key comes before the descriptor: the daemon
// says so in the environment, or provider, the built-in manifest's
// credential_provider, is set.
func expectsKey(provider string) bool {
	return provider != "" || os.Getenv(KeyOnStdinEnv) == "1"
}

// readKeyIfSent reads the key when expectsKey says one comes, and returns nil
// without reading when none does.
func readKeyIfSent(in protodelim.Reader, provider string) (*leylinev1.SetCredentialRequest, error) {
	if !expectsKey(provider) {
		return nil, nil
	}
	return ReadCredential(in)
}
