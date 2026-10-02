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
mkdir -p "$output"
commit="$(git rev-parse HEAD)"
go_version="$(go version | awk '{print $3}')"
for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
  os="${target%/*}"
  arch="${target#*/}"
  file="cfctx-run-${os}-${arch}"
  GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags "-buildid= -X main.version=$version" -o "$output/$file" ./cmd/cfctx-run
done
python3 - "$output" "$version" "$commit" "$go_version" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
version, commit, go_version = sys.argv[2:]
files = []
for os_name, arch in (("linux", "amd64"), ("linux", "arm64"), ("darwin", "amd64"), ("darwin", "arm64")):
    name = f"cfctx-run-{os_name}-{arch}"
    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
    files.append({"os": os_name, "arch": arch, "file": name, "sha256": digest})
(root / "checksums.json").write_text(json.dumps(files, indent=2) + "\n")
(root / "release.json").write_text(json.dumps({
    "name": "cfctx-run", "version": version, "sourceCommit": commit,
    "goVersion": go_version, "files": files,
}, indent=2) + "\n")
PY
echo "Built $version for Linux and macOS amd64/arm64 in $output"
