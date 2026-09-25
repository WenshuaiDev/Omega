// Package buildinfo exposes the version embedded in a Go executable.
package buildinfo

import "runtime/debug"

// Version returns the module version, or "devel" for a workspace build.
func Version() string {
	info, ok := debug.ReadBuildInfo()
	if !ok || info.Main.Version == "" || info.Main.Version == "(devel)" {
		return "devel"
	}
	return info.Main.Version
}
