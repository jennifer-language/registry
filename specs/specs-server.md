# The Jennifer deck registry: server specification

- **Version:** 0.3.0 (draft)
- **Date:** 2026-09-21
- **Companion:** [specs-client.md](specs-client.md), the client half

This is the contract a deck registry must fulfil. The key words **MUST**,
**SHOULD**, and **MAY** are used in the RFC 2119 sense.

> **Scope.** This document owns the **wire format and the server's obligations**:
> the naming grammar, the version record, the discovery document, the endpoints,
> and what the registry must verify at publish time. The obligations of a client
> consuming it - version negotiation, fetching and verifying code, and the login
> flow - are specified in [specs-client.md](specs-client.md), which is maintained by
> the jvc team. Where the client spec describes a payload, this document is
> normative for its shape.
>
> This document was split out of a single `registry-specs.md` on 2026-08-15, so
> that each project owns its own side.

Sections 1 to 6 describe behaviour a registry must implement to be usable at
all. Sections 7 to 11 describe the write and identity surface, which does not
exist yet and is where you have design latitude. Section 12 covers the identity
and forge interfaces, and the profile the public registry runs.

---

## 1. Vocabulary

| Term | Meaning |
| ---- | ------- |
| **deck** | a distributable, versioned bundle of Jennifer modules. Imported, never run. |
| **app** | a runnable Jennifer program. Installed onto PATH, not vendored. Out of scope for the registry. |
| **scope** | the `@vendor` half of a deck name; an ownership boundary |
| **version record** | everything the registry knows about one published version (section 3) |
| **yank** | mark a version unresolvable for new installs without deleting it (section 9) |
| **vendor tree** | the consumer-side `vendor/<scope>/<deck>/` directory a deck installs into |

## 2. Names, versions, and constraints

### 2.1 Deck names

A registry deck name is **scoped**: `@scope/deck`. The two halves have
**different grammars**, because they do different jobs.

```
scope = [a-z][a-z0-9-]{0,62}[a-z0-9]  |  [a-z]
deck  = [a-z][a-z0-9]{0,63}
```

- **`deck` is an identifier.** It becomes the namespace a consumer binds with
  `import "@scope/deck/"`, so it must be a legal Jennifer identifier: letters and
  digits only, letter-initial. No hyphens, no underscores.
- **`scope` is only ever a path segment**, in `vendor/<scope>/<deck>/`, so it
  **MAY** contain hyphens. It **MUST NOT** begin or end with one, and **MUST
  NOT** contain two in a row. This exists so that real account names, which
  commonly contain hyphens on every forge, can be expressed at all.
- Neither half exceeds 64 characters.
- The `@` and the single `/` are the only other characters permitted.
- Examples: `@jennifer/routeros`, `@acme/tool2`, `@jennifer-language/routeros`.

A **bare** name (no `@`, no `/`) is *not* a registry deck: it names a module
bundled with the interpreter or a local file. The registry **MUST** reject a bare
name on publish.

#### Names are lowercase

Both halves are lowercase, and a registry **MUST normalise by folding** rather
than merely rejecting: `@Netflix/Foo` is accepted and recorded as
`@netflix/foo`, and a lookup for either form finds the same deck.

Two reasons, and they compound:

- **`vendor/` lands on case-insensitive filesystems.** macOS and Windows treat
  `vendor/Netflix/` and `vendor/netflix/` as one directory, Linux as two. Without
  folding, a lockfile resolves differently per platform.
- **It removes impersonation structurally** rather than by a rule somebody has to
  remember to enforce. There is only one form, so there is nothing to refuse.

This grammar is the **maximum** a conforming client must handle. A deployment
**MAY** narrow it (12.6) and **MUST NOT** widen it, because a name outside it
produces records a conforming client cannot install.

Folding costs nothing where scopes are derived from account names, because the
providers are themselves case-insensitive for uniqueness while preserving the
registered casing. GitHub is: `Netflix` and `netflix` are one account, canonically
`Netflix`, so there is exactly one casing to fold.

#### Names reserved by the host filesystem

A registry **MUST** reject a scope or deck equal to a Windows reserved device
name, because `vendor/con/` cannot be created there:

```
con  prn  aux  nul  com1..com9  lpt1..lpt9
```

The comparison is against the folded name, so `CON` is rejected too.

### 2.2 Scope ownership

**A scope is owned by a principal, identified by the identity provider's stable
subject identifier** - a numeric account id on GitHub, a `sub` claim on an OIDC
provider - which is a user or, in a later version, an organisation. It is
**never** owned by whoever happened to claim it, and **never** bound to a login
string.

- A scope is a name **granted once, on proof of control**. It is not a live
  mirror of a GitHub name, and it does not track renames.
- Authorisation for every write under a scope asks one question: **may this
  caller currently act for the principal that owns this scope?**

A scope **MAY** additionally carry **co-owners**: further principals, under the
same provider, that may write under it. A co-owner is not a second holder of the
scope - the record still names the principal it was granted to, and reassigning
that is a different operation - so "who owns @acme" keeps one answer while "who
may publish under it" can have several.

Co-ownership is deliberately **not** self-service in this version. Adding one is
an operator action (8.2), which keeps the governance questions an owners list
otherwise raises - who may add, who may remove, whether the last owner can remove
themselves - out of the protocol until organisation scopes (8.7) answer them
properly. A registry **MUST NOT** let a co-owner be added to a scope with no
owner: a reserved name has nobody to co-own with, and accepting one would produce
a scope nobody holds that somebody can nevertheless write to.

That rule generalises to every **delegated** credential, and a registry **MUST
NOT** authorise a write under a scope with no owner by any of them - a
trusted-publisher binding (8.9), a CI token (8.10), or a bearer token. Each
answers to a different authority: the binding, the token record, and the scope
record respectively, and only the last of the three consults the scope at all. So
a registry that checks ownership only where a credential is *created* leaves
every credential created by another path, or created before the check existed,
unchecked. The check belongs at the write, where the credential is relied on.

Section 8 specifies how a scope is claimed and what "act for" means. The rest of
this document only needs the property: a scope resolves to one or more principal
ids, and those bindings do not change when names do.

### 2.3 Versions

A version is a **Semantic Versioning 2.0.0** string: `major.minor.patch` with
optional `-prerelease` and `+build`. The registry **MUST** reject anything else.

**No leading `v`.** `1.2.3` is a version; `v1.2.3` is not, and a registry
**MUST** reject it rather than stripping the prefix. This follows from SemVer
2.0.0, which excludes it, but it is stated here because it is the single most
likely thing to get wrong: **a git tag conventionally carries the prefix and a
version never may**, so both forms appear in one version record, one field
apart. `version` is `1.2.3`; `ref` is whatever the tag was called, commonly
`v1.2.3`. They answer different questions, and a registry **MUST NOT** store
either as a normalised form of the other.

That is a rule about **storage**, not about comparison. Publishing compares the
two deliberately (8.8 step 6), and that comparison **MUST** tolerate a single
optional leading `v` on the tag side, since otherwise no conventionally tagged
release could ever agree with its own manifest. What is forbidden is carrying
the tolerance any further: the version recorded, served, resolved, and written
into a lockfile is the manifest's, exactly as spelled.

The rejection applies wherever a version appears: in a constraint (2.4), in a
`deck.toml`, and in a path segment. Normalising the prefix away there would be
worse than refusing it, because it makes two spellings of one version and leaves
a client to guess which one a lockfile recorded.

### 2.4 Constraints

A constraint is a **single** expression. Compound ranges (`||`, `,`) are **not**
part of the grammar.

```
constraint = wildcard | exact | caret | tilde | comparator
wildcard   = "" | "*" | "any"
exact      = [ "=" ] version
caret      = "^" partial
tilde      = "~" partial
comparator = ( ">=" | ">" | "<=" | "<" ) version
partial    = num [ "." num [ "." num ] ]
```

| Form | Satisfied when |
| ---- | -------------- |
| `*` / `any` / `` | any published version |
| `=1.2.3` | exactly 1.2.3 |
| `^1.2.3` | `>=1.2.3 <2.0.0` |
| `^0.2.3` | `>=0.2.3 <0.3.0` (zero-aware) |
| `^0.0.3` | `>=0.0.3 <0.0.4` |
| `^1.2` / `^1` | `>=1.2.0 <2.0.0` / `>=1.0.0 <2.0.0` |
| `^0` | `>=0.0.0 <1.0.0` (zero-aware) |
| `^0.0` | `>=0.0.0 <0.1.0` (zero-aware) |
| `~1.2.3` / `~1.2` | `>=1.2.0 <1.3.0` |
| `~1` | `>=1.0.0 <2.0.0` |
| `>=1.0.0` etc. | the comparator holds |

A version string that is not valid SemVer satisfies nothing at all.

**A prerelease is opt-in, and the opt-in has to name it.** A version carrying a
prerelease component satisfies a constraint **only when the constraint's own
version carries a prerelease with the same `major.minor.patch`**. So
`>=0.2.0-dev` is satisfied by `0.2.0-rc.1` and by `0.2.0`, but not by
`0.3.0-alpha`; and `*`, `any`, and every comparator written without a
prerelease are satisfied by no prerelease at all. A caret or tilde range is
never satisfied by a prerelease, since its version is a partial and carries
none.

Because a constraint is a **single** expression here, with no compound ranges,
this needs no per-comparator bookkeeping: there is one version in the
constraint, and either it carries a prerelease on the candidate's core or it
does not.

**Ordering is unaffected and MUST NOT change.** `0.1.0 < 0.2.0-dev < 0.2.0` is
what SemVer section 11 requires and what comparison must keep doing. What
changes is that ordering stops doubling as a membership test: a prerelease that
does not satisfy the constraint is not a candidate, so it cannot be the highest
satisfying version. Without this, a deck tagged `0.2.0-dev` outranks the last
real release for every consumer who wrote `*` or `>=0.1.0`, silently.

**A registry MAY store prerelease versions**, and publishing one stays legal: a
beta is a normal version record that consumers reach by naming it. A registry
**SHOULD NOT** refuse one.

Where every published version of a deck is a prerelease, an unqualified
constraint is satisfied by none of them and resolution fails. A client
**SHOULD** report that case distinctly from an unknown deck, naming the newest
prerelease and the fact that a constraint must name it, because "no version
satisfies `*`" otherwise reads as "this deck does not exist".

Cargo and npm/node-semver both land here, so the rule a user brings from either
ecosystem is the rule they get.

**A partial is completed with zeros, and its ceiling comes from the form rather
than from how many components were written.** A caret permits changes that do
not touch the **leftmost non-zero** component, so `^1.2` and `^1` share a
ceiling of `2.0.0` while `^0` and `^0.0` narrow to `1.0.0` and `0.1.0`. A tilde
permits patch-level changes when a minor is written and minor-level changes when
only a major is, so `~1.2` stops at `1.3.0` but `~1` runs to `2.0.0`.

Spelling these out is not decoration: the grammar above admits `^1` and `~1`, so
a registry resolving server-side has to answer for them, and leaving the answer
to the reader is what lets two implementations disagree about what `^1` means.

**The registry is not the authority on resolution.** A client resolves the
dependency graph locally, from per-deck metadata (section 5.1). The server-side
resolution endpoints (5.3, 5.4) are a convenience for other clients and **MAY**
be omitted by a minimal implementation; 5.1 **MUST NOT** be.

### 2.5 Keywords

A version **MAY** carry keywords, which exist so a registry can group decks for
browsing. They are the only publisher-supplied field that becomes part of the
registry's own navigation, and a registry **MUST** treat them as untrusted for
exactly that reason.

A keyword is 2 to 32 characters of lowercase ASCII letters, digits, and single
inner hyphens, with no leading, trailing, or doubled hyphen. That grammar makes a
keyword usable as a URL path segment with no escaping.

A registry:

- **MUST** fold a keyword to lowercase before storing or comparing it, so one
  tag is one page;
- **MUST** ignore a keyword that does not match the grammar, rather than
  rejecting the manifest;
- **MAY** refuse individual keywords by local policy, and the reference
  implementation refuses a list of terms it will not build category pages for;
- **SHOULD** cap how many it indexes per version, dropping the excess in
  manifest order rather than rejecting the manifest. The reference implementation
  caps at **five**, and applies the cap **after** filtering, so a publisher
  cannot displace their own keywords by padding the list with refused ones.

**No keyword is ever a reason to reject a publish.** A malformed or refused
keyword costs the publisher that keyword. Failing a release over a tag would
trade a working publish for a cosmetic one.

Keywords are **per version**, and a registry presenting them **SHOULD** read them
from the newest version, so that a keyword dropped in a later release stops
grouping the deck.

## 3. The version record

Every published version has this shape. It is the core data model; the API
endpoints are projections of it.

| Field | Type | Required | Meaning |
| ----- | ---- | -------- | ------- |
| `version` | string | yes | the SemVer version (2.3), never `v`-prefixed, e.g. `1.0.0` |
| `kind` | string | yes | `"git"` for a repository-hosted deck, `"tar.gz"` for a hosted artifact |
| `url` | string | yes | the git clone URL (`kind: "git"`), or the artifact URL (`kind: "tar.gz"`) |
| `ref` | string | git only | the tag the version was published from, commonly `v`-prefixed, e.g. `v1.0.0`; never shaped like an object id (3.1) |
| `commit` | string | git only | the full 40-character commit SHA the tag pointed at **at publish time** |
| `repoId` | int | no | the host's immutable numeric repository id, recorded at publish (6.4) |
| `repoOwnerId` | int | no | the numeric id of the account that owned that repository at publish (6.4) |
| `checksum` | string | tar.gz only | `sha256:<lowercase hex>` of the artifact bytes |
| `requires` | object | no | this version's runtime dependencies, deck name -> constraint |
| `engines` | object | no | interpreters that can run it, engine name -> constraint |
| `capabilities` | array of string | no | host capabilities its code needs |
| `keywords` | array of string | no | the version's tags, normalised (2.5); absent reads as empty |
| `description` | string | no | one-line summary |
| `publishedAt` | string | no | publication time, Unix seconds as text |
| `yanked` | bool | no | see section 9; absent means false |

Notes that matter:

- **`requires` drives transitive resolution.** It is the deck's own dependency
  table *at that version*, captured at publish time. It is not recomputed later.
- **`engines`** names interpreters (`jennifer`, `jennifer-tiny`) mapped to
  version constraints. It is an **allowlist of alternatives**: the running engine
  must be a key, and its version must satisfy that key's constraint. An empty or
  absent table means no restriction.
- **`capabilities`** is any of `net`, `exec`, `sql`. Empty means the deck is pure
  and runs on any interpreter build. The interpreter enforces these at read time,
  so an inaccurate value produces a runtime failure for the consumer.
- An absent `requires` / `engines` / `capabilities` **MUST** be treated as empty,
  not as an error.
- An absent `kind` **MUST** be treated as `"tar.gz"`, for compatibility with
  records written before `git` existed.
- For `kind: "git"`, `commit` is the integrity pin and `checksum` is meaningless
  (see section 6). For `kind: "tar.gz"` it is the reverse. A registry **SHOULD**
  serve the unused pin as an empty string rather than omitting it, so a reader
  never has to distinguish "absent" from "not applicable".

### 3.1 `ref` MUST NOT be shaped like an object id

A registry **MUST** refuse a publish whose `ref` is **7 to 64 hex digits in
either case**, and **MUST NOT** store one. That is the shape of a git object id,
abbreviated or whole, and a ref of that shape is ambiguous with the object it
names.

The consequence is the client's, which is why the registry is the one that has
to refuse it: a ref and an object id share one syntactic space, and wherever a
name is resolved before an object - `git fetch <remote> <name>` against the
advertised refs, or a `?ref=` parameter on a forge API, which resolves a name
before an object by definition - a ref called `4a3b1c...` answers in place of the
commit of that id. The fetch then verifies an object hash, correctly, and the
object is not the pin. GitHub refuses such names at creation; GitLab, Gitea,
Forgejo, Bitbucket and self-hosted servers do not.

Seven digits is git's shortest abbreviation, so a shorter name cannot be read as
an id; 64 is the longest object id there is. The rule costs a publisher one tag
rename in the case where it fires at all, since a real tag is `v1.2.0`.

A registry **SHOULD** additionally refuse a publish when the source repository
holds a **branch or tag named exactly like the resolved commit**, because a
registry that reads the manifest at the commit (section 7) through a ref-or-sha
parameter has read it from that ref instead, and the record it is about to write
describes a tree that is not at `commit`. This is a **SHOULD** rather than a
**MUST** because the repository stays mutable after publication: the check
removes the registry's own exposure and narrows the client's, and only the
client's own verification closes it
([specs-client.md](specs-client.md) section 4.1.1).

### 3.2 The pin is the identity; the URL is a coordinate

**`commit` identifies the code. `url` only says where a copy was last seen.**

That distinction is load-bearing, and it has a consequence worth stating
plainly, because "a published version is immutable" (section 9) invites the
opposite reading:

> A registry **MAY** correct `url` on a published version when the upstream
> repository moves, and doing so is **not** a mutation of the version. The
> content it names is unchanged, and provably so: whatever the URL, the client
> fetches `commit` and git verifies the hash.

The same latitude is already assumed by section 6.6, which contemplates a
registry serving a fallback copy from a different URL while `commit` stays the
identity. Everything else about a published version is frozen.

## 4. Versioning and discovery

A client **MUST** be able to determine, before it does anything else, which API
version a registry speaks and which optional operations it offers. Discovering
that by trying a call and reading a `404` is not acceptable: a missing endpoint
and an unsupported protocol version are different problems with different
remedies, and a user deserves to be told which one they have.

### 4.1 The discovery document

A registry **MUST** serve a discovery document at the fixed, unversioned path:

```
GET /.well-known/jennifer-registry
```

This path never changes; it is the one thing a client may hard-code.

```json
{
  "registry": "decks.jennifer-lang.org",
  "url": "https://decks.jennifer-lang.org",
  "spec": "0.1.0",
  "apis": [
    { "version": 1, "basePath": "/v1", "deprecated": false },
    { "version": 1, "basePath": "/", "deprecated": false }
  ],
  "features": ["deck", "decks", "resolve", "resolveGraph", "health", "auth"],
  "auth": {
    "provider": "github",
    "flow": "device",
    "deviceUrl": "/v1/auth/device",
    "tokenUrl": "/v1/auth/token",
    "refreshUrl": "/v1/auth/refresh"
  }
}
```

| Field | Meaning |
| ----- | ------- |
| `registry` | a human-readable identifier, shown in client messages |
| `url` | optional; the registry's own canonical base URL, no trailing slash |
| `spec` | the version of **this document** the registry implements |
| `apis` | every API version served, each with a base path to use |
| `apis[].version` | an integer major version |
| `apis[].basePath` | a base path all that version's endpoints hang off |
| `apis[].deprecated` | whether that mount is deprecated |
| `apis[].sunset` | optional ISO 8601 date after which it stops working; present only when deprecated |
| `features` | the optional operations this registry actually offers (4.4) |
| `auth` | how to authenticate for writes; **absent when the registry accepts none** |
| `auth.provider` | the identity provider: `"github"`, or a name the deployment chooses (12.2) |
| `auth.flow` | `"device"` or `"authcode"` (12.2); a client **MUST** refuse a flow it does not know |
| `auth.authorizeUrl` | `authcode` only; the provider's authorization endpoint |
| `auth.scopes` | `authcode` only; the scopes the client must request |
| `auth.deviceUrl` | where to begin a device authorization (8.4) |
| `auth.tokenUrl` | where to exchange an approved device code for a token (8.4) |
| `auth.refreshUrl` | optional; where to exchange a refresh token (8.4) |
| `auth.clientId` | present **only** when the client runs the flow against the provider itself: required for `authcode`, optional for `device` (8.4, 12.2) |
| `auth.trustedPublishing` | optional; present when the registry accepts CI identity tokens (8.9) |
| `auth.trustedPublishing.audience` | the `aud` a CI job **MUST** request; a registry rejects any other (8.9) |
| `auth.trustedPublishing.providers` | the issuers accepted, e.g. `["github-actions"]` |
| `auth.trustedPublishing.url` | where to present the token |

**The `auth` object is optional, and its absence is meaningful.** A read-only
registry omits it, and a client **MUST** read that as "this registry does not
accept logins" and say so, rather than guessing an endpoint. A registry that
does accept writes **MUST** advertise `deviceUrl` and `tokenUrl`: without them a
client has nowhere to send the exchange and no way to learn the OAuth client id,
which differs per registry.

**`url` is what the registry calls itself.** A registry **SHOULD** advertise it,
and **MUST** omit it rather than guess: a registry sees a listen address and a
`Host` header, and behind a proxy, in a container, or on a private network
neither is its public name. An absent `url` means the deployment has not declared
one, which is a better answer than a wrong one - this string ends up recorded in
lockfiles as this registry's identity.

It **MUST** be an absolute base URL with no trailing slash, so that one registry
has one spelling. Clients **SHOULD** use it when recording which registry a deck
came from (`specs-client.md` section 2.3), and **SHOULD** prefer it to whatever
address they happened to dial.

A `url` that differs from the address the client used is **not** an error, and a
client **MUST NOT** refuse the registry over it. A mirror, an internal name, and
a public name are all legitimate ways to reach one registry. A client **MAY**
say so once, because the same difference is also what a misdirected client looks
like, and the person running it is the one who can tell those apart.

**A CI job cannot guess the audience.** A registry accepting 8.9 tokens **MUST**
advertise `auth.trustedPublishing.audience`, because the job has to name it when
minting the token and the registry rejects every other value. Publishing it is
what makes the audience check enforceable rather than a shared secret by another
name; it is not confidential, and its purpose is to stop a token minted for one
registry being replayed at another.

**The auth URLs are absolute paths, used verbatim.** They are the one exception
to 4.2's rule about prefixing requests with a version's `basePath`, because they
are given whole. A registry serving them under a version simply advertises
`/v1/auth/device`.

**A version MAY appear more than once**, when it is served at several base
paths. The registry **MUST** list the canonical path first, and a client
**SHOULD** use the first entry for the version it selects. This is what lets a
v1 registry advertise both `/v1` and the bare root (4.3).

> **Implementation note, not normative.** This shape is what the bundled
> `webapi` module's `webapi.discovery` emits, deriving `apis` and `features`
> from the router's own table so the document cannot claim an operation that is
> not served. `auth` is the one member a registry adds itself, which is exactly
> why it must be added only when the endpoints behind it exist. Earlier drafts of
> this document specified `specVersion` / `api[]` / `path` / `status`; those
> names are retired.

### 4.2 Version negotiation

- API versions are **integer majors**. A version is bumped only for a
  **breaking** change: removing a field or endpoint, renaming one, or changing
  the meaning of an existing value.
- **Additive changes do not bump it.** A new optional field, or a new entry in
  `features`, is not breaking, which is why clients **MUST** ignore fields they
  do not recognise.

`spec` and `apis[].version` answer different questions and move independently.
`apis[].version` is the wire contract a client negotiates against. `spec` names
the revision of *this document*, which can be reshaped - a section rewritten, a
rule made explicit - without any endpoint changing, and a client **MUST NOT**
refuse a registry on the strength of `spec` alone.

`spec` is a full **SemVer 2.0.0** string. Until the reference implementation is
tagged `1.0.0` it stays **below** `1.0.0`, and a leading zero carries its usual
SemVer meaning: anything here may still change, including in ways that break a
client. **A `0.y.z` specification is not a stable target to build against.**

At the first stable release the two are tagged together at `1.0.0` and stay in
step from then on, so "which revision of the specification does this registry
implement" has exactly one answer. Before that point a client that needs to
distinguish revisions **SHOULD** compare `spec` as a SemVer string rather than
matching it exactly.

**The API major does not reset with it, and there is no `v0`.** `apis[].version`
is an integer that appears in a URL, not a SemVer field, so a leading zero would
carry none of the meaning it carries in `spec`; and 4.3 makes v1 the floor a
registry *without* a discovery document is assumed to speak, which a `v0` above
it would contradict. The first wire contract is `v1` and stays `v1`.

What that costs, stated plainly: **while `spec` is below `1.0.0`, v1 may change
in a breaking way without the major bumping.** The permission to break comes from
the `0.y` specification, and it is spent on the wire format as much as on the
prose. A client written against a pre-1.0 registry **SHOULD** pin the `spec` it
was tested against and treat a minor bump as a reason to re-read this document.
From `1.0.0` the integer-major rule above takes full effect and a breaking change
means `v2`, served alongside `v1` for as long as 4.5's deprecation allows.

The client's obligations on reading this document - intersecting versions,
choosing the highest, and failing usefully when the intersection is empty - are
specified in [specs-client.md](specs-client.md) section 3.

### 4.3 Registries without a discovery document

A registry that returns `404` for the well-known path **MUST** be treated as
**API v1 rooted at `/`**. This keeps the prototype registries that predate this
section working, and lets a private registry stay minimal. New registries
**SHOULD** serve the document.

For the same reason, a v1 registry **MAY** serve its endpoints at both `/v1/...`
and bare `/...`. The versioned path is canonical, and **MUST** be listed first
in `apis` when both are advertised.

### 4.4 Feature names

`features` names the optional operations a registry actually implements, so a
client can refuse an operation up front with a clear message instead of
provoking a `404`.

**A feature names a route, not a way of authorising one.** The non-interactive
mechanisms of 8.8 are all reached through `POST /publish`, so none of them adds a
feature name; whether 8.9 is available is advertised by the presence of
`auth.trustedPublishing`, and a CI token (8.10) needs no advertisement at all
because it is presented rather than discovered. Keeping features one-to-one with
routes is what lets a registry derive this list from its router instead of
maintaining it by hand.

| Feature | Endpoint | Required |
| ------- | -------- | -------- |
| `deck` | `GET /deck?name=` (5.1) | **yes** |
| `decks` | `GET /decks`, `GET /decks/:name`, `GET /decks/:name/:version` | no |
| `resolve` | `GET /resolve` | no |
| `resolveGraph` | `GET /resolve-graph` | no |
| `search` | `GET /search` (5.5) | no |
| `health` | `GET /health` | no |
| `auth` | `POST /auth/device`, `POST /auth/token` (8.4) | no |
| `publish` | `POST /publish` | no |
| `yank` | `POST /yank`, `POST /unyank` | no |
| `owners` | `POST /owners` | no |

A registry **MUST** list `deck`. Feature names are a set: several routes **MAY**
share one label, and it is listed once.

### 4.5 Rejecting an unknown version

If a client requests a path under a version the registry does not serve, the
registry **SHOULD** answer `400` with the supported versions in the body, rather
than a bare `404` that is indistinguishable from a missing deck:

```json
{ "error": "unsupported API version", "apis": [1] }
```

## 5. Read API

All responses are JSON with `Content-Type: application/json`.

### 5.1 `GET /deck?name=<deck>` (required)

Returns one deck's whole record. **This is the endpoint a client's resolver
depends on**; everything else is optional.

> **The name MUST be a query parameter, not a path segment.** A scoped name
> contains a `/`, and percent-encoding does not save you: most routers decode
> `%2F` before matching, so `GET /decks/%40acme%2Ftool` matches a
> two-segment route and resolves to the wrong thing. This is the single most
> common way to get this API wrong. A path route **MAY** additionally be offered
> for bare names, but the query form is the contract.

Response `200`:

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
    },
    "0.2.0": { "...": "..." }
  }
}
```

The deck record itself carries `name`, `description`, `versions`, and optionally
`successor` (5.1.1).

- The `versions` object is keyed by version string.
- An unknown deck is `404` with `{"error": "..."}`.
- A missing `name` parameter is `400`.
- The response **SHOULD** include yanked versions, each flagged (section 9).

#### 5.1.1 `successor`, and why it does not resolve

A deck record **MAY** carry `successor`, the name of a deck that continues it:

```json
{ "name": "@old/foo", "successor": "@new/foo", "versions": { "...": "..." } }
```

It exists for the rebrand case. An author who renames keeps `@old/foo` working
and publishes onward as `@new/foo`; without a field for it, the only way to say
so is prose in a description, and no tool can see it.

**It is advisory, and resolution MUST NOT follow it.** A constraint on
`@old/foo` resolves within `@old/foo` and nowhere else. A client **MAY** show it
("this deck continues as `@new/foo`") and **MUST NOT** substitute it.

That restriction is the whole point. An alias that resolution honoured would:

- make a **published name mutable**, when name-to-deck is the one mapping that
  has to stay fixed for a lockfile to mean anything;
- **double-install**, because `@old/foo` and `@new/foo` vendor to
  `vendor/old/foo` and `vendor/new/foo`, so a graph reaching both gets two copies
  of one deck and silently breaks the resolver's "exactly one version of each
  deck" invariant (5.4);
- become a permanent compatibility obligation, which is why neither npm nor
  crates.io has one.

Setting `successor` **MUST NOT** stop `@old/foo` resolving, and **MUST NOT**
prevent further publishing under it. Both decks are ordinary decks; the field
only records the relationship.

### 5.2 `GET /decks`

```json
{ "decks": ["@acme/routeros", "@acme/net"] }
```

Every deck name. A large registry **SHOULD** paginate; define the scheme when
you need it.

### 5.3 `GET /resolve?name=<deck>&constraint=<range>` (optional)

Best published version satisfying the constraint. An empty `constraint` means
`*`.

Response `200`:

```json
{
  "found": true,
  "name": "@acme/routeros",
  "version": "0.2.0",
  "kind": "git",
  "url": "https://github.com/acme/deck-routeros.git",
  "ref": "v0.2.0",
  "commit": "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
  "checksum": "",
  "description": "..."
}
```

The response **MUST** carry the pin for its `kind`, so a client can fetch from
this endpoint alone.

Nothing satisfying is `404` with `{"found": false, "name": ..., "error": ...}`.
A missing `name` is `400`.

### 5.4 `GET /resolve-graph?roots=<json>` (optional)

`roots` is a URL-encoded JSON object of deck name to constraint. Returns the
whole dependency graph, flattened and version-locked.

Response `200`:

```json
{
  "ok": true,
  "resolved": [
    {
      "name": "@acme/routeros",
      "version": "0.2.0",
      "kind": "git",
      "url": "https://github.com/acme/deck-routeros.git",
      "ref": "v0.2.0",
      "commit": "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
      "checksum": "",
      "engines": { "jennifer": ">=0.24.0" },
      "capabilities": ["net"],
      "description": "..."
    }
  ]
}
```

An unsatisfiable graph is `200` with `{"ok": false, "error": "..."}` (the request
was well-formed; the graph was not). Malformed `roots` is `400`.

Resolution rules, if implemented: when several requirements constrain one deck,
the chosen version **MUST** satisfy all of them simultaneously, and **MUST** be
the highest published version that does. Exactly one version of each deck appears
in the result. A dependency cycle **MUST** terminate rather than recurse.

### 5.5 `GET /search?q=<query>` (optional)

Decks whose name or description matches `q`, best first. An **empty query
returns every deck**, so this is also the machine-readable deck listing.

Response `200`:

```json
{
  "query": "router",
  "count": 1,
  "results": [
    {
      "name": "@acme/routeros",
      "description": "MikroTik RouterOS client",
      "latest": "0.2.0",
      "versions": 2
    }
  ]
}
```

- `latest` is the highest published version by SemVer precedence, `""` when the
  deck has none.
- Matching **SHOULD** be case-insensitive, and **SHOULD** rank name matches
  above description-only matches. The exact algorithm is not specified: a client
  displays the order it is given and **MUST NOT** depend on a particular one.
- No match is `200` with an empty `results`, never a `404`: the query was
  well-formed, nothing matched it.

A registry serving a website **MAY** answer this path with HTML when the
request's `Accept` header prefers it, and **MUST** still answer JSON otherwise.
The two **MUST** be the same result set.

### 5.6 `GET /health` and `GET /`

`/health` returns `{"status": "ok"}`. `/` returns service identity and the routes
offered. Both are conveniences; neither is depended on.

### 5.7 Errors

| Status | When |
| ------ | ---- |
| `400` | malformed or missing parameters |
| `401` | missing or invalid credentials on a write |
| `403` | authenticated, but not permitted (wrong scope owner) |
| `404` | no such deck or version |
| `409` | the version already exists (section 7) |
| `422` | the artifact or metadata failed validation |
| `429` | rate limited |

Every error body **SHOULD** be `{"error": "<human-readable message>"}`. The
message is shown directly to a developer in a terminal, so write it for that
reader.

## 6. Delivery and integrity

**The registry indexes; it does not host.** A deck's code stays in its GitHub
repository, and the client fetches it from there. The registry stores metadata
and the coordinates that identify exactly which code a version is.

The client's side of this - fetching at the commit, verifying a checksum before
unpacking - is [specs-client.md](specs-client.md) section 4. What follows is what the
registry records and why.

### 6.1 What a deck's tree must contain

However it is fetched, the deck's tree **MUST** contain:

- a `src/` directory; only that subtree is installed into the consumer's vendor
  tree;
- `src/<deck>.j`, the entry module. For `@acme/routeros` that is
  `src/routeros.j`;
- `deck.toml`, the manifest the registry reads its metadata from (section 7).

A `template/` directory, when present, is read by the client at scaffold time and
is also not vendored. Everything else is ignored.

### 6.2 Why the pin is a commit

For `kind: "git"` the registry **MUST** record the full 40-character commit SHA
the tag resolved to at publish time, and **MUST** serve it.

- **A tag is a mutable pointer.** `v1.0.0` can be force-pushed to a different
  commit after publication. Handing out the tag would let an author change what a
  published version means. The `ref` is retained for display and provenance only.
- **A commit SHA is a content hash.** Fetching over git gives integrity for
  free: git verifies object hashes on receipt, so a commit that arrives is the
  commit that was published. No separate checksum is needed, and none is
  recorded.

**Do not use GitHub's generated source tarballs as the integrity boundary.**
`https://github.com/OWNER/REPO/archive/refs/tags/v1.0.0.tar.gz` is generated on
demand, and its bytes are **not stable over time**: GitHub changed its archive
generation in 2023 and invalidated recorded checksums across several ecosystems
at once. A `sha256` over such an archive is a pin that can stop matching without
anybody changing anything.

### 6.3 The URL is mutable too, which is the harder case

A tag moving is the obvious hazard. The **whole URL** moving is the one that
catches people, and it follows from how GitHub handles renames:

- a released username becomes claimable by anyone **immediately**, with no grace
  period;
- repository URLs under the old name **redirect** to the new one, including git
  operations, and the redirect persists indefinitely;
- but *"if the new owner of your old username creates a repository with the same
  name as your repository, that will override the redirect entry and your
  redirect will stop working."*

So a stored `url` of `https://github.com/old/deck-foo.git` can come to name a
**different party's repository**, with no action by the registry or the author.

#### The worked attack

1. Alice publishes `@old/foo@1.0.0` from `github.com/old/deck-foo`, commit `X`.
2. Mallory clones that repository, obtaining every object including `X`.
3. Alice renames to `new`. GitHub frees `old` at once.
4. Mallory registers the login `old` and creates `old/deck-foo`, pushing the
   clone. The redirect is now overridden, and `X` is present.

The registry's stored `url` **and** `commit` now both resolve, against a
repository Mallory controls.

**What still holds.** Commit `X` is a hash over the commit object, which carries
the tree hash. Mallory cannot make `X` mean different code. A client fetching `X`
receives exactly what Alice published, and git verifies it on receipt. Integrity
survives.

**What does not.** Mallory gains availability (delete the repository, or make `X`
unreachable, and every install of that version fails) and provenance (the URL on
the deck page, the README, the issues, all now theirs, with no signal to anyone
evaluating the deck).

**Where it would have become a compromise.** Only if Mallory could also publish a
*new* version under `@old`. That needs authority over the scope, and section 2.2
denies it: `@old` is bound to Alice's numeric account id, and Mallory's newly
registered `old` is a different id. Had scope ownership been derived from the
login at publish time, Mallory would have been handed `@old` and could have
published `@old/foo@1.0.1` pointing anywhere, taking over every consumer on
`^1.0.0`. **That is the reason for binding to the id, and it is why this walk
through is in the specification rather than in a commit message.**

#### The residual integrity caveat

Git commit ids are SHA-1, for which chosen-prefix collisions are demonstrated.
GitHub applies collision detection and rejects known-technique attempts, and
producing a colliding *and useful* tree is harder again, so this is not a
practical concern today. It is stated because controlling the repository is
exactly the position such an attack would be mounted from. Git's migration to
SHA-256 is the durable answer.

### 6.4 Detecting a repository that changed hands

Because of 6.3, a registry **SHOULD** record `repoId` and `repoOwnerId`
(section 3) at publish time. Both are immutable numeric ids that survive renames
and transfers, exactly as an account id does, so a later reclaim becomes
**detectable rather than invisible**: resolve `repoId` against the host and
compare the current owner to `repoOwnerId`.

A registry **SHOULD** then:

- warn, or refuse to serve the record, when the owning account has changed;
- surface the discrepancy on the deck page, since that is the signal a human
  evaluating the deck otherwise has no way to see.

This extends the warning section 7 already permits for a tag that no longer
points at the recorded commit. Neither check is required for a minimal
implementation, and neither affects integrity; both address provenance.

#### `repoId` is provenance, not identity

**A registry MUST NOT treat `repoId` as a uniqueness key.** One repository may
legitimately back decks under more than one scope, and the obvious case is a
rebrand: an author who renames from `old` to `new` keeps `@old/foo` working
(section 8.3) and wants `@new/foo` published from the same repository. The
repository id is unchanged by a rename, so a uniqueness constraint added
defensively would block exactly the flow the rename rules are designed to
support.

The same holds for a repository that hosts a deck published under both a
personal scope and an operator-granted vanity scope.

`repoId` answers "has this repository changed hands since publication", nothing
else.

### 6.5 Hosted artifacts remain valid

`kind: "tar.gz"` stays supported for a deck published as an uploaded artifact -
a GitHub release asset, or any other URL. Those bytes are stable because somebody
uploaded them rather than a service generating them, so `checksum` **MUST** be
present and well-formed (`sha256:` followed by 64 lowercase hex digits).

`url` **MAY** point anywhere the client can fetch over HTTPS.

### 6.6 What not mirroring costs

Stated plainly, so nobody is surprised:

- **A deleted repository or a deleted tag makes a version uninstallable.** The
  recorded commit still identifies the code, so any fork or clone that retains
  the object can serve it, but the registry itself cannot. This is the
  "left-pad" exposure, accepted deliberately.
- **The registry's availability no longer implies installability.** A GitHub
  outage stops installs even when the registry is healthy.
- **Rate limits apply to the consumer, not the registry.** Unauthenticated git
  fetches are throttled per address, which a busy CI fleet will notice. The
  registry **SHOULD** document this rather than let users discover it under load.
- **The registry validates at publish time only.** It verifies the tree once,
  when the version is published. It cannot attest to what the origin serves
  later, beyond the commit SHA that identifies it.

A registry **MAY** later keep a fallback copy of published trees without becoming
the primary host. That is an operational decision, not a protocol change: the
`url` would simply point elsewhere while `commit` stays the identity.

## 7. Write API

| Route | Does |
| ----- | ---- |
| `POST /publish` | publish a version from a repository and a tag |
| `POST /yank` | mark a version yanked |
| `POST /unyank` | reverse it |
| `POST /claim` | claim a scope for the authenticated caller (8.2) |
| `POST /owners` | add or remove a co-owner of a scope |
| `GET /scopes` | list registered scopes and who holds them |

`GET /scopes` is the only one of these that needs no caller. It reports each
scope's name, kind, and whether it is owned or reserved, and for an owned one the
owner's **login** - not the subject id. The login is already visible on every
deck page; the id is what authorisation binds to, and a public list of them is a
list of exactly what an impersonator would need.

A refused claim **SHOULD** distinguish its cause by status: `400` for a name
outside the grammar, `409` for one already held or reserved, `403` for a policy
that declines. Answering `403` to all three tells a caller their credentials are
wrong when the real answer is a typo or a taken name.

A publish names a **repository and a tag**, not an uploaded file. The registry
does the resolving:

`POST /publish` **MUST**:

1. authenticate the caller (section 8);
2. **resolve the tag to a commit SHA**, and record the SHA. The tag is retained
   for display; the commit is the identity (6.2);
3. read `deck.toml` **at that commit** and take the deck name, version,
   `requires`, `engines`, and `capabilities` from it;
4. verify the caller has **name authority** over the scope in *that* name, and
   **source authority** over the repository (7.1);
5. reject a name that is not scoped, or a version that is not SemVer;
6. reject a version whose `deck.toml` version disagrees with the tag - a tag
   `v1.0.0` whose manifest says `0.9.0` is a mislabelled release, not a
   publishable one. A single leading `v` on the tag is ignored for this
   comparison and nowhere else (2.3), so `v1.0.0` and `1.0.0` both agree with a
   manifest saying `1.0.0`;
7. reject a version that already exists (`409`) - **publishes are immutable**;
8. verify the tree contains `src/` and `src/<deck>.j` (6.1).

Point 3 matters: metadata that can be asserted independently of the code will
eventually disagree with it. Read it from the commit, never from the request
body.

**The order is normative.** The manifest is read *before* authorisation, because
the name being authorised is the one in the manifest, not one the caller
supplied. A caller cannot rename a deck at publish time, and cannot publish a
repository into a scope its manifest does not name.

### 7.1 Two authorisations, not one

Publishing binds a **name** to a **source**, and those are separate rights that
earlier drafts of this document collapsed into a single line.

| | Question | Answered by |
| --- | --- | --- |
| **Name authority** | may you publish under this scope? | the scope's principal id (8.1), locally |
| **Source authority** | may you publish *this repository* as a deck? | the host, at publish time |

Name authority alone is not enough, and the gap it leaves is concrete: the owner
of `@acme` could publish a version of `@acme/spinner` sourced from
`example.test/dana/spinner`, a repository they have no rights to, purely because
that repository's manifest happens to name `@acme/spinner`. Everything in the
list above would pass.

That is bad in three ways, and the third is the one that bites the publisher:

- **Provenance.** Consumers see a deck under `@acme` and extend it that trust,
  while the code is written by somebody else entirely.
- **Availability.** The deck's source can be deleted or made private by a party
  who never agreed to maintain it.
- **Takeover.** If the third-party repository later changes hands, its manifest
  can keep naming `@acme/spinner` while the code becomes something else, and the
  next tag published from it inherits `@acme`'s reputation.

A registry **MUST** establish source authority by one of the two routes below,
and **MUST NOT** treat it as granted by default.

#### Route A: ask the forge

Query the caller's permission on the repository. **`push` is the requirement, not
ownership**: push accepts a repository owned by an organisation the caller can
write to, which an ownership comparison would wrongly reject. On GitHub,
`GET /repos/{owner}/{repo}` returns a `permissions` object for the authenticated
user; 12.3 gives the equivalent for the other supported forges.

This route needs a forge with a permissions API, and a credential that forge
accepts. Neither holds universally: the caller may have authenticated with an
identity provider the forge does not know (12.5), or the code may live somewhere
with no API at all.

#### Route B: require a signed tag

A scope **MAY** record one or more **verification public keys**. Where it does,
a registry **MAY** require that the published tag carry a git signature by one of
them, and accept that as source authority on its own.

This route asks the forge for nothing. Verifying a signature needs only the
ability to **read** the repository, which the registry already does to fetch
`deck.toml`, so it works on a forge with no permissions API, on a self-hosted
instance the registry holds no token for, on a mirror, and on a `file://` URL.
Git has carried the machinery for years: GPG signatures, and SSH signatures since
git 2.34.

It is also **strictly stronger than route A**. Push permission proves the caller
can write to the repository *now*; a signature proves the scope owner authorised
*this exact commit*. A registry that requires signatures is unaffected by a
repository later changing hands (6.3), because a new owner cannot produce a
signature over a new commit.

How a key is registered is a write-API concern, alongside `POST /owners`.

#### Route C: accept the forge's own attestation

Where a publish is performed by a CI job on the forge, the forge **itself** can
assert which repository the job ran in, as a signed OIDC token (8.9). A registry
**MAY** accept a verified token's repository claim as source authority.

This is the strongest of the three and the cheapest to check. Route A asks a
third party a question about the caller and believes the answer; route B verifies
an artifact the caller produced. Route C is the **issuer** stating, under its own
signature, that a build ran in a named repository at a named ref - not a claim
the caller makes about itself, and not one the caller can forge without
compromising the forge.

It answers both halves of this section at once. `repository_id` in the token is
exactly the `repoId` 7.3 wants recorded, obtained from the party that assigns it,
so provenance costs no extra call.

Its limit is its precondition: it exists only when the publish comes from a CI
job on a forge that issues these tokens. A publish from a laptop still needs
route A or B.

#### When neither route is available

A registry **MUST NOT** silently treat source authority as granted. It **MUST**
either refuse the publish, or record the source as unverified and surface that
wherever the deck is shown. Which of the two is policy (12.6): a public registry
should refuse, and a private one whose users are already trusted may reasonably
record and display instead.

**Decks are published from public repositories.** A private repository cannot be
fetched by consumers, so this is not a restriction, and stating it resolves what
the registry needs to read (7.2).

### 7.2 What the registry reads, and with what rights

Publishing reads two things from the host: the repository's `deck.toml` at a
commit, and the caller's permissions on that repository. Because decks are
public, neither needs the OAuth `repo` scope: public contents are readable
without authentication, and the `permissions` object is returned for a public
repository to any authenticated user.

> **To confirm before implementing.** That the `permissions` field is populated
> for a public repository without `repo` scope is asserted here from the API's
> documented shape and has not been verified against a live token. Check it
> before relying on 8.6's scope list.

### 7.3 Recording the source

A registry **SHOULD** record `repoId` and `repoOwnerId` (section 3) at publish,
and **SHOULD** surface the owning account wherever the deck is shown. Even with
source authority verified, the repository owner and the scope owner are
frequently different accounts - an organisation repository published under a
personal scope, for instance - and a reader evaluating a deck has no other way to
see whose code it actually is.

Point 3 is what makes a moved tag harmless. Once published, moving `v1.0.0` in
the repository changes nothing for consumers: the registry hands out the commit
it resolved at publish time. It **MAY** additionally warn when a tag no longer
points at the recorded commit, since that usually means somebody rewrote history
by mistake.

An example request body:

```json
{
  "repository": "https://github.com/acme/deck-routeros",
  "tag": "v0.1.0"
}
```

and the record it produces is in the appendix.

## 8. Identity and authorization

**Identity is delegated. The registry MUST NOT issue passwords and MUST NOT
maintain its own account system.** That deletes the expensive half of a package
registry: signup, password reset, email verification, sessions, and the screens
to administer them.

**This section is written against GitHub**, because that is what the public
registry configures (12.7). GitHub is a *profile*, not the protocol: section 12
gives the interface any identity provider must satisfy, and what changes when
identity and source hosting are different services.

The login flow as the user experiences it is [specs-client.md](specs-client.md)
section 5. What follows is what the server is responsible for.

### 8.1 Ownership binds to a principal id, not to a login

**A scope MUST be bound to the identity provider's stable subject identifier,
never to a login string.** On GitHub that is the numeric account id; on an OIDC
provider it is the `sub` claim, which is opaque and need not be a number. A
registry storing it **SHOULD** treat it as an opaque string and **MUST** record
which provider issued it, since a subject is only unique within its issuer.

Logins are mutable. A GitHub login released by a rename or a deletion becomes
claimable by anyone **immediately**, with no grace period, so binding to one
hands an attacker who registers a freed username the right to publish under an
established scope. Section 6.3 walks that attack end to end; it is the
justification for this rule and worth reading before changing it. The same holds
for any provider whose usernames can be reassigned, which is most of them.

So:

- store the **principal id** (an integer) as the owner;
- store the login too, but only as a **display label**, refreshed on each login;
- when a login changes, the scope stays with the id and the displayed name
  updates;
- when an account is deleted, its scopes **MUST** become unclaimable rather than
  reverting to whoever next registers that login. Releasing one, if ever, is an
  operator decision (section 10).

#### The principal is not the claimant

The owner is the principal the scope was granted **for**, which is not
necessarily the human who performed the claim. For a user scope they are the same
account. For an organisation scope they are not: `@microsoft` belongs to
Microsoft's *organisation* id, and an employee who claims it does so **on behalf
of** the org and receives nothing personally.

Getting this wrong is not a subtlety. If the claimant became the owner, the first
employee to claim a corporate scope would own it, keep it after leaving, and be
able to publish under the company's identity indefinitely.

Authorisation therefore never asks "did you claim this". It asks:

> **May this caller currently act for the principal that owns this scope?**

For a user principal that is identity: are you that account. For an organisation
principal it is current membership (8.7).

#### Scope authority is necessary for every write

**Per-deck maintainer lists, where a registry offers them, may only narrow scope
authority, never widen it.** A caller who cannot act for the scope's principal
cannot publish, yank, unyank, or change owners under it, whatever any per-deck
list says.

Without that invariant, "I created `@microsoft/foo`, so I maintain it" survives
the author leaving the organisation, and the hijack returns one level down.

### 8.2 Claiming a scope

**Name authority is a local integer comparison.** The bearer token carries the
principal ids the caller may act for, the scope record carries the owner id, and
authorising a write compares them without a lookup. That holds for an
organisation scope (8.7) exactly as it does for a personal one: what differs is
*which* id the scope is bound to and *when* membership is established, never
whether a network call decides a write.

That is name authority only. **Publishing still calls the host**, to read the
manifest at the commit and to check source authority (7.1), so a publish is not
independent of GitHub. What this buys is that *scope ownership* never is: it
cannot be changed by anything happening on GitHub after the token was minted,
and it stays answerable when GitHub is unreachable.

A scope may be obtained three ways.

#### Derived: a user claiming their own login

A GitHub user **MAY** claim the scope whose folded name equals their own login,
and the registry binds it to their account id. `alice` may claim `@alice`.

The claim is a **one-time proof**. Afterwards the scope is bound to the id, and
the login is never consulted for authorisation again.

A registry **MUST** refuse a claim for a scope already bound to a different
principal, and **SHOULD** say so specifically rather than returning a bare
`403`: the caller may legitimately hold that GitHub login today while an earlier
holder still owns the registry scope (8.5). A dispute is an operator matter
(section 10).

#### Derived: a member claiming their organisation

A caller **MAY** claim the scope whose folded name equals an organisation they
are an `active` member of, and the registry binds it to the **organisation's**
numeric id, marked as an organisation scope (8.7). It grants the claimant
nothing personally: they can write under it for exactly as long as they remain a
member.

The organisations a caller may claim for are those their token carries, which
are the ones the identity provider **disclosed** - not necessarily the ones they
belong to. A provider **MAY** withhold a membership from an application it has
not been approved for, and GitHub does exactly that for any organisation with
third-party application restrictions enabled.

That failure mode is silent by construction: the token is valid, the account is
real, and the only symptom is a claim refused for a name the caller plainly
belongs to. A registry therefore **SHOULD** report the organisations a token
carries in the token exchange's response (8.4's `orgs`), so the shortfall is
visible at login rather than inferred from a later refusal.

#### Granted: an operator assignment

An operator **MAY** grant any scope to any principal id. This is not an
exception, it is the general mechanism, and it is needed from the first day for
three cases that derivation cannot serve:

- **a name that is not a GitHub name.** The `jennifer-language` organisation
  publishes official decks under `@jennifer`, which it does not own on GitHub;
- **an organisation the provider will not disclose.** Organisation scopes are
  derivable (8.7), but only for a membership the identity provider is willing to
  report; where it withholds one, the operator path is what remains;
- **a dispute or a reassignment**, including releasing a deleted account's scope.

A registry **MUST** be able to reserve names (its own, `@jennifer`, common
trademarks) so that no derived claim can take them.

Derivation solves squatting for the ordinary case: nobody claims `@microsoft`
without controlling that account. Registries that instead let anyone register any
vendor name, as Packagist does, avoid every naming problem in this section at the
cost of that property.

### 8.3 What a rename does, and does not, do

Because a scope is a name granted once on proof and bound to an id (8.1), **a
GitHub rename is a non-event for the registry**. Nothing is revoked, nothing
moves, and no record changes except the display label.

Concretely, when `old` renames to `new`:

| | |
| --- | --- |
| `@old` | stays bound to the same id, stays fully live, keeps accepting publishes |
| `@new` | **MAY** be claimed by the same account, if unclaimed, giving them two scopes |
| existing versions under `@old` | keep resolving forever |
| the display label | updates to the new login on next login |
| the freed GitHub login `old` | claimable by a stranger, who gets **no** registry rights |

A registry **MUST NOT** provide scope aliasing: `@old` **MUST NOT** be made to
resolve as `@new`. The reasons are the same as for deck aliasing, given in 5.1.1,
and `successor` is the advisory alternative for saying "this continues over
there" without making a published name mutable.

A registry **MUST NOT** freeze `@old` on rename either. The same principal
controls both scopes, so there is nothing to protect against, and freezing would
attach a mutable policy to a name whose stability is the point.

**The cost, stated plainly.** The stranger who legitimately takes the GitHub
login `old` can never claim `@old` here. That is unavoidable under id binding and
is the price of the property in 8.1. It makes the operator dispute path load
bearing rather than decorative.

**An operational note worth passing to authors.** GitHub frees the old login
immediately, and repository redirects break the moment somebody recreates a
repository of the same name under it (6.3). The one mitigation an author controls
is to register a placeholder account holding their old login straight after
renaming. A registry **SHOULD** say so where authors will read it.

### 8.4 The token exchange

A registry that accepts writes **MUST** serve these two endpoints, and **MUST**
advertise their paths in the discovery document (4.1). Without advertised paths
a client cannot log in at all: it has nowhere to send the exchange, and it has no
way to obtain the OAuth **client id**, which differs per registry because each
registry runs its own OAuth application.

| Route | Does |
| ----- | ---- |
| `POST /auth/device` | begin a device authorization, return the code the user types |
| `POST /auth/token` | exchange an approved device code for a registry token |
| `POST /auth/refresh` | exchange a refresh token for a new registry token |

**The registry drives the flow against GitHub; the client never talks to GitHub
and never holds a GitHub token.** That is what keeps the client free of
per-registry configuration, keeps the OAuth application's identifiers and scopes
the registry's business, and satisfies 8.4's rule that the registry issues its
own credential rather than passing GitHub's around. A registry **MAY** instead
publish its `clientId` and let the client run the flow directly, but then it
**MUST** advertise that id in the `auth` object, and it inherits the problem of a
GitHub token living in the user's dotfile.

#### `POST /auth/device`

No request body. Response `200`:

```json
{
  "deviceCode": "3584d83530557fdd1f46af8289938c8ef79f9dc5",
  "userCode": "WXYZ-1234",
  "verificationUri": "https://github.com/login/device",
  "expiresIn": 900,
  "interval": 5
}
```

`deviceCode` is opaque to the client and is only ever sent back to this
registry. `userCode` is what the user types at `verificationUri`. `interval` is
the minimum seconds between polls, and a client **MUST** honour it.

#### `POST /auth/token`

```json
{ "deviceCode": "3584d83530557fdd1f46af8289938c8ef79f9dc5" }
```

The client polls this until it resolves. The outcome is carried by the **status
code**, so a client can branch without parsing prose:

| Status | Body | Means |
| ------ | ---- | ----- |
| `200` | the token, below | approved |
| `202` | `{"status": "pending"}` | the user has not finished yet; poll again after `interval` |
| `429` | `{"error": "..."}` | polling too fast; back off, then continue |
| `403` | `{"error": "..."}` | the user denied the request; stop |
| `410` | `{"error": "..."}` | the device code expired; start over |

Response `200`:

```json
{
  "token": "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expiresIn": 3600,
  "refreshToken": "def50200f1a2...",
  "login": "alice",
  "accountId": 1234567,
  "orgs": ["acme", "viverto"]
}
```

`login` and `accountId` are the identity the token carries, returned so a client
can say "logged in as @alice" without decoding the token. **`accountId` is the
identity that matters** (8.1); `login` is a display label.

`orgs` is the organisation **logins** the token carries, sorted, and a registry
that supports organisation scopes **SHOULD** return it. Present and empty means
none; absent means the registry does not report them. Together with `login` it
is the complete list of scopes this token could derive a claim for, which is why
returning it matters: the list can be short for reasons invisible from the
client side (8.2), and a caller who sees it at login recognises a missing
organisation immediately instead of meeting an unexplained refusal later. The
ids are deliberately **not** returned - a claim is typed as a name, and the id
is the thing ownership binds to.

`refreshToken` is optional, and present only when the registry offers 8.4's
refresh path.

#### `POST /auth/refresh`

```json
{ "refreshToken": "def50200f1a2..." }
```

Answers exactly like a successful `POST /auth/token`, with a fresh `token` and
`expiresIn`. A rejected or expired refresh token is `401`, and the client's
remedy is to run the device flow again. A registry **SHOULD** rotate the refresh
token on each use.

### 8.5 Authorization is a bearer token

After the device flow the registry **SHOULD** issue its own short-lived signed
token (a JWT is the obvious choice) rather than storing the user's GitHub token.
It carries the account id, the login, and an expiry; the client sends it as
`Authorization: Bearer <token>` on writes.

No session store, no cookie, no CSRF: it is an API call with a header.

**The token is opaque to the client.** A client presents it and does not parse,
verify, or depend on its shape; the example in 8.4 shows a JWT because that is
the obvious choice, and its `alg` is illustrative rather than part of this
contract.

**Which signature algorithm to use follows from who verifies.** While the
registry is the only party that verifies its own tokens, a symmetric algorithm
is sufficient and simpler: one key, no distribution.

A registry that ever lets **anything else** verify - a CDN edge authorising at
the boundary, a companion service, a second implementation - **MUST** switch to
an asymmetric algorithm and publish the public key. With a symmetric key, the
ability to verify *is* the ability to sign, so handing a verifier the key hands
it the power to mint tokens for any account. There is no way to delegate one
without the other.

That is worth deciding before the second verifier exists rather than during it,
because the migration has to bridge tokens signed both ways.

Consequences to design for:

- **Expiry MUST be short enough to matter** (hours, not months) with a refresh
  path, or the token becomes a long-lived credential in a dotfile.
- **Revocation.** Revoking the GitHub grant **MUST** prevent obtaining a new
  registry token. A registry **SHOULD** also offer an operator path to invalidate
  outstanding tokens for an identity.
- **Organisation membership is only as fresh as the token that carries it.**
  8.7 specifies where it is read and why a registry that discards the provider
  token cannot re-ask at publish time. The rule that survives is the one there: a
  refreshed token **MUST NOT** advance the membership timestamp, and a registry
  **SHOULD** refuse an organisation-scope write whose memberships have aged out.
  Somebody removed from an organisation then loses access when their claim
  expires, not instantly.

### 8.6 The OAuth application

The OAuth app **SHOULD** request the narrowest scopes that work:

| Scope | Why |
| ----- | --- |
| `read:user` | the account's stable id and login |
| `read:org` | organisation membership, to authorise an org-owned deck scope |

**No `repo` scope is needed**, but not because the registry avoids repository
data: publishing reads `deck.toml` at a commit and checks the caller's
permissions on the repository (7.1, 7.2). Both are reachable without it, because
**decks are published from public repositories**. The `repo` scope exists for
private repository access, which a public registry has no use for and should not
hold.

`read:org` is listed for the organisation surface in 8.7, and is not needed by a
version 1 registry.

### 8.7 Organisation scopes

> Co-owners (2.2) are the interim answer to the same need, and a deliberately
> weaker one: they are an explicit list, so a departure is revoked only when
> somebody remembers to revoke it. Organisation scopes replace the list with a
> question asked of the provider, which is why they are still worth building even
> though co-owners exist. The two are complementary - a list can express a
> collaborator from outside the organisation, which membership cannot.


A scope **MAY** be owned by an **organisation** rather than a person. Such a
scope is granted by an operator (8.2) and marked as an organisation scope; every
later write under it asks whether the caller can act for that organisation,
instead of comparing their own id.

The shape follows from 8.1 without further choices:

- the scope is owned by the **organisation's** numeric id;
- a claim requires the claimant to be able to act for that organisation **at
  claim time**, and grants the claimant nothing personally;
- every later write re-asks whether the caller can act for that organisation
  **now**, so somebody who leaves stops being able to publish, yank, or change
  owners under it, promptly and without any bookkeeping.

`GET /user/memberships/orgs/{org}` answers exactly that question about the caller
and returns `role` (`admin`, `member`, `billing_manager`) and `state` (`active`,
`pending`). Two exclusions are not negotiable:

- **`state: pending` is not membership.** An invited but unjoined account has
  accepted nothing.
- **`billing_manager` is not authority.** It is a finance role with no
  relationship to code.

**What counts as acting for an organisation: any `active` member.** `admin` only
is safer but impractical, since the engineers who publish are usually not
organisation admins; a designated team is the middle path npm effectively takes,
at the cost of another API call and per-organisation setup. A deployment that
wants either of the stricter rules narrows it in its policy module (12.6); this
document specifies the broad rule as the default and requires the two exclusions
above regardless.

The consequence is worth stating plainly: **anyone an organisation adds becomes
able to publish under its scope.** That is the same trust an organisation already
extends by granting repository write access, and it is why membership is asked
rather than stored.

#### When membership is read

A registry that discards the provider token after login (8.4, which this
specification recommends) **cannot** ask the provider at write time, because it
holds no credential to ask with. It **MUST** therefore read memberships during
the exchange and carry them in its own token, and it **MUST** record when they
were read.

Two rules keep that honest:

- A refreshed token **MUST NOT** advance the membership timestamp. Refreshing
  proves possession of a refresh token, not continued membership; letting it
  move would make a stale membership renewable indefinitely, which is the exact
  failure an explicit owners list has.
- A registry **SHOULD** refuse an organisation-scope write whose memberships are
  older than a configured window, and say so, so the caller logs in again rather
  than being told they lack access they in fact have.

The cost is that revocation is not instant: somebody removed from an
organisation keeps write access until their token's memberships age out. That
bound is the honest form of 8.1's promise, and it is still far better than a list
somebody has to remember to edit.

Two consequences to design for:

- **An abandoned organisation freezes.** If everyone leaves, or the organisation
  is deleted, nobody can publish or yank under its scope, and the operator path
  (section 10) becomes the only remedy.
- **Publishing gains a dependency on the GitHub API.** An outage or a rate limit
  blocks publishes under organisation scopes. Reads are unaffected, and user
  scopes stay offline-authorisable.

### 8.8 Publishing without a browser

Everything in 8.4 assumes a human at a browser. That assumption breaks for the
most common publish there is: a pipeline that has just run the tests and should
release what it proved. A device grant cannot be completed by a runner, and a
registry that offers no alternative pushes every publisher toward the one thing
this section exists to prevent - a human pasting a long-lived credential into a
CI secret, or worse, publishing by hand from a laptop after a green build.

A registry that accepts writes **MUST** therefore offer at least one
non-interactive path, and **SHOULD** offer 8.9 where its forge supports it.

Two mechanisms, and they are not equivalent:

| | 8.9 Trusted publishing | 8.10 CI token |
| --- | --- | --- |
| Secret in CI | **none** | a bearer token |
| Lifetime | minutes, per job | until revoked or expired |
| Proves | this build, this repository, this ref | somebody holds this token |
| Source authority (7.1) | **yes, route C** | no; needs route A or B |
| Works from a laptop | no | yes |
| Works off-forge | no | yes |

Trusted publishing is the better mechanism wherever it is available, because a
credential that does not exist cannot leak. A CI token is the fallback, and a
registry **MUST NOT** treat it as the recommended path.

Both bootstrap from 8.4: registering a trusted publisher, or minting a token, is
a write like any other and is authorised by 8.2's scope binding. **The browser
step does not disappear, it becomes one-time.**

### 8.9 Trusted publishing

A registry **MAY** accept an OIDC identity token issued by a CI system to a job,
in place of a bearer token, at the write endpoints.

#### The binding

A trusted publisher is a record on a **deck**, or on a scope, naming the workload
permitted to write to it:

| Field | Meaning |
| ----- | ------- |
| `provider` | which issuer, e.g. `github-actions`, `gitlab-ci`, `gitea-actions` |
| `repositoryId` | the forge's immutable numeric repository id |
| `repository` | the repository path, for display |
| `workflow` | the workflow file that may publish |
| `refPattern` | which refs may publish, e.g. `refs/tags/*` |

The binding **MUST** key on the **immutable repository id**, not the path, for
the reason 8.1 gives about logins: a repository path can be renamed and the
freed path re-registered by somebody else. The path is a display label.

#### Verifying a token

A registry **MUST**, in this order:

1. fetch the issuer's JWKS from its OIDC discovery document, and **cache it**;
2. verify the signature, `iss`, `exp`, `nbf`, and `iat`;
3. verify `aud` **matches a value this registry chose and published**, and reject
   a token minted for any other audience;
4. match the repository, workflow, and ref claims against a registered binding;
5. authorise the write against that binding, and no other credential.

Step 3 is not optional. Without an audience check, a token minted for an
unrelated service - or for a *different registry* - is replayable here by whoever
receives it, and CI tokens are handed to third-party actions routinely.

A registry **MUST** reject a token whose claims match no binding, and **MUST
NOT** fall back to creating one. Auto-binding on first use would let whichever
repository publishes first capture a deck name.

#### Claim names differ per provider

The claims are provider-specific, which is why `provider` is part of the binding.
`sub` is **not** a stable key: its shape varies by provider and by configuration.
Match on the individual claims.

| | GitHub Actions | GitLab CI | Gitea / Forgejo Actions |
| --- | --- | --- | --- |
| `iss` | `token.actions.githubusercontent.com` | the instance URL | the instance URL |
| repository id | `repository_id` | `project_id` | `repository_id` |
| repository | `repository` | `project_path` | `repository` |
| workflow | `job_workflow_ref` | `workflow_ref` | `workflow` |
| ref | `ref` | `ref` | `ref` |

> **Partly verified.** The *forge* endpoints for all three are exercised against
> live instances (github.com, gitlab.com, codeberg.org). The **CI claim names in
> the table above are not**: they need a pipeline run on each, which needs an
> account on each. The GitHub Actions set is the one the reference implementation
> is built against.

#### First publish

A deck that does not exist yet has nothing to bind a publisher to. A registry
**MUST** allow a **pending binding**: the scope owner registers `(provider,
repositoryId, workflow, deck name)` before the deck exists, and the first
successful publish converts it into a normal binding. A pending binding
**SHOULD** expire if unused, so an abandoned one does not reserve a name
indefinitely.

The scope must already be owned (8.2), so a pending binding never bypasses name
authority. It only removes the ordering problem.

### 8.10 CI tokens

Where 8.9 is unavailable - a laptop, a cron job, a CI system with no OIDC - a
registry **MAY** issue a long-lived bearer token for non-interactive use.

Because such a token is a standing credential, a registry that issues them:

- **MUST** scope each token to a scope, or to a single deck, and **MUST NOT**
  issue one that can write everything the minting user can;
- **MUST** support revoking one without disturbing the others, and **SHOULD**
  default them to an expiry rather than to none;
- **MUST** show the token exactly once, at creation;
- **SHOULD** record last-used time, so an unused token can be found and removed;
- **MUST** record every write a token performs in the operational log (section
  11), because detection is the only control left once a standing secret exists.

A CI token proves possession and nothing more. It establishes **name authority
only**, and a registry **MUST** still satisfy 7.1 by route A or B before
accepting the publish.

## 9. Immutability, yanking, and deletion

- **A published version is immutable.** Re-publishing an existing version
  **MUST** fail with `409`. Consumers pin exact versions; mutating a version
  silently changes other people's builds.
- **Yank, do not delete.** A yanked version **MUST NOT** satisfy a constraint
  during fresh resolution, and **MUST** remain fetchable so an existing lockfile
  still installs. Yanking is reversible.
- **Deletion SHOULD NOT be offered.** If it must exist for legal reasons, treat
  it as an operator action, not a user-facing one, and expect it to break
  downstream builds.

## 10. The website

The web surface **SHOULD** be read-only. Every author action belongs in the CLI
(section 7). What the web is genuinely needed for is **discovery and
evaluation**:

- a deck page with the version history, dependencies, declared capabilities, and
  required engines (and, when available, the rendered README and license);
- search;
- stable, linkable URLs, so a deck can be found from a search engine.

A registry **SHOULD** serve the human pages and the JSON API from the same
origin, negotiating on `Accept` where a path serves both. Where a page needs a
URL that the JSON API already uses with different segment semantics, the page
**MUST** take a different path rather than overloading it: `/decks/:name/:version`
already means name plus version, so a two-segment scoped deck page cannot live
there. This implementation uses `/deck/<scope>/<deck>`.

Because a published version is immutable, nearly all of this can be **generated
at publish time** and served as static files from a CDN. That keeps installs
working when the write service is down, which is the outage that matters.

There **SHOULD NOT** be a web publish form, account management pages, or an admin
UI.

**Operator actions** - taking down a malicious deck, force-yanking, reassigning a
scope after a dispute or a deleted account, invalidating an identity's tokens -
are rare and privileged. They **SHOULD** be an operator CLI rather than a web
surface that has to be defended. They are not user-facing.

## 11. Operational requirements

- **Rate limit** writes per identity and reads per address; return `429`.
- **Reads must stay available** independently of writes. A consumer running
  `install` during a publish outage should be unaffected.
- **Immutable responses are cacheable.** Serve `/deck?name=` with a validator.
- **Log publishes durably.** Who published what, when, from which identity. This
  is the audit trail for a supply-chain incident, and it cannot be reconstructed
  later.
- **Treat every uploaded archive as hostile.** Bound its size, bound the
  decompressed size, and reject entries with absolute paths or `..` segments.

## 12. Providers and profiles

Nothing in sections 1 to 11 is inherent to GitHub. A registry depends on external
services in exactly two roles, and both are pluggable; the public registry simply
configures GitHub for both.

### 12.1 Two roles, which only coincide on GitHub

| Role | Answers | Used by |
| ---- | ------- | ------- |
| **identity provider** | who is this caller, stably? | login (section 8), name authority |
| **forge** | what is in this repository, and who may push to it? | publishing (section 7) |

On `github.com` one service plays both, which is why the earlier sections read as
though there were only one. A deployment commonly pairs an SSO provider with a
self-hosted forge - Authelia in front of Gitea, say - so a registry **MUST** allow
the two to be configured independently.

### 12.2 What a registry needs from an identity provider

| Answers | Why |
| ------- | --- |
| a **stable subject identifier** | what scope ownership binds to (8.1); must not change when a username does |
| a **display label** | shown to humans, refreshed on each login, never authoritative |
| the **flow** it supports | the client is told, and adapts (below) |
| a **CLI-drivable exchange** | the registry has no browser form of its own (8.4) |

The subject is the `sub` claim for OIDC and the numeric id for GitHub. A registry
**MUST** store it together with its issuer, because a subject is unique only
within one.

Any OAuth 2.0 or OIDC provider satisfying that can be used, which means a generic
OIDC provider covers Authelia, Keycloak, and anything else standards-compliant
without bespoke code. A dedicated provider is worth writing only where the
service deviates from the standard or offers something extra worth using.

#### Flows

`auth.flow` in the discovery document (4.1) tells a client what to run:

| `flow` | How it works | Trade-off |
| ------ | ------------ | --------- |
| `"device"` | the registry drives RFC 8628 against the provider; the client only polls the registry | the client never talks to the provider and needs no provider configuration |
| `"authcode"` | the client runs authorization code + PKCE with a loopback redirect (RFC 8252), then exchanges the result at `tokenUrl` | works with any OAuth2 provider, but the client must open a browser, listen on `127.0.0.1`, and be told the provider's endpoints |

`"device"` is preferred wherever the provider implements it, because it keeps the
client dumb and provider-agnostic. A registry advertising `"authcode"` **MUST**
additionally advertise `authorizeUrl`, `clientId`, and `scopes`, since the client
cannot construct those itself.

A client **MUST** treat an unrecognised `flow` as "cannot log in here" and say so,
rather than guessing. **A provider token obtained by either flow MUST NOT be
stored by the client**; it is exchanged for the registry's own credential (8.5).

### 12.3 What a registry needs from a forge

| Answers | Used for |
| ------- | -------- |
| does this forge handle this URL? | selecting among configured forges (12.4) |
| resolve a tag to a commit SHA | 7, step 2 |
| read a file at a commit | reading `deck.toml`, 7 step 3 |
| may this caller push to this repository? | source authority, 7.1 |
| a stable repository id and owner id | provenance, 6.4 |

| Forge | Permission check | Notes |
| ----- | ---------------- | ----- |
| GitHub | `GET /repos/{owner}/{repo}` -> `permissions.push` | |
| GitLab | `GET /projects/{id}` -> `permissions`, project or group access level | write is access level 30 (developer) or above; self-hosted differs only in base URL |
| Gitea | `GET /repos/{owner}/{repo}` -> `permissions.push` | API is deliberately GitHub-shaped |
| Forgejo | as Gitea | a Gitea fork; the API is compatible |

> **Verify before implementing.** These endpoint shapes are stated from each
> forge's documented API and have **not** been exercised against a live instance.
> Confirm each, and confirm the minimum token scope that returns a populated
> permission field, before depending on the table.

**Self-hosted is configuration, not a separate provider.** GitLab, Gitea, and
Forgejo self-hosted instances speak the same API as their hosted counterparts and
differ only in base URL, so one module per API family covers both. Forgejo is a
Gitea fork and needs no module of its own unless the APIs diverge.

### 12.4 Selecting providers

A deployment configures **one identity provider** and **one or more forges**. Each
forge declares which URLs it handles, which is what lets a private registry accept
both an internal Forgejo and public GitHub dependencies in one graph.

A version record whose `url` matches no configured forge is unverifiable, and 7.1
applies: refuse, or record the source as unverified and show it.

### 12.5 When identity and forge are different services

This is the part that does not follow from the public design.

When GitHub is both roles, the login flow yields a GitHub token, so the registry
can ask GitHub about the caller's permissions directly. **With Authelia in front
of Gitea it cannot**: it holds an Authelia token, which Gitea will not accept.

A registry therefore **MUST** be configured with one of:

- **a forge service account.** The registry holds a forge token with enough rights
  to query repository permissions, and maps the caller's identity onto a forge
  account. Usual in a private deployment, where both services already share a user
  directory.
- **a linked forge identity per user.** The user authorises the forge separately,
  once, and the registry keeps that association. More moving parts, but it needs
  no privileged service token.
- **nothing**, in which case source authority is unverifiable and 7.1 applies.

Mapping an identity onto a forge account **MUST NOT** be done by matching display
names. A registry **SHOULD** use a claim the provider asserts and the forge agrees
with - typically the same directory's username or email when both are backed by
one LDAP or OIDC source - and **MUST** treat a failed mapping as unverifiable
rather than as permission granted.

### 12.6 Policy is the third axis, and it is pure

Identity and forge answer questions about the outside world. **Policy answers
questions about what this deployment permits**, and it is configured
independently of both: the same `github` + `github` pair can run the public
policy or a stricter internal one.

A deployment therefore names three things:

```
identity = github
forge    = github
policy   = official
```

**A policy module MUST NOT perform I/O.** It receives facts already gathered - the
authenticated subject, the requested scope, the outcome of the source-authority
check - and answers allow or deny. Two things follow, and both are the point:

- every decision that governs who may publish what lands in **one small
  auditable file**, rather than being spread across the code that talks to
  GitHub;
- the whole of it is **testable without a network**, so the security-relevant
  surface is the part with the cheapest tests.

The questions a policy answers:

| Question | Governs |
| -------- | ------- |
| may this subject claim this scope? | the derived rule, and reserved names |
| is this name acceptable? | narrowing 2.1 |
| is an unverified source acceptable? | 7.1, refuse or record |

#### Policy may subtract, never add

A policy **MAY narrow** what this document permits and **MUST NOT widen** it. A
deployment that accepted names outside 2.1 would emit records a conforming client
cannot install, and one that granted authority beyond 8.1 would break the
guarantees consumers rely on. This has the same shape as the per-deck rule in
8.1: policy subtracts.

#### Claim policy

| Policy | A subject may self-claim | Suits |
| ------ | ------------------------ | ----- |
| `operator` | nothing; every scope is granted | a private registry that wants a planned namespace |
| `derived` | only the scope matching its own provider username | a public registry, where names must mean something |
| `firstcome` | any unclaimed, unreserved scope | a private registry that wants no friction |

**Operator grants are available under all three**, and do not pass through
`mayClaim`; the policy governs *self-service* claiming only.

Two notes on choosing:

- **A private registry usually wants `operator` or `firstcome`.** Self-service
  claiming exists to settle competition for names between strangers, and inside
  an organisation there are no strangers. `operator` gives a namespace that maps
  onto teams; `firstcome` gives no friction at all.
- **`firstcome` is hard to reverse.** A scope name then means only that somebody
  asked first, which is Packagist's position and a perfectly workable one, but
  names are far cheaper to protect before they are handed out than after. A
  registry that may one day be public should think twice about starting there.

### 12.7 The official public registry

The public registry is one profile among several, and its choices are policy
rather than protocol:

| | |
| --- | --- |
| identity | `github` |
| forge | `github`, and `gitlab` for hosting only (below) |
| policy | `derived` |
| flow | `device` |
| claim policy | `derived` self-claims, plus operator grants |
| derived rule | a subject may claim the scope equal to its folded GitHub login |
| reserved | the registry's own names, `@jennifer`, common trademarks |
| source authority | route A on GitHub, route B elsewhere |
| name grammar | exactly 2.1, unnarrowed |

Where earlier sections state a GitHub fact as though it were universal - a
released login being immediately claimable (6.3), case-insensitive account
uniqueness (2.1) - it is this profile being described. The reasoning generalises;
the specifics do not.

#### One identity, several forges

**Identity is singular; hosting need not be.** The public registry authenticates
every caller through GitHub, and a scope is claimed by proving a GitHub identity
and nothing else. Where the *code* lives is a separate question, so a deck hosted
on `gitlab.com` can be published under a GitHub-derived scope.

The consequence is that **route A cannot serve the second forge**: the registry
holds a GitHub credential, which GitLab will not accept, so it cannot ask GitLab
whether the caller may push (12.5). A cross-forge deck is therefore published
under **route B**, a tag signed by a key the scope has registered (7.1).

That ordering matters operationally: **key registration has to exist before a
second forge can be accepted.** Adding `gitlab` to the forge list without it
would leave every GitLab-hosted publish unverifiable, and this profile refuses
those.

#### Caveats of the strict profile

`derived` is the strictest self-service policy, and the failure modes it leaves
are predictable enough to prepare for. Acting on these before opening claims is
far cheaper than afterwards.

**Do before opening claims:**

- **Populate the reserved list.** Once a name is claimable it can be claimed, and
  taking it back is a dispute. `@jennifer` in particular is claimable by anyone
  who registers that GitHub username, and the org that needs it is called
  `jennifer-language`.
- **Decide the organisation story.** Organisation scopes are not in version 1
  (8.7), so an organisation's decks either sit under an individual's personal
  scope or need an operator grant. **Prefer the operator grant**: moving a deck
  out of a person's scope later is a rename that the no-aliasing rule (8.3)
  deliberately makes awkward.
- **Open the operator queue.** Derivation does not cover a name the provider does
  not have, so operator grants are not an exception path, they are load bearing
  from day one.

**Expect, and have an answer ready:**

- **Claim refusals that look like bugs.** A user who renamed on GitHub still owns
  their old scope, and the stranger who later takes that username will be refused
  when claiming it. The refusal must name the cause, and the operator needs a
  dispute path (10).
- **Typosquatting, which derivation does not address.** `@micr0soft` is unclaimed
  upstream, so somebody registering that username may derive it legitimately. The
  reserved list and takedown are the only answers; do not expect the policy to
  help.
- **Hyphen friction.** A GitHub repository called `my-deck` cannot be a deck named
  `my-deck`: the deck half of a name is a Jennifer identifier and takes no hyphens
  (2.1), though the scope half does. Authors will hit this and it needs saying in
  the manual, not in a rejection message.
- **Deleted accounts freeze their scopes.** When an account goes, its scopes
  become unclaimable by design (8.1), and the decks under them can no longer be
  published or yanked. Only an operator reassignment unfreezes them, so that
  ability needs to exist before it is needed.

### 12.8 What an operator needs

At minimum, an operator tool **MUST** be able to:

- **grant a scope** to a subject, and revoke it;
- **list** scopes with their owning subject and display label;
- **reassign** a scope, for a dispute, a departure, or a deleted account (10);
- **invalidate** an identity's outstanding tokens (8.5).

These are privileged and rare, and **SHOULD** be a CLI on the server rather than a
web surface that has to be defended (10).

## 13. Conformance checklist

A registry is usable by a client when:

- [ ] `GET /.well-known/jennifer-registry` returns 4.1, listing `apis` and `features`
- [ ] `features` includes `deck`
- [ ] a version served at several base paths lists the canonical one first
- [ ] every endpoint is reachable under the advertised `apis[].basePath`
- [ ] `GET /deck?name=<scoped-name>` returns 5.1 for a known deck
- [ ] it returns `404` with an `error` body for an unknown one
- [ ] version records carry `version`, `kind`, `url`
- [ ] `version` is bare SemVer: `1.0.0` is served, `v1.0.0` is refused (2.3)
- [ ] a prerelease satisfies only a constraint naming a prerelease on the same
      `major.minor.patch`, and is never selected by `*` or a bare comparator (2.4)
- [ ] a `kind: "git"` record carries `ref` and a full 40-character `commit`
- [ ] a `kind: "tar.gz"` record carries a well-formed `sha256:` `checksum`
- [ ] `/resolve` and `/resolve-graph`, if offered, carry the pin for each `kind`
- [ ] absent `requires` / `engines` / `capabilities` behave as empty
- [ ] absent `kind` is treated as `"tar.gz"`
- [ ] scoped names work as query parameters (not mangled by path routing)
- [ ] the published tree contains `src/<deck>.j`

Naming (section 2.1):

- [ ] names are folded to lowercase on the way in, and a lookup for either
      casing finds the same deck
- [ ] a hyphen is accepted in a scope, and rejected in a deck name
- [ ] a scope does not begin or end with a hyphen, or contain two in a row
- [ ] a Windows reserved device name is rejected as either half

Publishing, where it is offered (section 7):

- [ ] the deck name is taken from `deck.toml` at the resolved commit, and the
      scope check runs against **that** name
- [ ] source authority is verified, or the source is recorded and shown as
      unverified
- [ ] a repository the caller cannot push to is refused, even when its manifest
      names a scope the caller owns
- [ ] `repoOwnerId` is recorded, and the owning account is shown with the deck

Ownership, where writes are offered (section 8):

- [ ] a scope resolves to a numeric principal id, and authorisation never
      consults a login
- [ ] a login is stored only as a display label and refreshed on login
- [ ] a claim for a scope already bound to another principal is refused, with a
      message saying so
- [ ] a rename leaves the old scope live, bound, and publishable
- [ ] no mechanism makes one scope resolve as another
- [ ] no credential authorises a write under a scope with no owner, checked at
      the write and not only where the credential was created
- [ ] `repoId` is not treated as a uniqueness key across decks
- [ ] a `ref` shaped like an object id (7 to 64 hex digits, either case) is
      refused and never stored

Non-interactive publishing, where it is offered (section 8.8):

- [ ] at least one path exists that completes without a browser
- [ ] a trusted-publishing registry advertises `auth.trustedPublishing.audience`
- [ ] a token whose `aud` is not that value is refused
- [ ] `iss`, `exp`, `nbf`, and the signature are verified against the issuer's
      cached JWKS
- [ ] bindings key on the immutable repository id, never on the repository path
- [ ] a token matching no registered binding is refused, and no binding is
      created on its behalf
- [ ] a pending binding requires the scope to be owned already, and expires when
      unused
- [ ] a CI token is scoped narrower than its minting user, revocable on its own,
      and shown exactly once
- [ ] a CI token satisfies name authority only; 7.1 is still established
      separately
- [ ] every write performed by a CI token appears in the operational log

## Appendix: a worked example

Publishing `@acme/routeros` 0.1.0, which depends on `@acme/net ^1.0.0`, needs
`net`, and requires Jennifer 0.24 or newer.

The author tags the release and runs a publish, which sends the repository and
the tag. The repository at `v0.1.0` contains:

```
deck.toml
src/routeros.j
src/query/words.j
template/main.j        (optional; used by the client's scaffold verb)
```

`deck.toml` inside the tree declares:

```toml
[package]
name = "@acme/routeros"
version = "0.1.0"
description = "MikroTik RouterOS client"
capabilities = ["net"]

[engines]
jennifer = ">=0.24.0"

[decks]
"@acme/net" = "^1.0.0"
```

The registry resolves `v0.1.0` to a commit, reads that manifest **at that
commit** rather than trusting the request, and stores:

```json
{
  "version": "0.1.0",
  "kind": "git",
  "url": "https://github.com/acme/deck-routeros.git",
  "ref": "v0.1.0",
  "commit": "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
  "checksum": "",
  "requires": { "@acme/net": "^1.0.0" },
  "engines": { "jennifer": ">=0.24.0" },
  "capabilities": ["net"],
  "description": "MikroTik RouterOS client",
  "publishedAt": "1770000000"
}
```

If `acme` later force-pushes `v0.1.0` to a different commit, nothing changes for
consumers: the registry still hands out `9f2c1d4e...`.
