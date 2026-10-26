# syntax=docker/dockerfile:1

########################################################################
# Docs stage: render the three books into the static site: the user manual at
# /manual, the admin manual (API and operator CLI) at /reference, the
# specifications at /specs. Grimoire builds one source directory into one output
# directory, so each book has its own config and invocation.
#
# The image's entrypoint is `jennifer run /opt/grimoire/grimoire`, so RUN
# invokes the binary directly. Output lands under /work/public, per each config.
#
# No `--clean`: this stage starts from an empty filesystem and .dockerignore
# keeps `public` out of the context, so there is no stale page to prune and no
# render from a working tree can reach the image.
########################################################################
FROM ghcr.io/jennifer-language/grimoire AS docs

WORKDIR /work
COPY grimoire.toml grimoire-manual.toml grimoire-specs.toml ./
COPY reference/ ./reference/
COPY manual/ ./manual/
COPY specs/ ./specs/
RUN ["jennifer", "run", "/opt/grimoire/grimoire", "build"]
RUN ["jennifer", "run", "/opt/grimoire/grimoire", "build", "--config", "grimoire-manual.toml"]
RUN ["jennifer", "run", "/opt/grimoire/grimoire", "build", "--config", "grimoire-specs.toml"]

########################################################################
# Runtime stage: the official interpreter image plus this app. Its module
# library ships `webapi` / `args` / `html` / `http`, so nothing needs adding.
#
# Pinned to a release. Every .j file here and the bundled `webapi` module
# declare `pragma-jennifer-version: >=0.25.0`, so 0.25.0 is the first release
# that runs this. Raise the pin only after the suite passes and
# `jennifer serve bin/serve` boots on the new version.
########################################################################
FROM ghcr.io/jennifer-language/jennifer:0.25.0 AS runtime

# Who the server runs as. The defaults are the base image's unprivileged user,
# which suits a named volume: Docker initialises it from the image, so the
# ownership matches.
#
# A bind mount keeps its host ownership, so a uid mismatch is `permission
# denied` on write. `store.save` is crash-atomic and writes a temp file beside
# the target, so the directory must be writable, not only the file. Build with
# the host's ids:
#
#     REGISTRY_UID=$(id -u) REGISTRY_GID=$(id -g) docker compose up -d --build
#
# The compose variables are not named UID/GID because `UID` is readonly and
# unexported in bash, so `${UID}` in a compose file resolves to nothing and the
# default is used.
ARG UID=10001
ARG GID=999

# The application. The entry points live in bin/ and import the modules as
# ../src/*.j, so both trees are copied with their structure intact.
WORKDIR /app
COPY bin/ /app/bin/
COPY src/ /app/src/

# The website's static root: the three rendered books, served at /manual,
# /reference, and /specs. Built in the docs stage so an image never ships a
# stale local render (public/ is dockerignored).
COPY --from=docs /work/public /app/public

# The registry database. A missing file opens as an empty registry, so there is
# nothing to seed; the mount persists edits made with deckadmin.
#
# The chown is the only step needing root; the unprivileged user is restored
# right after. It runs before VOLUME so an anonymous volume inherits the
# ownership. The numeric form lets UID/GID be any host id, with no account in
# /etc/passwd.
#
# Only data/ changes owner. Code and rendered books stay root's, so the server
# process cannot rewrite bin/serve for the next start or plant a page under
# public/. COPY keeps the build context's modes (possibly 750), so they are made
# readable (and executable where they were) for everybody and writable by root
# alone.
USER root
RUN mkdir -p /app/data && \
    chmod -R a+rX,go-w /app/bin /app/src /app/public && \
    chown -R ${UID}:${GID} /app/data
COPY --chmod=0755 bin/entrypoint.sh /entrypoint.sh
VOLUME ["/app/data"]
USER ${UID}:${GID}

# The log defaults to the data volume: the one directory the image can always
# write, and where a `deckadmin` run through `docker exec` appends to the same
# file. It also goes to stdout, so `docker logs` works without a mount.
# REGISTRY_RUN_UID/GID: the ids the entrypoint drops to when started as root,
# baked from the build args so the two cannot disagree.
ENV REGISTRY_RUN_UID="${UID}" \
    REGISTRY_RUN_GID="${GID}" \
    REGISTRY_ADDR=":8080" \
    REGISTRY_DB="/app/data/decks.json" \
    REGISTRY_TLS_CERTDIR="/app/data/tls" \
    REGISTRY_ACME_CHALLENGEDIR="/app/data/acme-challenge" \
    REGISTRY_LOG="/app/data/registry.log" \
    REGISTRY_LOG_LEVEL="info" \
    REGISTRY_LOG_FORMAT="logfmt" \
    REGISTRY_LOG_REQUESTS="0"

# Fail the build early if the interpreter or the module tree is broken: this
# parses the whole server, its modules, and every pragma in them.
RUN ["jennifer", "lint", "/app/bin/serve", "/app/bin/deckadmin", "/app/bin/healthcheck"]

EXPOSE 8080

# No curl in this base image, so the probe is a Jennifer program (see
# bin/healthcheck). Exec form: HEALTHCHECK's shell form would run through
# /bin/sh and bypass the image's entrypoint conventions.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["jennifer", "run", "/app/bin/healthcheck"]

# The entrypoint wraps /usr/bin/jennifer: started unprivileged it hands straight
# over; started as root (`user: "0:0"`) it first takes ownership of the data
# volume, then drops privileges. CMD is the interpreter's arguments either way.
#
# HEALTHCHECK and `docker exec` bypass ENTRYPOINT and call `jennifer` directly.
# serve resolves the stdlib from /usr/share/jennifer/modules and its own
# modules (../src/store.j, ...) relative to bin/serve.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["serve", "bin/serve"]
