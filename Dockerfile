# syntax=docker/dockerfile:1

########################################################################
# Docs stage: render both books into the static site. The manual is the
# task-shaped user guide at /manual; the reference is the API and the
# specifications at /reference. Grimoire builds one source directory into one
# output directory, so each book is its own config and its own invocation.
#
# The image's entrypoint is `jennifer run /opt/grimoire/grimoire`, so RUN
# invokes the binary directly. Output lands under /work/public, per each config.
#
# No `--clean` here, unlike a local build: this stage starts from an empty
# filesystem and .dockerignore keeps `public` out of the context, so there is
# never a stale page to prune. That is the same reason the image cannot ship a
# rendered copy left over from someone's working tree.
########################################################################
FROM ghcr.io/jennifer-language/grimoire AS docs

WORKDIR /work
COPY grimoire.toml grimoire-manual.toml ./
COPY reference/ ./reference/
COPY manual/ ./manual/
RUN ["jennifer", "run", "/opt/grimoire/grimoire", "build"]
RUN ["jennifer", "run", "/opt/grimoire/grimoire", "build", "--config", "grimoire-manual.toml"]

########################################################################
# Runtime stage: the official interpreter image plus this app. Its module
# library ships `webapi` / `args` / `html` / `http`, so nothing needs adding.
#
# The `dev` tag is deliberate. Every .j file here declares
# `pragma-jennifer-version: >=0.25.0`, and so does the bundled `webapi`
# module; the newest release tag is 0.24.0, which a release build would
# compare against and refuse. A dev build bypasses the floor. Move to a
# release tag as soon as one satisfies the pragma.
#
# `dev` is a moving tag, so build with --pull to avoid a stale local copy.
########################################################################
FROM ghcr.io/jennifer-language/jennifer:dev AS runtime

# Who the server runs as. The defaults are the base image's own unprivileged
# user, which is right for a named volume: Docker initialises one from the
# image, so the ownership matches by construction.
#
# **A bind mount does not work that way.** The host directory keeps its host
# ownership, and the container process is a bare uid to the kernel, so a uid
# mismatch is a hard `permission denied` on write - and because `store.save` is
# crash-atomic, it writes a temp file *beside* the target, so the directory has
# to be writable, not merely the file. Build with the host's ids to match:
#
#     JVC_UID=$(id -u) JVC_GID=$(id -g) docker compose up -d --build
#
# Named on purpose: `UID` is readonly and unexported in bash, so `${UID}` in a
# compose file silently resolves to nothing and would quietly take the default.
ARG UID=10001
ARG GID=999

# The application. The entry points live in bin/ and import the modules as
# ../src/*.j, so both trees are copied with their structure intact.
WORKDIR /app
COPY bin/ /app/bin/
COPY src/ /app/src/

# The website's static root: both rendered books, served at /manual and
# /reference. Built in the docs stage rather than copied from the build context,
# so an image never ships a stale local render (public/ is dockerignored for
# that reason).
COPY --from=docs /work/public /app/public

# The registry database. A missing file opens as an empty registry, so there is
# nothing to seed; the mount is what persists edits made with deckadmin.
#
# The chown is the one step needing root, so the unprivileged user is restored
# immediately after. It runs before VOLUME so an anonymous volume inherits the
# ownership; the numeric form is used because UID/GID need not name an account
# that exists in /etc/passwd, which is what lets an arbitrary host id work.
USER root
RUN mkdir -p /app/data && chown -R ${UID}:${GID} /app
VOLUME ["/app/data"]
USER ${UID}:${GID}

# The log defaults to the data volume, which is the one directory this image is
# guaranteed to be able to write and the one place a `deckadmin` run through
# `docker exec` can append to the same file. It goes to stdout as well, so
# `docker logs` works without mounting anything.
ENV JVC_ADDR=":8080" \
    JVC_DB="/app/data/decks.json" \
    JVC_LOG="/app/data/registry.log" \
    JVC_LOG_LEVEL="info" \
    JVC_LOG_FORMAT="logfmt" \
    JVC_LOG_REQUESTS="0"

# Fail the build early if the interpreter or the module tree is broken: this
# parses the whole server, its modules, and every pragma in them.
RUN ["jennifer", "lint", "/app/bin/serve", "/app/bin/deckadmin"]

EXPOSE 8080

# No curl in this base image, so the probe is a Jennifer program (see
# bin/healthcheck). Exec form: HEALTHCHECK's shell form would run through
# /bin/sh and bypass the image's entrypoint conventions.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["jennifer", "run", "/app/bin/healthcheck"]

# The base image's entrypoint is /usr/bin/jennifer, so CMD is its arguments.
# serve resolves the stdlib from /usr/share/jennifer/modules and its own
# modules (../src/store.j, ...) relative to bin/serve.
CMD ["serve", "bin/serve"]
