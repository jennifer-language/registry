# The HTTP API

A read-only JSON API over a `flatdb` file, serving deck metadata and resolving
version constraints. There is no write path: every change goes through
[`deckadmin`](cli.md) on the server's filesystem.

The normative contract is [specs-server.md](/specs/specs-server.html). Where this page and
that one disagree, the specification wins, or the specification needs changing
first. The client's own obligations - negotiating a version, fetching at the
commit, verifying a checksum - are [specs-client.md](/specs/specs-client.html).

Every response is `application/json`. Every error body is
`{"error": "<message>"}`, written for a developer reading it in a terminal.

## Discovery

A client determines what this registry speaks **before** it calls anything, from
a fixed path that never changes and is the one thing a client may hard-code:

```
GET /.well-known/jennifer-registry
```

```json
{
  "registry": "jennifer-registry",
  "spec": "0.1.0",
  "apis": [
    { "version": 1, "basePath": "/v1", "deprecated": false },
    { "version": 1, "basePath": "/", "deprecated": false }
  ],
  "features": ["health", "decks", "deck", "resolve", "resolveGraph", "search"]
}
```

**The `auth` object appears only when the login surface is configured**, and its
absence is the answer rather than an omission: this deployment accepts no
logins, so a client reports that instead of guessing an endpoint. Set
`REGISTRY_IDENTITY_CLIENTID` and `REGISTRY_TOKEN_KEY` ([cli.md](cli.md)) and the same
document grows an `auth` feature and an `auth` object:

```json
"auth": {
  "provider": "github",
  "flow": "device",
  "deviceUrl": "/v1/auth/device",
  "tokenUrl": "/v1/auth/token",
  "refreshUrl": "/v1/auth/refresh"
}
```

Those URLs are absolute paths used verbatim, which is the one exception to
prefixing requests with `basePath`. The endpoints behind them are section 8.4 of
[specs-server.md](/specs/specs-server.html), and the flow a client runs is section 4 of
[specs-client.md](/specs/specs-client.html).

## The token exchange

Served only when configured. **The registry drives the device flow against
GitHub**, so a client never talks to GitHub and never holds a GitHub token.

| Route | Does |
| ----- | ---- |
| `POST /auth/device` | begin a device authorization; returns the code the user types |
| `POST /auth/token` | poll with `{"deviceCode": ...}` until it resolves |
| `POST /auth/refresh` | exchange `{"refreshToken": ...}` for a new pair |

Polling outcomes ride on the status code: `200` approved, `202` pending, `429`
slow down, `403` denied, `410` expired. A success carries `token`, `expiresIn`,
`refreshToken`, `login`, and `accountId`.

**Refresh tokens rotate.** The presented token is spent on use and a new one
issued, so a captured token works exactly once and the theft surfaces as an
unexpected logout rather than as silent access. Only a SHA-256 fingerprint is
stored, never the token, so the database is not a set of live credentials.

A client intersects `apis[].version` with the versions it supports, uses the
highest, and prefixes every later request with that version's `basePath`. An
empty intersection is a failure naming both sides' versions, not a call that
404s.

**A version appears once per base path it is served at**, canonical path first.
v1 is listed twice here because it is served both at `/v1` and at the bare root;
a client uses the first entry and must not read the repetition as two API
versions.

`apis` and `features` are both derived from the router's own table by
`webapi.discovery`, so the document cannot advertise an operation that is not
served, or a mount that does not exist. `auth` is the one member a registry adds
itself, which is why it is added only when the endpoints behind it exist.

`features` names the optional operations actually offered, so a client can
refuse an operation up front instead of provoking a 404. The write features
(`publish`, `yank`, `owners`) are absent because they do not exist yet, and
`auth` is absent unless the login surface is configured.

**Additive changes do not bump the major.** A new field or a new feature name is
not breaking, so clients must ignore what they do not recognise.

## Routes

Every route is served under `/v1` canonically, and at the bare path as a v1
alias for clients that predate discovery. `/` and the well-known path are
unversioned.

| Route | Returns |
| ----- | ------- |
| `GET /` | service identity and the routes offered |
| `GET /health` | `{"status": "ok"}` |
| `GET /decks` | `{"decks": [names...]}` |
| `GET /deck?name=<deck>` | one deck's full record, scoped-name safe |
| `GET /decks/:name` | one deck's full record, bare names only |
| `GET /decks/:name/:version` | one version's record |
| `GET /resolve?name=&constraint=` | the best matching version and its pin |
| `GET /resolve-graph?roots=<json>` | the whole transitive graph, flattened and locked |
| `GET /search?q=<query>` | decks matching a query, best first |

Two of these answer HTML instead when the request's `Accept` prefers it, because
the website lives on the same origin: `/` is the landing page for a browser and
the service index for an API client, and `/search` is the results page or the
JSON result set. Both run the same code, so they cannot disagree. The website's
own routes are in [cli.md](cli.md#the-website).

### Scoped names must be query parameters

A scoped name like `@acme/routeros` contains a `/`, and percent-encoding does
not save it: routers decode `%2F` **before** matching, so
`GET /decks/%40acme%2Frouteros` matches the two-segment `/decks/:name/:version`
route and resolves to the wrong thing.

`GET /deck?name=...` is the contract, and it is what a client's resolver calls.
The `/decks/:name` path route works for bare names only. This is the single most
common way to get this API wrong.

## GET /deck?name=&lt;deck&gt;

The one endpoint a client genuinely requires. Everything else is optional.

```json
{
  "name": "@acme/routeros",
  "description": "MikroTik RouterOS client",
  "versions": {
    "0.1.0": {
      "version": "0.1.0",
      "kind": "git",
      "url": "https://github.com/acme/deck-routeros.git",
      "ref": "v0.1.0",
      "commit": "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
      "checksum": "",
      "requires": { "@acme/net": "^1.0.0" },
      "engines": { "jennifer": ">=0.24.0" },
      "capabilities": ["net"],
      "description": "first release",
      "publishedAt": "1770000000"
    }
  }
}
```

An unknown deck is `404`; a missing `name` is `400`.

### The version record

| Field | Meaning |
| ----- | ------- |
| `version` | the SemVer version |
| `kind` | `"git"` for a repository-hosted deck, `"tar.gz"` for an uploaded artifact |
| `url` | the git clone URL, or the artifact URL |
| `ref` | the tag the version was published from (git) |
| `commit` | the full 40-character SHA that tag pointed at, at publish time (git) |
| `checksum` | `sha256:<hex>` of the artifact bytes (tar.gz) |
| `requires` | this version's runtime dependencies, deck name to constraint |
| `engines` | interpreters that can run it, engine name to constraint |
| `capabilities` | host capabilities its code needs (`net`, `exec`, `sql`) |
| `description` | a one-line summary |
| `publishedAt` | publication time, Unix seconds as text |

The pin depends on the kind, and the field the kind does not use is stored empty
rather than omitted:

- **`git`**: `commit` is the integrity boundary and `checksum` is meaningless.
  Fetch the repository **at the commit, not at the ref**. A tag is a mutable
  pointer that can be force-pushed after publication; a commit SHA is a content
  hash, and git verifies object hashes on receipt, so the commit that arrives is
  the commit that was published. The `ref` is kept for display and provenance.
- **`tar.gz`**: `checksum` must be present and verified against the fetched
  bytes before unpacking, and `ref` / `commit` are empty.

An absent `requires` / `engines` / `capabilities` is empty, not an error, and an
absent `kind` reads as `"tar.gz"` for records written before the field existed.

## GET /resolve

Turns a name and a constraint into one version and its pin. An empty
`constraint` means `*`.

```json
{
  "found": true,
  "name": "@acme/routeros",
  "version": "0.1.0",
  "kind": "git",
  "url": "https://github.com/acme/deck-routeros.git",
  "ref": "v0.1.0",
  "commit": "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
  "checksum": "",
  "description": "MikroTik RouterOS client"
}
```

Nothing satisfying is `404` with `{"found": false, "name": ..., "error": ...}`;
a missing `name` is `400`.

## GET /resolve-graph

`roots` is a URL-encoded JSON object of deck name to constraint. The reply is
the whole dependency graph, flattened and version-locked, one entry per deck in
the order a client should install them:

```json
{
  "ok": true,
  "resolved": [
    {
      "name": "@acme/routeros",
      "version": "0.1.0",
      "kind": "git",
      "url": "https://github.com/acme/deck-routeros.git",
      "ref": "v0.1.0",
      "commit": "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
      "checksum": "",
      "engines": { "jennifer": ">=0.24.0" },
      "capabilities": ["net"],
      "description": "..."
    }
  ]
}
```

When several requirements constrain one deck, the chosen version satisfies all
of them simultaneously and is the highest published version that does. Exactly
one version of each deck appears. A cycle terminates rather than recursing.

An unsatisfiable graph is `200` with `{"ok": false, "error": "..."}`: the
request was well-formed, the graph was not. A malformed `roots` object is `400`.

**The registry is not the authority on resolution.** jvc resolves locally from
`/deck` metadata; this endpoint is a convenience for other clients and is
optional per the specification. It answers with the *same* resolver a client
runs: `deckcatalog` feeds the store's decks into `catalog` and calls `resolver`,
seeding only the decks the resolver asks for.

## GET /search

Decks whose name or description matches `q`, case-insensitively, with name
matches ranked above description-only matches. An **empty query returns every
deck**, so this is also the machine-readable deck listing.

```json
{
  "query": "router",
  "count": 1,
  "results": [
    { "name": "@acme/routeros", "description": "MikroTik RouterOS client",
      "latest": "0.2.0", "versions": 2 }
  ]
}
```

`latest` is the highest published version by SemVer precedence, `""` for a deck
with none. No match is `200` with an empty `results`, never a `404`: the query
was well-formed, nothing matched it.

The ranking is deliberately unspecified in the contract - display the order you
are given rather than depending on a particular one. Matching is a substring
scan, which for a registry this size is exact, needs no index to keep in sync,
and stays correct as the store changes underneath it.

## Status codes

| Status | When |
| ------ | ---- |
| `400` | malformed or missing parameters |
| `404` | no such deck or version |

The specification also reserves `401`, `403`, `409`, `422`, and `429` for the
write and identity surface, which does not exist yet.

## Caching

A published version is immutable, so `/deck` responses are safe to cache with a
validator. Nothing here is generated per request beyond a store read; the store
is reopened per request so `deckadmin` edits appear without a restart.
