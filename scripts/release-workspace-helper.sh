#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: scripts/release-workspace-helper.sh VERSION [OUTPUT_DIR]}"
output="${2:-build/workspace-helper}"
if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  echo "version must look like v1.2.3" >&2
  exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  echo "release source must be clean and fully committed" >&2
  exit 1
fi
if [[ "$output" != /* ]]; then
  output="$root/$output"
fi
mkdir -p "$output"
commit="$(git rev-parse HEAD)"
toolchain="$(awk '$1 == "toolchain" {print $2}' go.mod)"
[[ "$toolchain" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "release requires an exact Go toolchain pin in go.mod" >&2
  exit 1
}
unset GONOSUMDB GOPRIVATE GOINSECURE GOFLAGS
export GOSUMDB=sum.golang.org
export GOENV=off GOTOOLCHAIN="$toolchain" GOWORK=off
go_version="$(go env GOVERSION)"
[[ "$go_version" == "$toolchain" ]] || {
  echo "release Go toolchain mismatch: expected $toolchain, got $go_version" >&2
  exit 1
}
release_tag="cfctx-run-$version"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/source"
git archive HEAD | tar -x -C "$work/source"
cd "$work/source"
unset GOFLAGS GOAMD64 GOARM64 GOEXPERIMENT GO386 GOARM GOMIPS GOMIPS64
export GOENV=off GOTOOLCHAIN="$toolchain" GOWORK=off
for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
  os="${target%/*}"
  arch="${target#*/}"
  file="cfctx-run-${os}-${arch}"
  if [[ "$arch" == amd64 ]]; then
    GOAMD64=v1 GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags "-buildid= -X main.version=$version" -o "$output/$file" ./cmd/cfctx-run
  else
    GOARM64=v8.0 GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags "-buildid= -X main.version=$version" -o "$output/$file" ./cmd/cfctx-run
  fi
  go version -m "$output/$file" > "$work/$file.buildinfo"
done
python3 - "$output" "$work" "$version" "$commit" "$go_version" "$release_tag" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
work = pathlib.Path(sys.argv[2])
version, commit, go_version, release_tag = sys.argv[3:]
files = []
for os_name, arch in (("linux", "amd64"), ("linux", "arm64"), ("darwin", "amd64"), ("darwin", "arm64")):
    name = f"cfctx-run-{os_name}-{arch}"
    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
    build_info = "\n".join((work / f"{name}.buildinfo").read_text().splitlines()[1:]) + "\n"
    files.append({"os": os_name, "arch": arch, "file": name, "sha256": digest, "goVersionInfo": build_info})
(root / "checksums.json").write_text(json.dumps(files, indent=2) + "\n")
(root / "release.json").write_text(json.dumps({
    "name": "cfctx-run", "version": version, "releaseTag": release_tag, "sourceCommit": commit,
    "goVersion": go_version, "files": files,
}, indent=2) + "\n")
PY
echo "Built $version for Linux and macOS amd64/arm64 in $output"
