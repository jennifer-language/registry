# syntax=docker/dockerfile:1

########################################################################
# Docs stage: render all three books into the static site. The user manual is
# the task-shaped guide at /manual; the admin manual is the API and the operator
# CLI at /reference; the specifications are the normative contracts at /specs.
# Grimoire builds one source directory into one output directory, so each book is
# its own config and its own invocation.
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
#     REGISTRY_UID=$(id -u) REGISTRY_GID=$(id -g) docker compose up -d --build
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

# The website's static root: all three rendered books, served at /manual,
# /reference, and /specs. Built in the docs stage rather than copied from the
# build context,
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
COPY --chmod=0755 bin/entrypoint.sh /entrypoint.sh
VOLUME ["/app/data"]
USER ${UID}:${GID}

# The log defaults to the data volume, which is the one directory this image is
# guaranteed to be able to write and the one place a `deckadmin` run through
# `docker exec` can append to the same file. It goes to stdout as well, so
# `docker logs` works without mounting anything.
# The uid the entrypoint drops to when it is started as root. Baked from the
# build args so the two can never disagree.
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
RUN ["jennifer", "lint", "/app/bin/serve", "/app/bin/deckadmin"]

EXPOSE 8080

# No curl in this base image, so the probe is a Jennifer program (see
# bin/healthcheck). Exec form: HEALTHCHECK's shell form would run through
# /bin/sh and bypass the image's entrypoint conventions.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["jennifer", "run", "/app/bin/healthcheck"]

# The entrypoint wraps /usr/bin/jennifer rather than replacing it: started
# unprivileged it hands straight over, and started as root (`user: "0:0"`) it
# first takes ownership of the data volume and then drops back down. CMD is
# still the interpreter's arguments either way.
#
# HEALTHCHECK and `docker exec` bypass ENTRYPOINT, so both still call `jennifer`
# directly and are unaffected by this.
# serve resolves the stdlib from /usr/share/jennifer/modules and its own
# modules (../src/store.j, ...) relative to bin/serve.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["serve", "bin/serve"]
