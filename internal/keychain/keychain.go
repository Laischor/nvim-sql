// Package keychain reads passwords from the macOS keychain via the
// `security` CLI. Store one with:
//
//	security add-generic-password -s <service> -a <account> -w
package keychain

import (
	"fmt"
	"os/exec"
	"strings"
)

func Get(service, account string) (string, error) {
	if _, err := exec.LookPath("security"); err != nil {
		return "", fmt.Errorf("keychain: `security` CLI not found (macOS only)")
	}
	out, err := exec.Command("security", "find-generic-password", "-s", service, "-a", account, "-w").Output()
	if err != nil {
		return "", fmt.Errorf("keychain: no password for service %q account %q (add with: security add-generic-password -s %s -a %s -w)", service, account, service, account)
	}
	return strings.TrimRight(string(out), "\n"), nil
}
