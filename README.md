# The Jennifer deck registry

The HTTP repository that [jvc](https://github.com/jennifer-language/jvc),
Jennifer's deck manager, resolves and fetches decks from, plus the operator CLI
that maintains it. jvc is the client; this is the server.

The registry indexes decks; it does not host them. A deck's code stays in its
git repository, and a published version is pinned to the commit its tag pointed
at when it was published. The registry stores the metadata and the coordinates.

## Quick start

```sh
# Serve the registry and the website on :8080, reading data/decks.json
jennifer serve bin/serve

# Hold a scope for the operator, then publish a version into it
jennifer run bin/deckadmin register-namespace acme
jennifer run bin/deckadmin add @acme/routeros 0.1.0 \
    https://github.com/acme/deck-routeros.git \
    --ref v0.1.0 --commit 9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293 \
    "MikroTik RouterOS client"

# What a client asks for
curl 'http://localhost:8080/deck?name=@acme/routeros'
```

An empty or missing database opens as an empty registry; there is nothing to
seed.

## The website

The same server hosts a small read-only site: search at `/`, the full listing at
`/browse`, keywords at `/tags`, a page per deck at `/deck/<scope>/<deck>`, the
user manual at `/manual/`, the admin manual (API and CLI) at `/reference/`, and
the specifications at `/specs/`. `/` and `/search` answer HTML to a browser and
JSON to an API client.

Authors publish with `POST /publish` (from jvc or CI) and operators with
`deckadmin`. There is no publish form, no account management, and no admin UI.

## Layout

```
bin/          the executables: serve, deckadmin, healthcheck (no .j; run directly)
src/          the modules, each with a co-located _test.j overlay
data/         the flatdb database and anything else the server writes (gitignored)
manual/       user guide sources, served at /manual
reference/    admin manual sources (API, CLI), served at /reference
specs/        the normative specifications, served at /specs
public/       the website's static root, built by grimoire (gitignored)
deck.toml     this project's own app manifest
```

## Documentation

**The manual** is for people using the registry:

| | |
| - | - |
| [manual/finding-a-deck.md](manual/finding-a-deck.md) | search, and how to read a deck page |
| [manual/using-a-deck.md](manual/using-a-deck.md) | depending on a deck, and what install does |
| [manual/publishing-a-deck.md](manual/publishing-a-deck.md) | what your repository needs to be listed |

**The admin manual** is for operators:

| | |
| - | - |
| [reference/cli.md](reference/cli.md) | the executables, configuration, and the website |
| [reference/api.md](reference/api.md) | the HTTP API |

**The specifications** are for implementers of either side:

| | |
| - | - |
| [specs/specs-server.md](specs/specs-server.md) | the server specification, the normative contract for this project |
| [specs/specs-client.md](specs/specs-client.md) | the client specification, headed for the jvc repository |

All three are built with [Grimoire](https://github.com/jennifer-language/grimoire) and
served by `serve`. Grimoire builds one source directory into one output
directory, so each book has its own config:

```sh
docker run --rm --pull always --user "$(id -u):$(id -g)" \
    -v "$PWD:/work" ghcr.io/jennifer-language/grimoire build --clean
docker run --rm --pull always --user "$(id -u):$(id -g)" -v "$PWD:/work" \
    ghcr.io/jennifer-language/grimoire build --clean \
    --config grimoire-manual.toml
docker run --rm --pull always --user "$(id -u):$(id -g)" -v "$PWD:/work" \
    ghcr.io/jennifer-language/grimoire build --clean \
    --config grimoire-specs.toml
```

The container image builds the books in its own stage, so `public/` is never
committed or shipped stale. A deployment without one answers its URL with a page
saying how to build it.

## Tests and lint

```sh
for t in store admin apiview webview authview token search policy identity forge \
         forgecred scope scopeview reserved audit trustpub citoken manifest publishview \
         config certs stats keywords deckcatalog constraint deckname catalog \
         resolver; do
    jennifer test src/${t}_test.j
done
for t in policy/operator policy/derived policy/firstcome \
         identity/github identity/gitea identity/gitlab identity/oidc \
         forge/github forge/gitea forge/gitlab; do
    jennifer test src/${t}_test.j
done

jennifer fmt -l src/*.j src/*/*.j bin/serve bin/deckadmin bin/healthcheck  # lists nothing

# Zero findings, info included. The programs are named one by one: bin/ also
# holds entrypoint.sh, which is shell.
jennifer lint src/*.j src/*/*.j bin/serve bin/deckadmin bin/healthcheck
```

## License

LGPL-3.0-only. See [LICENSE.md](LICENSE.md).
