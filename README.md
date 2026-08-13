# VitaSDK official Docker images

[![2026.08 published](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fhub.docker.com%2Fv2%2Frepositories%2Fvitasdk%2Fvitasdk%2Ftags%2F2026.08%2F&query=%24.last_updated&label=2026.08%20published)](https://hub.docker.com/r/vitasdk/vitasdk/tags?name=2026.08)
[![nightly published](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fhub.docker.com%2Fv2%2Frepositories%2Fvitasdk%2Fvitasdk%2Ftags%2Fnightly%2F&query=%24.last_updated&label=nightly%20published)](https://hub.docker.com/r/vitasdk/vitasdk/tags?name=nightly)

Those badges are dates rather than a build status on purpose. A workflow that
stops being triggered keeps its last green tick forever -- which is exactly
what happened here for three weeks, and to `vitasdk/buildscripts` for two
months, without anything ever turning red. A stale date cannot lie.

```console
$ docker run --rm -it -v "$PWD:/workspace" vitasdk/vitasdk:2026.08
```

The image is a consumer of the published SDK, not a second way of installing
it: it bootstraps from the signed channel manifest at `vitasdk.org/channels`,
exactly as a person does on their own machine, and `vdpm` inside it is already
refreshed on that series.

## Tags

A tag is a release series plus, optionally, the day it was published.

| tag | what it is |
| --- | --- |
| `2026.08` | the series, moving: rebuilt when its packages move or the base gets security updates |
| `2026.08-20260813` | the same series frozen on that date, never rewritten |
| `latest` | the newest supported series |
| `nightly`, `nightly-20260813` | the development channel, rebuilt as it moves |

and two axes on top of any of them:

| suffix | what changes |
| --- | --- |
| `-minimal` | the core and the tools to build with it, without the ~130 target packages (764 MB against 1.6 GB) |
| `-non-root` | the same filesystem, running as `vitasdk` instead of as root |

So `2026.08-minimal-non-root-20260813` is a thing, and so is `minimal`, which
follows the newest supported series like `latest` does.

Every tag is a multi-architecture manifest covering `linux/amd64` and
`linux/arm64`, both built natively.

**The dated tags of a series are kept indefinitely. The dated tags of
`nightly` are not**: they are produced daily by definition and may be pruned
later. Pin a series if you need the pin to survive.

## Variants

The plain tag runs as root, which is what a derived `RUN apt-get install ...`
and the container jobs of most CI systems expect. It is not a root-only image:
the `vitasdk` user (UID 1000) exists in every variant, the SDK belongs to it
with group 0 and `g+rwX`, so all of these work without a rebuild:

```console
$ docker run --rm --user vitasdk vitasdk/vitasdk:2026.08     # by name
$ docker run --rm --user 4242:0  vitasdk/vitasdk:2026.08     # any UID, as a cluster assigns
$ docker run --rm vitasdk/vitasdk:2026.08-non-root           # or the tag, for runAsNonRoot
```

The `-non-root` tag exists for the one case `--user` cannot cover: Kubernetes
with `runAsNonRoot: true` reads the `USER` configured in the image and refuses
to start a container whose image declares root, whatever the pod says.

A non-root user is also what `vita-makepkg` needs -- it ships inside the SDK
and refuses to run with EUID 0, like the `makepkg` it descends from.

The full variant carries every package of the series and `build-essential`,
for projects that compile a helper tool of their own during the build. What
each variant contains is recorded in its labels:

```console
$ docker inspect vitasdk/vitasdk:2026.08 --format '{{ json .Config.Labels }}'
```

The dated tag says *when* an image was published. The labels say *what* it
contains: the channel, its sequence, the SHA-256 of the manifest it was built
from, and the exact core and packages releases.

## How it is built

`.github/workflows/publish.yml` builds one image per live series read from the
signed `channels/index.json` -- the same file the client reads. A series that
goes end-of-life stops being rebuilt without anything here changing.

It runs on two triggers. A `repository_dispatch` from `vitasdk/autobuilds`
when a channel is published, which is the one that keeps the images following
the packages; and a daily cron for base image security updates. Nothing is
pushed unless the channel manifest or the base image digest actually changed,
so a quiet day produces no tags.

Before anything is published, every built image compiles and links a real
`.vpk` inside itself, as root and as an arbitrary UID.

```console
$ docker build --target full --build-arg VITASDK_CHANNEL=2026.08 -t vitasdk:probe .
$ tests/smoke.sh vitasdk:probe
$ tests/test-plan.sh
```
