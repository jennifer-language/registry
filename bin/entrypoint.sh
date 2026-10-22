#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# Fix the data directory's ownership, but only when started as root.
#
# The image runs as an unprivileged user, and a volume mounted over /app/data
# keeps the host's ownership, which that user cannot chown. The symptom is a
# registry that serves and refuses every write.
#
#   * Started unprivileged (the image default): changes nothing and execs the
#     interpreter.
#   * Started as root (`user: "0:0"` in a compose or stack file): chowns
#     /app/data, then drops to the unprivileged user before exec'ing, so the
#     registry never runs as root.
set -eu

DATA_DIR="${REGISTRY_DATA_DIR:-/app/data}"
TARGET_UID="${REGISTRY_RUN_UID:-10001}"
TARGET_GID="${REGISTRY_RUN_GID:-999}"

if [ "$(id -u)" = "0" ]; then
    # Chown only when the owner is wrong, to skip a slow recursive no-op. A failed
    # chown (NFS root_squash, read-only volume) is not fatal, so a read-only
    # registry still starts.
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
