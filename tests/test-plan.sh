#!/usr/bin/env bash
#
# The naming and the decision not to publish, checked without a registry.
#
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
plan=$here/../scripts/plan.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

fixture() { # fixture <dir> — an index with one supported series and a nightly
	mkdir -p "$1"
	cat > "$1/index.json" <<-'EOF'
		{"channels": {
		  "2026.08": {"status": "supported"},
		  "2025.03": {"status": "end-of-life"},
		  "nightly": {"status": "development"}
		}, "schema_version": 1}
	EOF
	cat > "$1/2026.08.json" <<-'EOF'
		{"channel": "2026.08", "sequence": 1,
		 "core": {"release": "sdk-core-2026.08.0"},
		 "packages": {"release": "packages-2026.08-snapshot-20260813.3.1"}}
	EOF
	cat > "$1/nightly.json" <<-'EOF'
		{"channel": "nightly", "sequence": 42,
		 "core": {"release": "sdk-snapshot-20260813.571.1"},
		 "packages": {"release": "packages-snapshot-20260813.9.1"}}
	EOF
	printf '{}' > "$1/published.json"
}

run() { # run <dir> [extra args...] -> plan on stdout
	local dir=$1; shift
	python3 "$plan" \
		--index "$dir/index.json" \
		--manifest-dir "$dir" \
		--published "$dir/published.json" \
		--base-digest "sha256:base" \
		--date 20260813 \
		"$@"
}

check() { # check <description> <expected> <actual>
	if [[ $2 == "$3" ]]; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s\n       esperado: %s\n       obtenido: %s\n' "$1" "$2" "$3"
		failures=$((failures + 1))
	fi
}

query() { # query <plan json> <python expression over `p`>
	python3 -c 'import json,sys; p=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"
}

# An end-of-life series is not rebuilt, and both live ones are.
d=$work/live; fixture "$d"
out=$(run "$d")
check "sólo se construyen las series vivas" \
	"['2026.08', 'nightly']" \
	"$(query "sorted({b['channel'] for b in p['build']})" <<<"$out")"

# Two variants per series, and the non-root tags mirror the root ones.
check "dos variantes por serie" "4" "$(query "len(p['build'])" <<<"$out")"
check "la variante minimal se nombra" \
	"True" \
	"$(query "'vitasdk/vitasdk:2026.08-minimal' in p['build'][0]['tags'] or 'vitasdk/vitasdk:2026.08-minimal' in p['build'][1]['tags']" <<<"$out")"

# `latest` follows the newest supported series, never the development one.
check "latest apunta a la serie supported" \
	"['2026.08']" \
	"$(query "sorted({b['channel'] for b in p['build'] if 'vitasdk/vitasdk:latest' in b['tags']})" <<<"$out")"
check "non-root a secas acompaña a latest" \
	"['2026.08']" \
	"$(query "sorted({b['channel'] for b in p['build'] if 'vitasdk/vitasdk:non-root' in b['non_root_tags']})" <<<"$out")"
check "nightly no se lleva ningún alias" \
	"[]" \
	"$(query "[t for b in p['build'] if b['channel']=='nightly' for t in b['tags'] if ':' in t and t.split(':')[1] in ('latest','minimal')]" <<<"$out")"

# Nothing moved: no build, and therefore no dated tag for a day in which
# nothing happened.
d=$work/unchanged; fixture "$d"
identity=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$d/2026.08.json")
cat > "$d/published.json" <<-EOF
	{"2026.08": {"org.vitasdk.channel.manifest.sha256": "$identity",
	             "org.opencontainers.image.base.digest": "sha256:base"}}
EOF
out=$(run "$d")
check "una serie sin cambios no se republica" \
	"['nightly']" \
	"$(query "sorted({b['channel'] for b in p['build']})" <<<"$out")"

# ... unless the base moved underneath it, which is the whole point of the cron.
out=$(python3 "$plan" --index "$d/index.json" --manifest-dir "$d" \
	--published "$d/published.json" --base-digest "sha256:otra" --date 20260813)
check "un cambio de base sí la reconstruye" \
	"['2026.08', 'nightly']" \
	"$(query "sorted({b['channel'] for b in p['build']})" <<<"$out")"

# ... or unless it is asked for explicitly.
out=$(run "$d" --force)
check "--force reconstruye igualmente" \
	"['2026.08', 'nightly']" \
	"$(query "sorted({b['channel'] for b in p['build']})" <<<"$out")"

# A second publication on the same day must not overwrite the first.
d=$work/collision; fixture "$d"
printf 'vitasdk/vitasdk:2026.08-20260813\n' > "$d/existing"
out=$(run "$d" --existing-tags "$d/existing")
check "el tag fechado no se reescribe" \
	"True" \
	"$(query "'vitasdk/vitasdk:2026.08-20260813.2' in [t for b in p['build'] if b['channel']=='2026.08' and b['variant']=='full' for t in b['tags']]" <<<"$out")"

# With no supported series there is nothing for `latest` to mean, and moving it
# to the development channel would be worse than leaving it where it is.
d=$work/nosupported; fixture "$d"
python3 - "$d/index.json" <<-'EOF'
	import json, sys
	path = sys.argv[1]
	index = json.load(open(path))
	index["channels"]["2026.08"]["status"] = "end-of-life"
	json.dump(index, open(path, "w"))
EOF
out=$(run "$d")
check "sin serie supported nadie hereda latest" \
	"[]" \
	"$(query "[t for b in p['build'] for t in b['tags'] if t.endswith(':latest')]" <<<"$out")"

# The labels are the identity of the image: the dated tag only says when.
d=$work/labels; fixture "$d"
out=$(run "$d")
check "las etiquetas llevan la release exacta del core" \
	"sdk-core-2026.08.0" \
	"$(query "[b['labels']['org.vitasdk.core.release'] for b in p['build'] if b['channel']=='2026.08'][0]" <<<"$out")"

if (( failures )); then
	printf '\n%d comprobaciones fallidas\n' "$failures" >&2
	exit 1
fi
printf '\ntodo en verde\n'
