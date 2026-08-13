#!/usr/bin/env bash
#
# Compile and link a real .vpk inside a built image.
#
#   tests/smoke.sh IMAGE [RUN_AS_USER]
#
# Building an image proves nothing about it. The pipeline this one replaces
# published images whose toolchain could not even start -- a glibc SDK unpacked
# into a musl base -- and nobody noticed for months, because no step had ever
# run a compiler inside the result.
#
# The second argument runs the test as another user, which is how the arbitrary
# UID that Kubernetes hands out gets covered:
#
#   tests/smoke.sh vitasdk/vitasdk:2026.08 1234:0
#
set -euo pipefail

image=${1:?usage: smoke.sh IMAGE [RUN_AS_USER]}
run_as=${2:-}

run_options=(--rm --interactive)
if [[ -n $run_as ]]; then
	run_options+=(--user "$run_as")
fi

variant=$(docker image inspect \
	--format '{{ index .Config.Labels "org.vitasdk.variant" }}' "$image")
case $variant in
full|minimal) ;;
*)
	printf 'smoke: image %s declares no known variant: %s\n' "$image" "$variant" >&2
	exit 1
	;;
esac

printf 'smoke: %s (variant %s%s)\n' "$image" "$variant" \
	"${run_as:+, as $run_as}"

# The package half only applies where there are packages. In the minimal image
# the absence of zlib is the correct outcome, not a failure.
if [[ $variant == full ]]; then
	link_package=1
else
	link_package=0
fi

docker run "${run_options[@]}" --env LINK_PACKAGE="$link_package" "$image" \
	bash -s <<'INSIDE'
set -eu

# 1. The toolchain runs at all. This single line is what the previous images
#    failed, before anything else got a chance to.
arm-vita-eabi-gcc --version > /dev/null

# 2. vdpm is on a channel and can talk about it.
vdpm status

work=$(mktemp -d)
cd "$work"
mkdir src

cat > src/main.c <<'EOF'
#include <stdio.h>
#if LINK_PACKAGE
#include <zlib.h>
#endif

int main(void)
{
#if LINK_PACKAGE
	printf("smoke %s\n", zlibVersion());
#else
	printf("smoke\n");
#endif
	return 0;
}
EOF

cat > CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake"
      CACHE PATH "toolchain file")
endif()

project(smoke C)
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "Smoke")
set(VITA_TITLEID  "VSDK00099")

add_executable(smoke src/main.c)
target_compile_definitions(smoke PRIVATE LINK_PACKAGE=$ENV{LINK_PACKAGE})
if(NOT "$ENV{LINK_PACKAGE}" STREQUAL "0")
  target_link_libraries(smoke z)
endif()

vita_create_self(smoke.self smoke)
vita_create_vpk(smoke.vpk ${VITA_TITLEID} smoke.self NAME ${VITA_APP_NAME})
EOF

# 3. Configure, compile, link, and package. Ninja because the image ships it
#    and a missing generator should fail here rather than in someone's project.
cmake -S . -B build -G Ninja
cmake --build build --target smoke.vpk

test -s build/smoke.vpk

# 4. Writing to the SDK is what `vdpm install` needs at runtime, and it is the
#    first thing to break when the image is built as one user and run as
#    another. Checked without installing anything, so the test stays offline.
probe=$VITASDK/.smoke-writable
touch "$probe" && rm -f "$probe"

echo "smoke: ok"
INSIDE
