# The Jennifer deck registry: administrator manual

> How to find, use, or publish a deck is in the [user manual](/manual/). The
> normative contract is in the [specifications](/specs/).
>
> These pages cover the HTTP API and the operator CLI: what this server serves,
> and how to run it.

The HTTP repository that [jvc](https://github.com/jennifer-language/jvc),
Jennifer's deck manager, resolves and fetches decks from, plus the operator CLI
that maintains it. [jvc](https://jvc.jennifer-lang.dev/) is the client; this is the server.

The registry indexes; it does not host. A deck's code stays in its git
repository, and a published version is pinned to the commit its tag pointed at
when it was published. The registry stores the metadata and the coordinates, so
a moved tag does not affect anybody who already depends on that version.

## These pages

| | |
| - | - |
| [The executables](cli.md) | `serve` and `deckadmin`: every command and flag |
| [The HTTP API](api.md) | endpoints, the version record, discovery |
| [Server specification](/specs/specs-server.html) | the normative contract this project implements, in the [specifications](/specs/) book |
| [Client specification](/specs/specs-client.html) | what a client must do, in the [specifications](/specs/) book |

## In one minute

```sh
# Serve the registry and the website on :8080
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
seed on first run.

## The shape of it

Two thin executables in `bin/`, over modules in `src/` that hold all the logic
and all the tests:

- **`serve`** answers the JSON API, and serves the website: a deck listing,
  search, a page per deck, and these documents. The website is read-only. The
  API's write routes (publish, yank, claim, co-owners, and the login token
  exchange) take an authenticated client such as jvc, never a web form.
- **`deckadmin`** is the operator CLI, on the server's filesystem: granting and
  reserving scopes, adding versions by hand, CI tokens, trusted publishers, and
  revoking logins.
