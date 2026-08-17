# The Jennifer deck registry: client specification

- **Version:** 0.1.0 (draft)
- **Date:** 2026-08-15
- **Audience:** the team building jvc, the Jennifer deck manager
- **Companion:** [specs-server.md](specs-server.md), the registry half

This is the contract a **client** of a deck registry must fulfil. The key words
**MUST**, **SHOULD**, and **MAY** are used in the RFC 2119 sense.

> **Scope, and who owns this document.** This half specifies what a client does:
> negotiating an API version, fetching and verifying deck code, logging in, and
> resolving a dependency graph. The **wire format is not specified here** - the
> discovery document, the version record, the endpoints, and their status codes
> are normative in [specs-server.md](specs-server.md), because the registry
> produces them. This document references it rather than restating it, so the
> two cannot drift.
>
> Both halves were split out of a single `registry-specs.md` on 2026-08-15 so
> that each project owns its own side. **This half is intended to move to the
> jvc repository**; the registry repository maintains only the server half.

---

## 1. What a client is responsible for

A registry serves metadata. Everything that turns metadata into an installed
deck is the client's job:

| Responsibility | Section |
| -------------- | ------- |
| choosing which registry a scope resolves at | 2 |
| deciding which API version to speak | 3 |
| refusing an operation the registry does not offer | 3.3 |
| fetching code, and verifying it | 4 |
| obtaining a token, and sending it | 5 |
| folding names, and building the vendor path | 6 |
| resolving the dependency graph | 7 |
| enforcing `engines` and `capabilities` | 8 |

**The registry is not the authority on resolution.** A client **SHOULD** resolve
locally from per-deck metadata (`GET /deck?name=`), because that is the one
endpoint every registry must offer. The server-side `/resolve` and
`/resolve-graph` are a convenience and **MAY** be absent.

## 2. Which registry

**A project is not limited to one registry.** A client **MUST** support mapping a
**scope** to a registry, which is what lets a project depend on internal decks
and public ones at once:

```
@acme/*  ->  https://registry.internal.example
*        ->  https://decks.jennifer-lang.org
```

Deck names are already scoped, so the scope is the natural unit. Everything in
this document that speaks of "the registry" means **the registry that scope maps
to**.

### 2.1 It is a mapping, not a search order

**A scope resolves at exactly one registry.** A client **MUST NOT** try a second
registry when the first does not have the deck, and **MUST** report the miss
against the mapped registry.

This is not a performance preference, it is the defence against **dependency
confusion**. If a client searched several registries for a name, anyone could
publish `@acme/foo` on a public registry and have it preferred over, or raced
against, the internal deck of the same name. That attack has repeatedly hit
ecosystems whose clients merge registries into one search space. A strict mapping
removes the ambiguity by construction: `@acme` is internal or it is public, and
never both.

A client **SHOULD** warn when a mapping is added that shadows an already-locked
scope, since that changes what an existing lockfile means.

### 2.2 Transitive dependencies follow the consumer's mapping

A version record's `requires` names `@scope/deck` and says nothing about a
registry, deliberately: a deck does not get to decide where its consumers fetch
from. So **the consuming project's mapping decides**, for direct and transitive
dependencies alike.

That is what makes an internal mirror or a fork of a public scope workable, and
it is also why the mapping has to be unambiguous.

### 2.3 The lockfile records the registry

A client **MUST** record, per resolved deck, which registry it came from,
preferring the `url` the registry advertises in its discovery document
(`specs-server.md` section 4.1) over the address it happened to dial, and falling
back to that address when the registry declares none. Without
it, the same lockfile resolves to different code on a machine with a different
mapping, which is the exact failure the lockfile exists to prevent.

On install, a client **MUST** fetch each locked deck from its recorded registry,
and **MUST** fail rather than silently substitute when the current mapping
disagrees with the lockfile. Reporting the disagreement is the useful behaviour;
picking a side silently is not.

## 3. Version negotiation

Before anything else, a client fetches the discovery document from the fixed,
unversioned path. It is the one thing a client may hard-code:

```
GET /.well-known/jennifer-registry
```

Its shape is [specs-server.md](specs-server.md) section 4.1.

A client **MUST**:

1. fetch the discovery document;
2. intersect `apis[].version` with the versions it supports;
3. use the **highest** version in that intersection, and prefix every subsequent
   request with that version's `basePath`;
4. if the intersection is empty, **fail with a message naming both sides'
   versions** rather than attempting a call.

A useful failure reads like this, not like a 404:

```
this registry speaks API v2 and v3; jvc 0.1.0 supports v1.
upgrade jvc, or point at a registry that still serves v1.
```

### 3.1 Several base paths for one version

A version **MAY** appear more than once in `apis`, once per base path it is
served at. A client **SHOULD** use the **first** entry for the version it
selects; registries list the canonical path first. A client **MUST NOT** treat
the repetition as two different API versions.

### 3.2 A registry with no discovery document

A `404` for the well-known path **MUST** be treated as **API v1 rooted at `/`**.
This keeps prototype and private registries working. A client **MUST NOT** treat
that `404` as an error.

### 3.3 Features

`features` names the optional operations the registry actually implements. A
client **MUST** treat an absent feature as "not offered" and say so plainly,
rather than provoking a `404`:

```
this registry does not offer publishing (no `publish` feature).
```

A client **MUST** ignore feature names it does not recognise, and **MUST** ignore
unrecognised fields anywhere in the document. That is what makes additive
registry changes non-breaking.

### 3.4 Caching and deprecation

A client **SHOULD** cache the discovery document for the duration of a command
rather than fetching it per request, and **SHOULD** warn when the selected
mount's `deprecated` is true, naming the `sunset` date if one is given.

## 4. Fetching and integrity

The registry indexes; it does not host. A version record tells the client where
the code is and how it is pinned. Which pin applies depends on `kind`
([specs-server.md](specs-server.md) section 3).

### 4.1 `kind: "git"` - fetch the commit, never the ref

A client **MUST** fetch the repository at the recorded `commit`, not at the
`ref`.

- **A tag is a mutable pointer.** `v1.0.0` can be force-pushed to a different
  commit after publication. Resolving by tag at install time would let an author
  change what a published version means.
- **A commit SHA is a content hash.** Git verifies object hashes on receipt, so
  the commit that arrives is the commit that was published. No separate checksum
  is needed, and none is recorded: `checksum` is meaningless for this kind and
  **MUST NOT** be treated as an integrity signal.

The `ref` is for display and provenance. A client **MAY** show it, and **MAY**
warn when the remote's tag no longer points at the recorded commit, since that
usually means somebody rewrote history by mistake.

**A fetch that cannot produce the recorded commit MUST fail, never fall back.**
Not to the `ref`, not to the default branch, not to a generated archive. The URL
in a version record is only a coordinate and can come to name a **different
party's repository** without anyone touching the registry: GitHub frees a
released username immediately, repository redirects break as soon as somebody
recreates a repository of that name, and the new owner may hold the same history
([specs-server.md](specs-server.md) section 6.3). Fetching the commit turns that
into a hard failure instead of a silent substitution, and any fallback path
throws the protection away.

If a client downloads a generated archive as an optimisation, the URL **MUST**
address the commit SHA, so the content is pinned by the URL itself, and the
archive's own hash **MUST NOT** be treated as authoritative. **GitHub's generated
source tarballs are not byte-stable** - their generation changed in 2023 and
invalidated recorded checksums across several ecosystems at once.

### 4.2 `kind: "tar.gz"` - verify the checksum

`checksum` is `sha256:` followed by 64 lowercase hex digits. A client **MUST**
verify it against the fetched bytes **before unpacking**, and **MUST** abort on a
mismatch. `ref` and `commit` are meaningless for this kind.

`url` **MAY** point anywhere the client can fetch over HTTPS. Clients **SHOULD**
also accept `file://` and local paths, which is what makes a private or
air-gapped registry usable.

### 4.3 An absent `kind`

An absent `kind` **MUST** be read as `"tar.gz"`, for records written before
`git` existed.

### 4.4 What to install

The fetched tree contains `deck.toml`, a `src/` directory, and optionally
`template/`. A client **MUST** install **only** `src/`, into
`vendor/<scope>/<deck>/`, and **MUST** verify that `src/<deck>.j` is present -
for `@acme/routeros`, `src/routeros.j`. `template/` is read at scaffold time and
is not vendored. Everything else is ignored.

### 4.5 Caching

Fetch rate limits land on the consumer, not on the registry: unauthenticated git
fetches are throttled per address, which a busy CI fleet will notice. A client
**SHOULD** cache fetched repositories locally, for example as a per-user bare
mirror.

## 5. Login

### 5.1 No password, no form of the registry's own

A client **MUST** authenticate through a delegated OAuth 2.0 flow, and the
registry's default is the GitHub **device authorization grant**, which needs no
web UI of the registry's own:

```
$ jvc login
open https://github.com/login/device and enter code  WXYZ-1234
logged in as @alice
```

The user approves in a browser they are already signed into, under whatever 2FA
GitHub already enforces. The registry never sees a password, sends no email, and
holds no credential worth stealing. This deletes the expensive half of a package
registry: signup, password reset, email verification, session cookies, CSRF, and
the admin screens to support them.

A client **MUST NOT** offer a username-and-password path, and **MUST NOT** ask
the user to paste a personal access token as the primary flow.

**GitHub is the default, not an assumption.** A private registry may delegate
identity to any OAuth 2.0 or OIDC provider, so a client **MUST** read
`auth.provider` and `auth.flow` from the discovery document rather than assuming
either ([specs-server.md](specs-server.md) section 12.2). Two flows are defined:

| `flow` | What the client does |
| ------ | -------------------- |
| `"device"` | poll the registry, as in 5.3; the client never contacts the provider |
| `"authcode"` | run authorization code with PKCE against `auth.authorizeUrl` using `auth.clientId` and `auth.scopes`, with a loopback redirect on `127.0.0.1`, then exchange the result at `tokenUrl` |

A client **MUST** treat an unrecognised `flow` as "this registry cannot be logged
into by this client", naming the flow it was offered, rather than guessing.

Under `"authcode"` the client does hold a provider token briefly. It **MUST** be
exchanged at `tokenUrl` immediately and **MUST NOT** be written to disk; the only
credential a client stores is the registry's own.

### 5.2 Where to send the exchange

**A client learns the endpoints from the discovery document, never by
hard-coding them.** The `auth` object
([specs-server.md](specs-server.md) section 4.1) carries `deviceUrl`,
`tokenUrl`, and optionally `refreshUrl`, as absolute paths used verbatim: they
are the one exception to prefixing requests with the negotiated `basePath`,
because they are given whole.

**An absent `auth` object means the registry accepts no logins.** A client
**MUST** say that plainly rather than guessing a path:

```
this registry does not accept logins (no `auth` in its discovery document).
```

That is not a hypothetical: a read-only registry, which is what the reference
implementation is today, omits it.

### 5.3 Running the flow

The registry drives the exchange against GitHub. **A client never talks to
GitHub, and never holds a GitHub token** - it holds only the registry's own.
That is what keeps a client free of per-registry configuration: the OAuth
application, its client id, and its scopes all belong to the registry.

1. `POST` to `deviceUrl` with no body. The response carries `userCode`,
   `verificationUri`, `deviceCode`, `expiresIn`, and `interval`.
2. Show the user `verificationUri` and `userCode`, and nothing else they have to
   understand.
3. Poll `tokenUrl` with `{"deviceCode": ...}`, waiting at least `interval`
   seconds between attempts. A client **MUST** honour `interval` and **MUST**
   back off further on a `429`.
4. Stop when the status says so, and report accordingly:

| Status | Do |
| ------ | -- |
| `200` | store the token; print `logged in as @<login>` |
| `202` | still pending; wait `interval` and poll again |
| `429` | polling too fast; back off, then continue |
| `403` | the user denied it; stop, and say so |
| `410` | the code expired; offer to start again |

A client **MUST** give up when `expiresIn` elapses rather than polling forever.

A registry **MAY** instead advertise `auth.clientId` and expect the client to run
the device flow against GitHub directly. A client **MAY** support that, but then
the GitHub token it receives **MUST** be exchanged at `tokenUrl` immediately and
**MUST NOT** be written to disk.

### 5.4 Sending the token

The registry issues its own short-lived token. A client **MUST** send it as:

```
Authorization: Bearer <token>
```

on every write request, and **MUST NOT** send it to any host other than the
registry it was issued for. It **SHOULD** store it with owner-only permissions.

Tokens are deliberately short-lived. On a `401`, a client **SHOULD** refresh
rather than fail: `POST` its stored `refreshToken` to `refreshUrl`, retry the
request once, and fall back to a full login only if the refresh is itself
rejected. A registry that rotates refresh tokens returns a new one each time, so
a client **MUST** store whatever it gets back.

`jvc logout` discards the local token. Revoking the GitHub grant revokes the
ability to obtain a new one.

### 5.5 Publishing from CI

A device grant needs a human at a browser, and the most common publish there is -
a pipeline releasing what its tests just proved - has none. A client **MUST**
therefore support publishing without an interactive login, and **SHOULD** prefer
the first mechanism below where the registry offers it.

`specs-server.md` section 8.8 is normative for both.

#### Trusted publishing (no secret)

When the registry advertises `auth.trustedPublishing` and the client is running
in a CI job whose system issues OIDC tokens, the client **SHOULD**:

1. read `auth.trustedPublishing.audience` from the discovery document;
2. ask the CI system for an identity token with **exactly that audience**;
3. send it to `auth.trustedPublishing.url` in place of a bearer token.

A client **MUST NOT** substitute an audience of its own, and **MUST NOT** send a
token minted for one registry to another - the audience is what stops a token
being replayed, and the client is the party that requests it.

On GitHub Actions this needs `permissions: id-token: write` on the job and a
request to `ACTIONS_ID_TOKEN_REQUEST_URL` with `ACTIONS_ID_TOKEN_REQUEST_TOKEN`.
The publishing workflow holds **no registry credential of any kind**:

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - run: jvc publish --tag ${{ github.ref_name }}
```

#### CI token (fallback)

Where the registry offers no trusted publishing, or the CI system issues no
identity token, a client **MUST** accept a bearer token from the environment -
conventionally `JVC_TOKEN` - and use it exactly as 5.4 describes.

A client **MUST NOT** write such a token to its config file, and **MUST NOT**
print it. It **SHOULD** say which mechanism it used when publishing, so an
operator reading a build log can see whether a standing secret was involved.

**Detection order.** A client **SHOULD** try trusted publishing first, then
`JVC_TOKEN`, then a stored interactive token, and **MUST NOT** open a browser
when no terminal is attached: failing with the reason is more useful in a
pipeline than a device code nobody will read.

### 5.6 The whole contract

Whatever the registry's internals: **the CLI discovers the auth endpoints from
the discovery document, obtains a token without any browser form of the
registry's own, and sends it as a bearer token on write requests.** In CI it
obtains that authority from the CI system itself where it can, and from an
environment variable where it cannot.

## 6. Deck names

Deck names are lowercase, and the registry folds on the way in
([specs-server.md](specs-server.md) section 2.1). A client **SHOULD** fold a name
before sending it, so that a manifest written as `@Acme/Tool` asks for
`@acme/tool` and the two never diverge locally.

A client **MUST** use the **folded** name when building the vendor path, since
`vendor/Acme/` and `vendor/acme/` are one directory on macOS and Windows and two
on Linux. Folding at the boundary is what keeps a lockfile meaning the same thing
on every platform.

The two halves differ: a **scope** may contain hyphens, a **deck** may not,
because the deck half becomes the bound Jennifer namespace.

## 7. Resolution

A client resolves locally, from each deck's `requires` table as recorded at that
version ([specs-server.md](specs-server.md) section 3). The constraint grammar it
must implement is [specs-server.md](specs-server.md) section 2.4.

Rules a resolution **MUST** satisfy:

- when several requirements constrain one deck, the chosen version satisfies all
  of them **simultaneously**, and is the **highest** published version that does;
- exactly one version of each deck appears in the result;
- a dependency cycle terminates rather than recursing;
- a prerelease version never satisfies a caret or tilde range;
- a **yanked** version **MUST NOT** be chosen during fresh resolution, but
  **MUST** still install when an existing lockfile pins it. That is the whole
  point of yanking rather than deleting.

A client **SHOULD** record the resolved set in a lockfile, including each deck's
`commit` (or `checksum`), so a later install reproduces the same code without
re-resolving.

### 7.1 Using the server's resolution instead

If the registry advertises `resolve` or `resolveGraph`, a client **MAY** use
them. It **MUST** still apply the fetch and verification rules in section 3 to
the result, and **MUST** be prepared for the features to be absent.

## 8. Engines and capabilities

A version record **MAY** declare `engines` and `capabilities`.

- **`engines`** is an **allowlist of alternatives**: the running interpreter must
  be a key, and its version must satisfy that key's constraint. An empty or
  absent table means no restriction. A client **SHOULD** check this at install
  time for the whole resolved graph, and record it so the check can be repeated
  at run time.
- **`capabilities`** is any of `net`, `exec`, `sql`. Empty means the deck is pure
  and runs on any interpreter build. The interpreter enforces these when it reads
  the code, so an inaccurate declaration surfaces as a runtime failure for the
  consumer; a client **SHOULD** surface the mismatch at install time instead,
  where it is actionable.

An absent `requires`, `engines`, or `capabilities` **MUST** be treated as empty,
never as an error.

## 9. Errors

A client **MUST** be able to distinguish these, because the remedies differ:

| Status | Means | Tell the user |
| ------ | ----- | ------------- |
| `400` | malformed request | a client bug, or a bad argument |
| `401` | missing or invalid credentials | log in again |
| `403` | authenticated, not permitted | you do not own that scope |
| `404` | no such deck or version | check the name and the constraint |
| `409` | the version already exists | publishes are immutable; bump the version |
| `422` | metadata failed validation | what failed, from the body |
| `429` | rate limited | back off and retry |

The body is `{"error": "<message>"}`, written for a developer in a terminal. A
client **SHOULD** show that message rather than inventing its own.

An unknown API version answers `400` with `{"error": ..., "apis": [1]}`, which a
client **SHOULD** distinguish from a missing deck (section 2).

## 10. Client conformance checklist

A client is conformant when:

- [ ] a scope resolves at exactly one registry, with no fallback search
- [ ] the lockfile records which registry each deck came from
- [ ] a lockfile whose registry disagrees with the current mapping fails, loudly
- [ ] it fetches the discovery document before its first API call
- [ ] it treats a `404` on the well-known path as API v1 at `/`
- [ ] it selects the highest mutually supported version, and uses its `basePath`
- [ ] it uses the first entry when a version is listed at several base paths
- [ ] an empty version intersection fails naming both sides' versions
- [ ] it ignores unrecognised fields and feature names
- [ ] it refuses an operation whose feature is not advertised, by name
- [ ] it resolves from `GET /deck?name=`, addressing scoped names as a query parameter
- [ ] a `kind: "git"` deck is fetched **at the commit**, never at the ref
- [ ] a `kind: "tar.gz"` deck's checksum is verified **before unpacking**
- [ ] an absent `kind` is treated as `"tar.gz"`
- [ ] a fetch that cannot produce the recorded commit fails, with no fallback
- [ ] names are folded to lowercase before requesting and before building `vendor/`
- [ ] only `src/` is vendored, and `src/<deck>.j` is verified present
- [ ] yanked versions are skipped when resolving, but install from a lockfile
- [ ] `engines` is enforced across the whole resolved graph
- [ ] the auth endpoints come from the discovery document, not from hard-coded paths
- [ ] an absent `auth` object is reported as "this registry accepts no logins"
- [ ] polling honours `interval`, backs off on `429`, and gives up at `expiresIn`
- [ ] the advertised `flow` is honoured, and an unknown one is refused by name
- [ ] a provider token, where one is held at all, is never written to disk
- [ ] the token is obtained by the advertised flow and sent as a bearer header
- [ ] a `401` triggers a refresh before a full re-login, when a refresh token is held
- [ ] publishing completes with no browser when running in CI (5.5)
- [ ] a CI identity token is requested with the advertised audience, never one
      the client chose
- [ ] `JVC_TOKEN` is honoured, never written to the config file, and never printed
- [ ] no browser or device code is offered when no terminal is attached
