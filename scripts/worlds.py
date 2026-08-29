"""Which Docker Hub repository and tag name a channel's world publishes as.

Enumerated by hand, never derived from a naming convention -- the same choice
vitasdk-autobuild's generate-channel-manifest.py makes for schema_version.
Extend this when a third world ships.
"""

WORLDS = {
    "vita": {"repository": "vitasdk/vitasdk", "channel_suffix": ""},
    "vita_softfp": {"repository": "vitasdk/vitasdk-softfp", "channel_suffix": "-softfp"},
}


def resolve(channel, world):
    """The (repository, tag base) a channel of the given world publishes as."""
    if world not in WORLDS:
        raise SystemExit(f"worlds: unknown world {world!r} for channel {channel!r}")
    info = WORLDS[world]
    suffix = info["channel_suffix"]
    base = channel[: -len(suffix)] if suffix and channel.endswith(suffix) else channel
    return info["repository"], base
