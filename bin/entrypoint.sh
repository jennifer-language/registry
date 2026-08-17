#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# Fix the data directory's ownership, but only when started as root.
#
# The image runs as an unprivileged user, and a volume mounted over /app/data
# arrives with whatever ownership the host gave it. The container cannot chown
# its way out of that, because chown needs root and the whole point of the
# USER line is that it does not have it. So the common symptom is a registry
# that starts, serves, and refuses every write.
#
# This script closes that gap **without changing the default posture**:
#
#   * started unprivileged, which is what the image does on its own, it changes
#     nothing and hands straight over to the interpreter;
#   * started as root - `user: "0:0"` in a compose or stack file - it takes the
#     ownership of /app/data and then drops to the unprivileged user before
#     exec'ing, so the registry itself never runs with privileges it does not
#     need.
#
# Opting in is therefore one line in a deployment, and opting out is the
# default. A registry that quietly ran as root to spare an operator a chown
# would be a poor trade.
set -eu

DATA_DIR="${REGISTRY_DATA_DIR:-/app/data}"
TARGET_UID="${REGISTRY_RUN_UID:-10001}"
TARGET_GID="${REGISTRY_RUN_GID:-999}"

if [ "$(id -u)" = "0" ]; then
    # Only touch what is actually wrong. A recursive chown over a large data
    # directory on every restart is a slow no-op, and on a mount that cannot be
    # chowned at all (NFS with root_squash, a read-only volume) failing here
    # would turn a working read-only registry into a container that will not
    # start. Hence the guard and the `|| true`.
    if [ -d "$DATA_DIR" ]; then
        current="$(stat -c '%u:%g' "$DATA_DIR" 2>/dev/null || echo 'unknown')"
        if [ "$current" != "${TARGET_UID}:${TARGET_GID}" ]; then
            echo "entrypoint: taking ownership of $DATA_DIR for ${TARGET_UID}:${TARGET_GID} (was $current)" >&2
            chown -R "${TARGET_UID}:${TARGET_GID}" "$DATA_DIR" || {
                echo "entrypoint: could not chown $DATA_DIR; continuing anyway" >&2
                echo "entrypoint: the registry will serve what it has and refuse writes" >&2
            }
        fi
    fi
    exec setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --clear-groups \
        /usr/bin/jennifer "$@"
fi

# Already unprivileged: nothing to fix, and nothing to drop to.
exec /usr/bin/jennifer "$@"
