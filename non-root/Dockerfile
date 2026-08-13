# syntax=docker/dockerfile:1

# The non-root variant is not a second image. It is the published one with USER
# changed, so it reuses its layers -- no bytes are added to the registry -- and
# it cannot drift from the image it names.
#
# BASE_IMAGE has to be a digest rather than a tag. Layering on a tag is how the
# previous pipeline came to publish a non-root image carrying an SDK two months
# older than the one it claimed.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Everything the user needs is already theirs: the SDK is owned by vitasdk with
# group 0 and g+rwX, so `vdpm install` works here without sudo and without a
# recursive chown of its own.
USER vitasdk

LABEL org.vitasdk.user="vitasdk"
