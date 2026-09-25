#!/bin/sh
# Run against committed sources in a disposable clone, never mutate the caller.
set -eu
source_repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
evidence=$(mktemp -d "${TMPDIR:-/tmp}/omega-acceptance.XXXXXX")
git clone --quiet --no-local "$source_repo" "$evidence/repo"
cd "$evidence/repo"
printf 'Acceptance clone and logs: %s\n' "$evidence"

run() {
	name=$1
	shift
	status=0
	"$@" >"$evidence/$name.log" 2>&1 || status=$?
	printf '%s: exit %s\n' "$name" "$status"
	if [ "$status" -ne 0 ]; then cat "$evidence/$name.log"; exit 1; fi
}

reject() {
	name=$1
	pattern=$2
	shift 2
	status=0
	"$@" >"$evidence/$name.log" 2>&1 || status=$?
	printf '%s: exit %s (expected nonzero)\n' "$name" "$status"
	if [ "$status" -eq 0 ] || ! grep -q "$pattern" "$evidence/$name.log"; then
		cat "$evidence/$name.log"
		exit 1
	fi
}

replace() {
	node --input-type=module - "$@" <<'JS'
import fs from "node:fs";
const [file, before, after] = process.argv.slice(2);
const source = fs.readFileSync(file, "utf8");
if (!source.includes(before)) throw new Error(`Missing fixture text in ${file}`);
fs.writeFileSync(file, source.replace(before, after));
JS
}

web=web/apps/example-web/src/main.tsx
service=services/example-service/cmd/example-service/main.go
{
	uname -sm
	git rev-parse HEAD
	go version
	node --version
	corepack --version
} >"$evidence/platform.log"
cat "$evidence/platform.log"
run bootstrap-first make bootstrap
run bootstrap-repeat make bootstrap
run immutable-sources git diff --exit-code
run check-baseline make check
run check-readonly git diff --exit-code
run build make build
run service ./build/example-service
grep -qx 'Omega example-service version=devel' "$evidence/service.log"
run compiler corepack yarn workspace @omega/example-web exec tsc --version
grep -qx 'Version 7.0.2' "$evidence/compiler.log"
run lint-api corepack yarn workspace @omega/example-web exec node -p 'require("typescript").version'

replace package.json '"prettier": "3.9.9"' '"prettier": "3.9.8"'
cp yarn.lock "$evidence/yarn.lock"
reject immutable-install 'YN0028' make bootstrap
cmp yarn.lock "$evidence/yarn.lock"
git restore -- package.json

# A formatting-valid type error must reach TS7 through the root command.
replace "$web" 'const projectName: string = "Omega";' 'const projectName: string = 123;'
cp "$web" "$evidence/type-error.tsx"
reject type-error 'TS2322' make check
cmp "$web" "$evidence/type-error.tsx"
git restore -- "$web"

replace "$web" 'const projectName: string = "Omega";' 'const projectName:string="Omega";'
cp "$web" "$evidence/format-error.tsx"
reject format-error 'Code style issues' make check
cmp "$web" "$evidence/format-error.tsx"
run format-repair make fmt
run format-restored git diff --exit-code

replace "$service" 'func main() {' 'func main(){'
cp "$service" "$evidence/format-error.go"
reject go-format-error 'Go format errors' make check
cmp "$service" "$evidence/format-error.go"
run go-format-repair make fmt
run go-format-restored git diff --exit-code

replace "$web" 'const projectName: string = "Omega";' 'const projectName: any = "Omega";'
reject lint-error 'no-explicit-any' make check
git restore -- "$web"

replace "$service" 'version=%s' 'version=%d'
reject vet-error 'wrong type string' make check
git restore -- "$service"

# A deliberately failing Go test verifies propagation, without keeping an
# implementation-level test seam in the actual modules.
test_file=libs/buildinfo/injected_test.go
cat >"$test_file" <<'GO'
package buildinfo

import "testing"

func TestAcceptanceFailure(t *testing.T) {
	t.Fatal("acceptance injected failure")
}
GO
reject go-test-error 'acceptance injected failure' make check
rm "$test_file"

replace "$service" 'buildinfo.Version()' 'buildinfo.DoesNotExist()'
reject go-build-error 'undefined: buildinfo.DoesNotExist' make build
git restore -- "$service"

printf '\nimport "./missing-acceptance-file";\n' >>"$web"
reject web-build-error 'missing-acceptance-file' make build
git restore -- "$web"

# Exercise actual prerequisite diagnostics with only external command wrappers.
mkdir "$evidence/bin"
make_bin=$(command -v make)
for tool in sh dirname cat go node corepack; do
	ln -s "$(command -v "$tool")" "$evidence/bin/$tool"
done
for tool in go node corepack; do
	rm "$evidence/bin/$tool"
	reject "missing-$tool" "Missing $tool" env PATH="$evidence/bin" "$make_bin" bootstrap
	ln -s "$(command -v "$tool")" "$evidence/bin/$tool"
done
for tool in go node corepack; do
	rm "$evidence/bin/$tool"
	printf '#!/bin/sh\nprintf "0.0.0\\n"\n' >"$evidence/bin/$tool"
	chmod +x "$evidence/bin/$tool"
	reject "wrong-$tool" 'version mismatch' env PATH="$evidence/bin:$PATH" "$make_bin" bootstrap
	rm "$evidence/bin/$tool"
	ln -s "$(command -v "$tool")" "$evidence/bin/$tool"
done

# Secret samples stay addable; real local config and products do not.
touch services/example-service/.env.local web/apps/example-web/.env.local
run ignored git check-ignore services/example-service/.env.local web/apps/example-web/.env.local node_modules web/apps/example-web/dist build
if git check-ignore -q services/example-service/.env.example; then
	printf '.env.example must remain addable\n' >&2
	exit 1
fi
run check-restored make check
run build-restored make build
run source-restored git diff --exit-code
if [ -n "$(git ls-files --others --exclude-standard)" ]; then
	git ls-files --others --exclude-standard
	exit 1
fi
printf 'PASS: command acceptance; browser rendering must be checked separately.\n'
