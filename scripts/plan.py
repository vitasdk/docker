#!/usr/bin/env python3
"""Decide what to build and how to name it.

Everything this needs is already on disk: the workflow downloads the signed
channel index and the manifest of every live series, verifies them, and asks
the registry what it published last time. This turns that into a plan.

Kept out of the workflow because the interesting part is not the plumbing, it
is the naming and the decision not to publish -- and neither can be tested
inside a YAML file.

The decision is taken from the inputs, never from the built image: two builds
of the same content are not identical byte for byte (timestamps, apt state), so
comparing what came out would republish every single day.
"""

import argparse
import hashlib
import json
import pathlib
import sys

from worlds import WORLDS, resolve

# status values in the index that mean "still built"
LIVE = ("supported", "development")

VARIANTS = {
    # variant: tag suffix
    "full": "",
    "minimal": "-minimal",
}


def series_key(name):
    """Order series names newest first. Anything unparseable sorts last."""
    parts = name.split(".")
    try:
        return (0, tuple(-int(part) for part in parts))
    except ValueError:
        return (1, name)


def channel_world(name, manifests):
    return json.loads(manifests[name]).get("world", "vita")


def alias_channels(index, manifests):
    """The channel of each world, if any, that gets the bare `latest`/`non-root`
    aliases.

    Prefers that world's newest supported series. A non-default world with
    none yet -- softfp, pre-cutover -- falls back to its newest development
    channel: anyone pulling that repository's bare tag already knows the
    world it names is experimental. The default world never falls back:
    moving `latest` to a development series because no series is supported
    would hand the nightly to everyone who typed `docker run vitasdk/vitasdk`.
    """
    def channels_with(status, world):
        return [
            name for name, entry in index["channels"].items()
            if entry.get("status") == status and name in manifests
            and channel_world(name, manifests) == world
        ]

    result = {}
    for world in WORLDS:
        candidates = channels_with("supported", world)
        if not candidates and world != "vita":
            candidates = channels_with("development", world)
        result[world] = sorted(candidates, key=series_key)[0] if candidates else None
    return result


def dated(base, date, existing):
    """A dated tag that is never rewritten.

    Two publications on the same day are not hypothetical here: the channel
    dispatch and the cron can both fire, and a rewritten dated tag stops being
    the thing it promises to be.
    """
    candidate = f"{base}-{date}"
    suffix = 1
    while candidate in existing:
        suffix += 1
        candidate = f"{base}-{date}.{suffix}"
    return candidate


def tags_for(repository, base, variant, date, existing, alias):
    suffix = VARIANTS[variant]
    moving = f"{base}{suffix}"
    root = [moving, dated(moving, date, existing)]
    non_root = [f"{moving}-non-root", dated(f"{moving}-non-root", date, existing)]
    if alias:
        # The bare aliases follow the newest supported series. `non-root`
        # already exists and has to keep meaning something.
        root.append("latest" if variant == "full" else variant)
        non_root.append("non-root" if variant == "full" else f"{variant}-non-root")
    return (
        [f"{repository}:{tag}" for tag in root],
        [f"{repository}:{tag}" for tag in non_root],
    )


def plan(index, manifests, published, base_digest, date, existing,
         force, only, test_run=False):
    aliases = alias_channels(index, manifests)
    build, skip = [], []

    for channel, entry in sorted(index["channels"].items()):
        if entry.get("status") not in LIVE:
            continue
        if only and channel != only:
            continue
        if channel not in manifests:
            raise SystemExit(f"plan: no manifest downloaded for {channel}")

        raw = manifests[channel]
        manifest = json.loads(raw)
        world = manifest.get("world", "vita")
        repository, base = resolve(channel, world)
        alias_channel = aliases.get(world)

        # A run that publishes nothing exists to prove the build still works,
        # on the series most people are using for that world. Building every
        # live series on every push would cost eight package installs to
        # learn one thing.
        if test_run and channel != (alias_channel or channel):
            continue

        identity = hashlib.sha256(raw).hexdigest()

        was = published.get(channel, {})
        unchanged = (
            was.get("org.vitasdk.channel.manifest.sha256") == identity
            and was.get("org.opencontainers.image.base.digest") == base_digest
        )
        if unchanged and not force:
            # Neither the series nor the base moved. Rebuilding would only
            # produce a different set of bytes with the same content, and a
            # dated tag nobody asked for.
            skip.append({"channel": channel, "reason": "channel and base unchanged"})
            continue

        labels = {
            "org.opencontainers.image.base.digest": base_digest,
            "org.vitasdk.channel": channel,
            "org.vitasdk.channel.sequence": str(manifest.get("sequence", "")),
            "org.vitasdk.channel.manifest.sha256": identity,
            "org.vitasdk.core.release": manifest.get("core", {}).get("release", ""),
            "org.vitasdk.packages.release": manifest.get("packages", {}).get("release", ""),
        }

        repository_existing = existing.get(repository, set())
        for variant in VARIANTS:
            root_tags, non_root_tags = tags_for(
                repository, base, variant, date, repository_existing,
                alias=channel == alias_channel,
            )
            build.append({
                "channel": channel,
                "repository": repository,
                "variant": variant,
                "tags": root_tags,
                "non_root_tags": non_root_tags,
                "labels": labels,
                # buildx wants `key=value` lines, not a mapping.
                "label_text": "\n".join(f"{k}={v}" for k, v in sorted(labels.items())),
            })

    return {"build": build, "skip": skip, "alias": aliases}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", required=True, type=pathlib.Path)
    parser.add_argument("--manifest-dir", required=True, type=pathlib.Path)
    parser.add_argument("--published", required=True, type=pathlib.Path,
                        help="JSON mapping channel to the labels of its published image")
    parser.add_argument("--existing-tags", type=pathlib.Path,
                        help="file with one 'repository:tag' per line")
    parser.add_argument("--base-digest", required=True)
    parser.add_argument("--date", required=True, help="UTC, YYYYMMDD")
    parser.add_argument("--channel", default="", help="plan this series only")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--test-run", action="store_true",
                        help="build only the newest supported series, per world")
    arguments = parser.parse_args()

    index = json.loads(arguments.index.read_text())
    manifests = {
        path.stem: path.read_bytes()
        for path in arguments.manifest_dir.glob("*.json")
        if path.stem != "index"
    }
    # One 'repository:tag' per line, split on the last colon: a repository
    # name never contains one, so the rightmost is always the tag boundary.
    existing = {}
    if arguments.existing_tags and arguments.existing_tags.exists():
        for line in arguments.existing_tags.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            repository, _, tag = line.rpartition(":")
            existing.setdefault(repository, set()).add(tag)

    result = plan(
        index=index,
        manifests=manifests,
        published=json.loads(arguments.published.read_text()),
        base_digest=arguments.base_digest,
        date=arguments.date,
        existing=existing,
        force=arguments.force,
        only=arguments.channel,
        test_run=arguments.test_run,
    )
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
