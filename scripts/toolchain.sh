#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

check() {
	tool=$1
	expected=$2
	actual=$3
	if [ "$actual" != "$expected" ]; then
		printf '%s version mismatch: expected %s, got %s.\n' "$tool" "$expected" "$actual" >&2
		printf 'Install/select %s %s in PATH; see README.md, prerequisites. No global tools were changed.\n' "$tool" "$expected" >&2
		exit 1
	fi
}

for tool in go node corepack; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		printf 'Missing %s. Install the pinned version first; see README.md, prerequisites.\n' "$tool" >&2
		exit 1
	fi
done

export GOTOOLCHAIN=local
check Go "go$(cat .go-version)" "$(go env GOVERSION)"
check Node "v$(cat .node-version)" "$(node --version)"
check Corepack "$(cat .corepack-version)" "$(corepack --version)"
expected_yarn=$(node -p 'require("./package.json").packageManager.split("@").pop()')
check Yarn "$expected_yarn" "$(corepack yarn --version)"
