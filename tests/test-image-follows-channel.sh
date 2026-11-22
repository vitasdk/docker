#!/usr/bin/env bash
#
# The layer that installs the SDK is keyed on what the series serves.
#
# Keyed on the series name alone it was built once and served from the build
# cache from then on: the plan decided a moved series needed a new image, and
# the build handed back the old SDK under new labels.
#
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$here/..
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

report() {
	printf 'FAIL %s\n' "$1"
	failures=$((failures + 1))
}

cat > "$work/index.json" <<'JSON'
{"channels": {"nightly": {"status": "development"}}, "schema_version": 1}
JSON
cat > "$work/nightly.json" <<'JSON'
{"channel": "nightly", "sequence": 42,
 "core": {"release": "sdk-snapshot-20260813.571.1"},
 "packages": {"release": "packages-snapshot-20260813.9.1"}}
JSON
printf '{}' > "$work/published.json"

python3 "$root/scripts/plan.py" --index "$work/index.json" --manifest-dir "$work" \
	--published "$work/published.json" --base-digest sha256:base --date 20260813 \
	> "$work/plan.json"

python3 - "$work/plan.json" "$work/nightly.json" <<'PY' || report "a build entry does not carry the hash of its manifest"
import hashlib, json, sys
plan = json.load(open(sys.argv[1]))
identity = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
entries = plan["build"]
assert entries
for entry in entries:
    assert entry["manifest_sha256"] == identity
    assert entry["labels"]["org.vitasdk.channel.manifest.sha256"] == identity
PY

# The argument has to be declared before the layer and used inside it, or the
# layer's cache key never sees it.
python3 - "$root/Dockerfile" <<'PY' || report "the Dockerfile does not key the SDK layer on the manifest"
import re, sys
text = open(sys.argv[1]).read()
core = text[text.index("FROM host-tools AS core"):]
run = core.index("./bootstrap-vitasdk.sh")
start = core.rindex("RUN ", 0, run)
assert "ARG CHANNEL_MANIFEST_SHA256" in core[:start]
assert "${CHANNEL_MANIFEST_SHA256}" in core[start:run]
PY

builds=$(grep -c 'VITASDK_CHANNEL=\${{ matrix.channel }}' "$root/.github/workflows/publish.yml")
keyed=$(grep -c 'CHANNEL_MANIFEST_SHA256=\${{ matrix.manifest_sha256 }}' "$root/.github/workflows/publish.yml")
[[ $builds -gt 0 && $builds == "$keyed" ]] ||
	report "publish.yml builds $builds time(s) with the channel but passes the manifest hash $keyed time(s)"

grep -q 'the image is labelled' "$root/tests/smoke.sh" ||
	report "the smoke test no longer compares the image with its labels"

if ((failures)); then
	exit 1
fi
echo "test-image-follows-channel: ok"
