# The HTTP API

A JSON API over a `flatdb` file: deck metadata and version resolution for anyone,
plus a write surface (publishing, yanking, claiming a scope, co-owners) for an
authenticated caller. The operator's own commands, such as granting a scope,
minting a CI token, or registering a trusted publisher, go through
[`deckadmin`](cli.md) on the server's filesystem and have no HTTP route.

The normative contract is [specs-server.md](/specs/specs-server.html). Where this page and
that one disagree, the specification wins, or the specification needs changing
first. The client's own obligations (negotiating a version, fetching at the
commit, verifying a checksum) are in [specs-client.md](/specs/specs-client.html).

Every API response is `application/json`, except where `/` and `/search` answer
HTML to a browser (below). Every error body is `{"error": "<message>"}`, written
for a developer reading it in a terminal.

## Discovery

A client determines what this registry speaks before it calls anything, from a
fixed path that never changes and is the one thing a client may hard-code:

```
GET /.well-known/jennifer-registry
```

With no login surface configured:

```json
{
  "registry": "jennifer-registry",
  "spec": "0.1.0",
  "apis": [
    { "version": 1, "basePath": "/v1", "deprecated": false },
    { "version": 1, "basePath": "/", "deprecated": false }
  ],
  "features": ["health", "decks", "deck", "resolve", "resolveGraph", "search",
               "scopes", "publish"]
}
```

`url` is added when the deployment declares its public base URL
(`REGISTRY_URL`, [cli.md](cli.md)), and omitted otherwise rather than guessed.

The `auth` object appears when logins or trusted publishing are configured. With
neither, its absence means this deployment accepts no logins, and a client
reports that instead of guessing an endpoint. Set
`REGISTRY_IDENTITY_CLIENTID` and `REGISTRY_TOKEN_KEY` ([cli.md](cli.md)) and the
features grow `claim`, `owners`, `yank`, and `auth`, and the document grows an
`auth` object:

```json
"auth": {
  "provider": "github",
  "flow": "device",
  "deviceUrl": "/v1/auth/device",
  "tokenUrl": "/v1/auth/token",
  "refreshUrl": "/v1/auth/refresh"
}
```

`provider` is the configured identity provider, and `flow` is what that
provider offers (`device`, or `authcode` for an OIDC provider that has no device
endpoint).

With trusted publishing configured (an audience and an issuer, and the issuer's
key set fetched at boot), `auth` also carries a `trustedPublishing` object:

```json
"trustedPublishing": {
  "audience": "registry.example",
  "providers": ["github-actions"],
  "url": "/v1/publish"
}
```

With trusted publishing on and logins off, `auth` holds only that object, and
the missing `deviceUrl` means "accepts no logins".

Those URLs are absolute paths used verbatim, the one exception to prefixing
requests with `basePath`. The endpoints behind them are section 8.4 of
[specs-server.md](/specs/specs-server.html), and the flow a client runs is section 5 of
[specs-client.md](/specs/specs-client.html).

A client intersects `apis[].version` with the versions it supports, uses the
highest, and prefixes every later request with that version's `basePath`. An
empty intersection is a failure naming both sides' versions, not a call that
404s. A path under a version this registry does not serve (`/v2/...`) is `400`
with `{"error": "unsupported API version", "apis": [1]}`.

A version appears once per base path it is served at, canonical path first.
v1 is listed twice here because it is served both at `/v1` and at the bare root;
a client uses the first entry and must not read the repetition as two API
versions.

`apis` and `features` are both derived from the router's own table by
`webapi.discovery`, so the document cannot advertise an operation that is not
served, or a mount that does not exist. `auth` is the one member a registry adds
itself, and it is added only when the endpoints behind it exist.

`features` names the optional operations offered, so a client can refuse an
operation up front instead of provoking a 404. Several routes share a label:
`decks` covers the three `/decks` routes, `yank` covers `/yank` and `/unyank`,
`auth` the three token-exchange routes.

Additive changes do not bump the major. A new field or a new feature name is
not breaking, so clients must ignore what they do not recognise.

## The token exchange

Served only when configured. The registry drives the device flow against the
identity provider, so a client never talks to the provider and never holds its
token.

| Route | Does |
| ----- | ---- |
| `POST /auth/device` | begin a device authorization; returns the code the user types |
| `POST /auth/token` | poll with `{"deviceCode": ...}` until it resolves, or (`authcode`) send `{"code", "codeVerifier", "redirectUri"}` once |
| `POST /auth/refresh` | exchange `{"refreshToken": ...}` for a new pair |

Polling outcomes ride on the status code: `200` approved, `202` pending, `429`
slow down, `403` denied, `410` expired. A success carries `token`, `expiresIn`
(3600), `refreshToken`, `login`, `subject` (the provider's subject id, a string),
`accountId` (the same as a number, only when it is one), and `orgs`, the
organisation logins the token carries. A body without its field is `400`; a provider that cannot be
reached is `502`. A rejected or expired refresh token is `401`.

Under `authcode` (an OIDC provider without a device endpoint) discovery carries
`authorizeUrl`, `clientId` and `scopes` (an array) instead of `deviceUrl`. The
client runs authorization code with PKCE against the provider and sends the
result to `/auth/token`. `redirectUri` must be `http://127.0.0.1:<port>/...` or
`http://[::1]:<port>/...`; anything else, or a code the provider refuses, is `400`.

Every refresh asks the provider, with the provider token kept sealed from the
login, whether it still names the same account. A revoked or expired provider
token ends the login (`401`); a provider that cannot be asked is `502` and leaves
the refresh token valid. A provider whose user tokens expire (a GitHub App with
expiring user tokens: 8 hours) therefore bounds a login to that lifetime.

Refresh tokens rotate. The presented token is spent on use and a new one
issued, so a captured token works exactly once and the theft surfaces as an
unexpected logout. Only a SHA-256 fingerprint is stored, never the token, so the
database holds no live credentials. A login lasts 30 days from the device flow
however often it is refreshed.

## Routes

Every route is served under `/v1` canonically, and at the bare path as a v1
alias for clients that predate discovery. `/` and the well-known path are
unversioned.

| Route | Returns |
| ----- | ------- |
| `GET /` | service identity and a list of the core read routes |
| `GET /health` | `{"status": "ok"}` |
| `GET /decks` | `{"decks": [names...], "page", "pages", "total"}`: 1,000 sorted names a page, `?page=N` |
| `GET /deck?name=<deck>` | one deck's full record, scoped-name safe |
| `GET /decks/:name` | one deck's full record, bare names only |
| `GET /decks/:name/:version` | one version's record |
| `GET /resolve?name=&constraint=` | the best matching version and its pin |
| `GET /resolve-graph?roots=<json>` | the whole transitive graph, flattened and locked |
| `GET /search?q=<query>` | decks matching a query, best first |
| `GET /scopes` | every registered scope and who holds it |
| `POST /publish` | publish a version from a repository and a tag |
| `POST /yank`, `POST /unyank` | withdraw a version, or restore it (logins only) |
| `POST /claim` | claim a scope for the caller (logins only) |
| `POST /owners` | add or remove a co-owner of a scope (logins only) |
| `POST /publishers` | register or remove a trusted publisher on a deck or scope (logins only) |

"Logins only" routes are registered only when the login surface is configured;
otherwise they are `404`.

Two of these answer HTML when the request's `Accept` prefers it, because the
website lives on the same origin: `/` is the landing page for a browser and the
service index for an API client, and `/search` is the results page or the JSON
result set. Both representations run the same code. The website's
own routes are in [cli.md](cli.md#the-website).

### Scoped names must be query parameters

A scoped name like `@acme/routeros` contains a `/`, and percent-encoding does
not help: routers decode `%2F` before matching, so
`GET /decks/%40acme%2Frouteros` matches the two-segment `/decks/:name/:version`
route and resolves to the wrong thing.

`GET /deck?name=...` is the contract, and it is what a client's resolver calls.
The `/decks/:name` path route works for bare names only.

## GET /deck?name=&lt;deck&gt;

The one endpoint a client requires. Everything else is optional.

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
      "keywords": ["mikrotik", "net"],
      "license": "MIT",
      "yanked": false,
      "description": "first release",
      "publishedAt": "1770000000"
    }
  }
}
```

An unknown deck is `404`; a missing `name` is `400`. The record is served as
stored, so a deck published with a README also carries it as `readme`.

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
| `keywords` | the version's tags, normalised, at most five |
| `license` | the manifest's `license`, `""` when it has none |
| `yanked` | whether the version is withdrawn from new resolutions |
| `description` | a one-line summary |
| `publishedAt` | publication time, Unix seconds as text |

The pin depends on the kind, and the field the kind does not use is stored empty
rather than omitted:

- **`git`**: `commit` is the integrity boundary and `checksum` is meaningless.
  Fetch the repository at the commit, not at the ref. A tag is a mutable
  pointer that can be force-pushed after publication; a commit SHA is a content
  hash, and git verifies object hashes on receipt, so the commit that arrives is
  the commit that was published. The `ref` is kept for display and provenance.
- **`tar.gz`**: `checksum` must be present and verified against the fetched
  bytes before unpacking, and `ref` / `commit` are empty.

An absent `requires` / `engines` / `capabilities` / `keywords` is empty, not an
error, an absent `yanked` is false, and an absent `kind` reads as `"tar.gz"` for
records written before the field existed.

## GET /resolve

Turns a name and a constraint into one version and its pin. An empty
`constraint` means `*`. Yanked versions are never chosen.

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
a missing `name` or a constraint outside the grammar is `400`.

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
one version of each deck appears, never a yanked one. A cycle terminates rather
than recursing.

An unsatisfiable graph is `200` with `{"ok": false, "error": "..."}`: the
request was well-formed, the graph was not. So is a graph reaching more than
256 decks. A `400` answers a `roots` that is not a JSON object of strings, more
than 64 roots, an invalid deck name, one name under two spellings, or a
constraint outside the grammar.

The registry is not the authority on resolution. [jvc](https://jvc.jennifer-lang.dev/) resolves locally from
`/deck` metadata; this endpoint is a convenience for other clients and is
optional per the specification. It answers with the same resolver a client
runs: `deckcatalog` gathers every deck the roots reach in one pass, feeds them
into `catalog`, and calls `resolver` once. The resolver does not backtrack.

## GET /search

Decks whose name or description contains `q`, case-insensitively, with name
matches ranked above description-only matches. An empty query returns every
deck, so this is also the machine-readable deck listing. A `q` longer than 200
characters is `400`.

```json
{
  "query": "router",
  "count": 1,
  "results": [
    { "name": "@acme/routeros", "description": "MikroTik RouterOS client",
      "latest": "0.2.0", "versions": 2, "live": true,
      "keywords": ["mikrotik", "net"] }
  ]
}
```

`latest` is the highest live (not yanked) version by SemVer precedence; when
every version is yanked it is the highest of those and `live` is false. `""`
for a deck with none. `keywords` are the newest version's. No match is `200`
with an empty `results`, never a `404`: the query was well-formed, nothing
matched it.

The JSON result set is unpaged. The HTML results page, like `/browse`, shows
100 decks at a time with `?page=`.

The contract leaves the ranking unspecified: display the order you are given
rather than depending on a particular one. Matching is a substring scan over one
deck index the server shares between requests and rebuilds when the database
changes.

## GET /scopes

```json
{ "scopes": [
  { "scope": "acme", "kind": "org", "status": "owned", "owner": "acme-admin" },
  { "scope": "admin", "kind": "user", "status": "reserved" }
] }
```

`status` is `owned` or `reserved`; an owned scope names its owner's **login**,
never the account id that ownership binds to.

## Writes

Every write is a `POST` with a JSON body, and is authorised by the caller, not
by the route. Bodies are capped at 64 KB.

### Who may write

| Credential | Sent as | Accepted on |
| ---------- | ------- | ----------- |
| registry bearer token, from the token exchange | `Authorization: Bearer <token>` | every write (logins only) |
| CI token, minted by `deckadmin mint-token` | `Authorization: Bearer jvcp_...` | `POST /publish` |
| CI identity token (trusted publishing) | `Authorization: Bearer <identity token>`, or `"identityToken"` in the body | `POST /publish` |

A bearer token establishes **name authority**: the caller must own the scope or
be a co-owner, or be an active member of an organisation scope. A CI token is
bound to one scope or one deck. A bearer JWT whose `iss` is the configured CI
issuer is treated as a trusted-publishing token. It is matched against the
deck's binding, else its scope's, registered with `POST /publishers` or
`deckadmin trust` and keyed on the repository id; its
`aud` must be this registry's audience, its commit the one the tag resolves to,
and, for a tag ref, its tag the one published.

### POST /publish

```json
{ "repository": "https://github.com/acme/deck-routeros.git", "tag": "v0.1.0" }
```

Nothing else about the deck comes from the body. The registry resolves the tag
to a commit, reads `deck.toml` (and `README.md`, if any) at that commit, and
takes the name, version, dependencies, engines, capabilities, keywords, and
license from it. For a bearer or CI token it also asks the forge whether the
account behind the publish may push to the repository (source authority, route
A). Success is `201`:

```json
{ "name": "@acme/routeros", "version": "0.1.0", "kind": "git",
  "url": "https://github.com/acme/deck-routeros.git", "ref": "v0.1.0",
  "commit": "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293" }
```

| Status | When |
| ------ | ---- |
| `400` | the body is not JSON; a repository URL or tag this registry will not read from, or a tag shaped like an object id; a tag that does not resolve to a commit, or a ref shadowing the commit; a manifest that fails to parse or validate; a manifest version that disagrees with the tag; a missing entry module |
| `401` | no credential, an invalid or expired one, an unknown or revoked CI token, or an identity token that does not verify |
| `403` | the scope is not registered or not the caller's; the token or binding does not cover this deck; the forge does not confirm push access |
| `409` | that version, build metadata aside, is already published |
| `501` | a bearer token without the login surface, or an identity token without trusted publishing |
| `502` | the forge could not be read |

The credential is checked before any forge call, and the version-conflict `409`
comes after every authorisation check, so a stranger cannot learn which versions
exist.

### POST /yank, POST /unyank

```json
{ "name": "@acme/routeros", "version": "0.1.0" }
```

Bearer token only. `200` with `{"name", "version", "yanked"}`, also when the
version was already in that state. `400` for a missing field or a name that is
not scoped, `401` without a token, `403` when the scope is not the caller's,
then `404` for an unknown version.

### POST /claim

```json
{ "scope": "acme" }
```

Bearer token only. Claims an unregistered scope under the deployment's claim
policy (`derived` by default: the caller's own login, or an organisation the
login carries). `201` with `{"scope", "owner"}`. `400` for a missing or invalid
name, `409` for one already held or reserved, `403` when the policy declines.

### POST /owners

```json
{ "scope": "acme", "subject": "1234567", "action": "add" }
```

Bearer token only, and only the scope's **owner**: a co-owner cannot change the
list. `subject` is the co-owner's subject id at the provider; `action` is `add`
or `remove`, and anything else adds. `200` with `{"scope", "provider", "kind",
"owners"}`, the owner and co-owner ids. `400` for a missing field or a subject
that is empty or contains whitespace,
`403` for anybody but the owner, `404` for an unregistered scope or removing a
non-co-owner, `409` for removing the owner.

### POST /publishers

```json
{ "target": "@acme/tool", "provider": "github-actions", "repositoryId": "123456789",
  "repository": "acme/deck-tool", "workflow": "acme/deck-tool/.github/workflows/publish.yml",
  "refs": "refs/tags/*" }
```

Bearer token only. Registers a trusted publisher (8.9) on a deck, or on a whole
scope with `"target": "@acme"`; `"action": "remove"` removes it. The scope's
owner may do this, or an active member of an organisation scope; a co-owner may
not. `provider` defaults to `github-actions` and `refs` to `refs/tags/*`;
`repositoryId` must be the forge's numeric id. `200` with the binding (`target`,
`provider`, `repositoryId`, `repository`, `workflow`, `refs`, `pending`), or
`{"target", "removed": true}`. `400` for a malformed request, `403` for anybody
else, `404` for an unregistered scope or removing an absent binding.

## Status codes

| Status | When |
| ------ | ---- |
| `400` | malformed or missing parameters, an unsupported API version, a refused publish request |
| `401` | missing or invalid credentials on a write |
| `403` | authenticated, but not permitted |
| `404` | no such deck, version, scope, or endpoint |
| `409` | the version is already published; the scope is already held |
| `501` | a write mechanism this deployment has not configured |
| `502` | the forge or identity provider could not be reached |
| `503` | the respond timeout (120 s by default) passed; the engine answers this itself |

A manifest that fails validation is `400`.

`429` carries a `Retry-After` header and comes from three budgets, each a
sliding one-minute window:

| Budget | Routes | Counted per | Default |
| ------ | ------ | ----------- | ------- |
| `identity.rateLimit` (`REGISTRY_AUTH_RATE_LIMIT`) | `/auth/device`, `/auth/token`, `/auth/refresh` | client address | 30 |
| `writeRateLimit` (`REGISTRY_WRITE_RATE_LIMIT`) | `/publish`, `/claim`, `/owners`, `/publishers`, `/yank`, `/unyank` | authenticated subject or CI token; the address for trusted publishing | 60 |
| `readRateLimit` (`REGISTRY_READ_RATE_LIMIT`) | `/resolve-graph`, and `/search` as JSON with an empty query (the whole index) | client address | 120 |

`0` turns a budget off. A device poll at GitHub's 5-second interval uses 12 of
the login budget. An IPv6 client counts against its /64. Behind a proxy, set
`clientIpHeader`, or every client shares the proxy's budget; the header is read
only on a connection from a loopback or private address, where a proxy can be,
so a client on the public internet cannot name its own address. Other reads
are not rate-limited.

## Plain HTTP when TLS is on

With `tls.enabled`, the plain listener (`addr`, port 80 in the container) serves
only `/.well-known/acme-challenge/` for HTTP-01, `/health`, and a `301` to the
same path on `https://<first tls.domains entry>` for anything else (the query
string is not carried). Bearer and refresh tokens therefore never travel in
clear, and every TLS response carries `Strict-Transport-Security` for a year.
A failed certificate issuance leaves that listener up for a restart to retry;
it does not fall back to serving the registry over plain HTTP.

## Caching

A published version is immutable, so `/deck` responses are safe to cache with a
validator. Every response carries `Vary: Accept`.

The pages and listings that are a function of the database alone (`/`,
`/search`, `/decks`, `/scopes`, `/resolve-graph`, and the website's pages) are
answered `304 Not Modified` to a matching `If-None-Match`, from a tag of the
database file's size and change time, before the database is read. The three
counted lookups (`/deck`, `/decks/:name`, `/resolve`) are excluded, since a
`304` would skip the count.

Reads share one parsed copy of the database, re-parsed when the file changes
and at most 30 seconds old, so `deckadmin` edits appear without a restart.
