# The executables

Two programs live in `bin/`, and both are deliberately thin: they read the
environment, call a module in `src/`, and print the result. All the logic, and
all the tests, are in the modules.

| | |
| - | - |
| `bin/serve` | the HTTP server and website, over `src/apiview.j` and `src/webview.j` |
| `bin/deckadmin` | the operator CLI, over `src/admin.j` |

A third, `bin/healthcheck`, exists only as the container's health probe; it is
not a tool you run by hand.

Both read the same database, so `deckadmin` edits show up in the server without a
restart: every request opens the store fresh.

## Configuration

Settings come from three places, each overriding the one before:

1. built-in defaults - a read-only, plain-HTTP registry
2. `config.toml` (or `$REGISTRY_CONFIG`), if present
3. the environment

**The environment wins.** The file states how a deployment is meant to run; the
environment varies one instance, or injects a secret, without editing a file into
an image. `config.toml.example` documents every key beside the variable that
overrides it.

An environment variable set to an **empty string counts as unset**, so a stray
blank cannot erase what the file configured. Booleans are the exception and parse
their value (`1 true yes on` / `0 false no off`), because `0` has to be able to
switch off what the file switched on.

A configuration that cannot be served is refused at startup with the reason,
rather than accepted and discovered at the first request.

## TLS and Let's Encrypt

The registry can obtain and renew its own certificate over the ACME HTTP-01
challenge, storing it in the data directory beside the database.

```toml
[tls]
enabled = true
domains = ["registry.example.com"]
email = "ops@example.com"
agreeTos = true
```

`agreeTos` has no default of `true` and never will: accepting a CA's terms is a
decision an operator makes, not one a program makes for them.

**Port 80 must reach the plain listener from the internet.** That is where the CA
knocks for the challenge, and it is why the plain listener is not simply a
redirect to HTTPS. The plain listener starts first and stays up throughout, so
the registry keeps serving while a certificate is being obtained or renewed.

**Use the staging directory first.** It issues untrusted certificates with far
higher rate limits; production limits are per registered domain per week, and a
misconfigured deployment can exhaust them before anyone notices. The registry
says at boot when it is pointed at staging, because otherwise the first sign is a
browser warning.

```
REGISTRY_ACME_DIRECTORY=https://acme-staging-v02.api.letsencrypt.org/directory
```

Renewal is decided from the recorded issue time, `renewBeforeDays` before the
90 day lifetime expires. A renewal that fails while a valid certificate is still
on disk keeps serving the old one and logs the failure; a *first* issuance that
fails leaves the registry on plain HTTP with an `error` in the log rather than
refusing to start.

## Environment

> **Renamed.** These variables used to be `JVC_*`. `jvc` is the *client*, so a
> host running both had one `JVC_DB` meaning two different databases. The old
> names are still read and warn on use; they will stop being read in a later
> version. A rename that merely ignored them would be worse than none, because an
> unset variable falls back to a **default** - an already-configured deployment
> would silently start serving a different database rather than failing.
>
> `JVC_TOKEN` is unaffected: that one belongs to the client.

| Variable | Default | Used by | Meaning |
| -------- | ------- | ------- | ------- |
| `REGISTRY_DB` | `data/decks.json` | both | the flatdb database path |
| `REGISTRY_ADDR` | `:8080` | `serve` | the listen address |
| `REGISTRY_URL` | unset | `serve` | the canonical base URL advertised in discovery |
| `REGISTRY_CLIENT_IP_HEADER` | unset | `serve` | header a trusted proxy puts the real client address in |
| `REGISTRY_POLICY` | `derived` | `serve` | who may claim a scope: `derived`, `operator`, `firstcome` |
| `REGISTRY_LOG` | unset | both | append the operational log to this file |
| `REGISTRY_LOG_LEVEL` | `info` | both | `debug`, `info`, `warn`, `error` |
| `REGISTRY_LOG_FORMAT` | `logfmt` | both | the *file* format: `text`, `logfmt`, `json` |
| `REGISTRY_LOG_REQUESTS` | `0` | `serve` | record one line per request |
| `REGISTRY_IDENTITY` | `github` | `serve` | which identity module: `github`, `gitlab`, `gitea`, `forgejo`, `oidc` |
| `REGISTRY_IDENTITY_CLIENTID` | unset | `serve` | the OAuth application id |
| `REGISTRY_IDENTITY_BASEURL` | unset | `serve` | the provider's base URL, for a self-hosted instance |
| `REGISTRY_IDENTITY_SECRET` | unset | `serve` | the client secret, for a provider that needs one |
| `REGISTRY_IDENTITY_SCOPES` | per module | `serve` | override the requested scopes |
| `REGISTRY_TOKEN_KEY` | unset | `serve` | the HMAC secret bearer tokens are signed with |
| `REGISTRY_CONFIG` | `config.toml` | `serve` | where the configuration file is |
| `REGISTRY_TLS` | `0` | `serve` | serve HTTPS and obtain a certificate |
| `REGISTRY_TLS_ADDR` | `:8443` | `serve` | the HTTPS listen address |
| `REGISTRY_TLS_DOMAINS` | unset | `serve` | the certificate's names, comma or space separated |
| `REGISTRY_TLS_EMAIL` | unset | `serve` | the account contact the CA requires |
| `REGISTRY_ACME_AGREE_TOS` | `0` | `serve` | accept the CA's terms |
| `REGISTRY_ACME_DIRECTORY` | Let's Encrypt production | `serve` | the ACME directory URL |
| `REGISTRY_TLS_CERTDIR` | `data/tls` | `serve` | where the certificate is stored |
| `REGISTRY_ACME_CHALLENGEDIR` | `data/acme-challenge` | `serve` | where challenge responses are written |
| `REGISTRY_TLS_RENEW_BEFORE_DAYS` | `30` | `serve` | how early to renew |
| `REGISTRY_FORGE` | `github` | `serve` | which forge module: `github`, `gitlab`, `gitea`, `forgejo` |
| `REGISTRY_FORGE_BASEURL` | unset | `serve` | the forge's API root, for a self-hosted instance |
| `REGISTRY_FORGE_TOKEN` | unset | `serve` | a service token, where the forge needs one to read |
| `REGISTRY_FORGE_HOST` | unset | `serve` | the hostname whose URLs this forge claims |
| `REGISTRY_TRUSTPUB_AUDIENCE` | unset | `serve` | the `aud` a CI token must carry; gates trusted publishing |
| `REGISTRY_TRUSTPUB_PROVIDER` | `github-actions` | `serve` | `github-actions`, `gitlab-ci`, or `gitea-actions` |
| `REGISTRY_TRUSTPUB_ISSUER` | per provider | `serve` | the OIDC issuer, required for anything self-hosted |

The server's console always receives the log, in human-readable text; the file
is the extra copy, and it is the only one that survives a restart. **Both
binaries write to the same file**, which is what makes it worth reading: the
server never sees a publish and `deckadmin` never sees a request. Nothing rotates
it, so a long-lived deployment should point logrotate at it.

**Behind a proxy the access log records the proxy** unless you name the header
carrying the real address. Unset is the safe default: the connection's own peer
cannot be forged, whereas a header can be sent by anybody. Only name one if
something in front of the registry sets it *and* strips any client-supplied copy
- otherwise the audit log becomes what callers claim about themselves.

Behind Cloudflare use `CF-Connecting-IP`, which Cloudflare overwrites on every
request and which therefore survives any number of hops. Behind Traefik alone use
`X-Forwarded-For`; the first entry is taken, which is the original client by
convention.

`REGISTRY_LOG_REQUESTS` is separate from the level because an access log is wanted at
`info` far more often than the rest of `debug` is, and because a container with a
30-second health probe otherwise fills its log with itself.

**`REGISTRY_IDENTITY_CLIENTID` and `REGISTRY_TOKEN_KEY` gate the login surface.** Set both and the registry serves the
token exchange and advertises it; leave either unset and the auth routes are not
registered, no `auth` object appears in the discovery document, and a client
reports that this registry accepts no logins. That default is deliberate: a
registry with no write API has nothing to authenticate.

`REGISTRY_TOKEN_KEY` is a secret. Changing it invalidates every outstanding bearer
token at once, which is the blunt instrument if one leaks.

**`REGISTRY_TRUSTPUB_AUDIENCE` gates publishing from CI** (specification 8.9). Set it
and `POST /publish` accepts a CI identity token in place of a bearer token, and
the discovery document advertises the audience so a job knows what to ask its CI
system for. It is **not** a secret - publishing it is what makes the check
enforceable - but it must be specific to this registry, because its whole purpose
is that a token minted for somewhere else is refused here. The registry's own
hostname is a good choice.

The issuer's key set is fetched **once at boot** and held for the process, so a
key rotation needs a restart. Fetching per request would put two round trips in
front of every publish and make this registry unavailable whenever the issuer is.

`REGISTRY_FORGE*` configures how a publish reads a repository: resolving a tag to a
commit and reading `deck.toml` at it. Identity and forge are independent choices
that only coincide on `github.com`, so they are configured separately.

A missing database file opens as an empty registry rather than failing, so a
first run needs no seed file.

## serve

```sh
jennifer serve bin/serve
REGISTRY_DB=/srv/registry.json REGISTRY_ADDR=:9000 jennifer serve bin/serve
```

It serves the JSON routes in [api.md](api.md) and the website below. There is no
write path: every change goes through `deckadmin` on the server's filesystem.

### The website

Read-only by design: no form that writes anything, no session, no account UI.

| Route | Is |
| ----- | -- |
| `/` | the deck listing with a search box (HTML), or the service index (JSON) |
| `/search?q=` | results (HTML), or the JSON result set |
| `/deck/<scope>/<deck>` | a deck page: versions, pins, dependencies, engines, capabilities |
| `/manual/` | the user manual: finding, using, and publishing decks |
| `/reference/` | these pages, rendered |

`/` and `/search` pick their format from the request's `Accept` header, so a
browser and a client can share one URL. Deck pages sit under `/deck/` rather
than `/decks/`, because `/decks/:name/:version` is the JSON API's and would
match a two-segment scoped deck page as a name plus a version.

The two static sections are two [Grimoire](https://github.com/jennifer-language/grimoire)
books, because they have two audiences and grimoire builds one source directory
into one output directory. Each directory is named for the URL it serves at,
which it must: `web.serveDir` joins the whole request path onto the static root.

| Source | Config | Served from | At |
| ------ | ------ | ----------- | -- |
| `manual/` | `grimoire-manual.toml` | `public/manual/` | `/manual/` |
| `reference/` | `grimoire.toml` | `public/reference/` | `/reference/` |

```sh
docker run --rm --pull always --user "$(id -u):$(id -g)" \
    -v "$PWD:/work" ghcr.io/jennifer-language/grimoire build --clean
docker run --rm --pull always --user "$(id -u):$(id -g)" -v "$PWD:/work" \
    ghcr.io/jennifer-language/grimoire build --clean \
    --config grimoire-manual.toml
```

`public/` is gitignored, and the container image builds both books in its own
stage, so no rendered copy is ever committed or shipped stale. A deployment that
has not built a section answers it with a page saying which command produces it,
rather than a bare 404.

`--clean` empties the output directory first. It matters after deleting or
renaming a page: grimoire defaults to `--no-clean`, so the old HTML would
otherwise keep serving under its old URL.

## deckadmin

```sh
jennifer run bin/deckadmin [logging flags] <command> [args]
```

### Logging flags

These are **root flags: they go before the command**, because that is where the
argument parser resolves them. `deckadmin --log x.log add ...` works;
`deckadmin add ... --log x.log` is rejected as an unknown flag on `add`.

| Flag | Environment | Default | Means |
| ---- | ----------- | ------- | ----- |
| `--log <path>` | `REGISTRY_LOG` | none | append events to this file |
| `--log-level <level>` | `REGISTRY_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `--log-format <fmt>` | `REGISTRY_LOG_FORMAT` | `logfmt` | `text`, `logfmt`, `json` |
| `-v`, `--verbose` | | off | also print each event to the console |
| `-q`, `--quiet` | | off | suppress the result message |

A flag beats the environment, which beats the default, so a container can set
`REGISTRY_LOG` once and a single command can still be redirected. `--verbose` is off
by default because `deckadmin` already prints a result line; turning it on is for
when the structured form is what you want to read.

The file is **the same one the server appends to**. That is the point of it: the
server never sees a publish and `deckadmin` never sees a request, so only the
shared file shows both.

| Command | Does |
| ------- | ---- |
| `add <deck> <version> <url> [description] [flags]` | publish a version (an upsert) |
| `update ...` | an alias of `add` |
| `remove <deck> [version]` | remove one version, or a whole deck |
| `list [deck]` | list decks, or one deck's versions |
| `register-namespace <scope> [flags]` | grant a scope to a principal, or reserve it |
| `add-owner <scope> <subject>` | let another principal write under a scope |
| `remove-owner <scope> <subject>` | revoke a co-owner |
| `namespaces [--owned\|--reserved]` | list registered scopes and who owns each |
| `trust <deck> <repositoryId> [flags]` | let a CI workflow publish a deck (8.9) |
| `untrust <deck>` | remove a deck's trusted publisher |
| `publishers` | list trusted publishers |
| `reserve-defaults [--dry-run]` | hold every reserved scope so nobody can claim one |
| `mint-token <scope> [flags]` | mint a CI token, shown once (8.10) |
| `tokens` | list CI tokens and when each was last used |
| `revoke-token <fingerprint>` | revoke one CI token |
| `yank <deck> <version>` | withdraw a version from new resolutions |
| `unyank <deck> <version>` | restore a withdrawn version |
| `revoke <accountId>` | invalidate an identity's refresh tokens |

#### Organisation scopes

`--org` marks the owner as an **organisation** rather than a person, and changes
the question every later write asks: not "is this your scope" but "are you an
active member of that organisation".

```sh
jennifer run bin/deckadmin register-namespace acme \
    --owner 77777 --login acme-inc --org
```

`--owner` is then the **organisation's** numeric id, not a person's. Anyone the
organisation actively includes can publish under the scope, and anyone it removes
stops being able to - with no list for an operator to maintain. Pending
invitations and billing managers are excluded and always will be.

The cost, stated plainly: memberships are read **at login** and carried in the
registry's own token, because the provider token is discarded immediately after
(8.4) and there is nothing left to ask with. A refresh reissues them without
renewing the timestamp, so somebody removed from an organisation keeps write
access until their token ages out rather than instantly.

Implemented for GitHub. The other identity modules return no memberships, which
makes an organisation scope unwritable there rather than writable by anybody.

#### Co-owners

A scope has **one owner and any number of co-owners**. A co-owner publishes and
yanks under the scope exactly as the owner does; what they do not do is become
the scope's identity, so `register-namespace` remains the way to hand a scope on.

```sh
jennifer run bin/deckadmin add-owner acme 67890
jennifer run bin/deckadmin remove-owner acme 67890
```

The argument is the **principal id**, not a login - the same rule as everywhere
else, so a rename never moves who may write. Co-owners live under the scope's own
provider; the same numeric id at a different provider is a different person and
is refused.

Two guards, both deliberate:

- **A reserved scope cannot take a co-owner.** There is no owner to co-own with,
  and accepting one would leave a scope nobody holds that somebody can write to.
  Grant it first.
- **The owner cannot be removed this way.** Losing the last owner would leave
  decks nobody can yank. Reassign with `register-namespace` instead.

Note what this is *not* for: letting a whole team publish rarely needs co-owners
at all. A **CI token** scoped to the namespace, or a **trusted publisher** per
deck, lets many people and pipelines publish without anyone holding a second
administrative credential. Reach for a co-owner when somebody needs to *manage*
the scope, not merely publish under it.

#### Handing a reserved scope to somebody

Reserving holds a name; it does not retire it. A reserved scope is simply
**registered with no owner**, so the same command that grants any scope hands it
over:

```sh
jennifer run bin/deckadmin register-namespace jennifer --owner 12345 --login mplx
```

That is how `@jennifer`, `@official`, or any other held name becomes publishable:
an operator decides who gets it, and from that moment the ordinary ownership
rules apply. `reserve-defaults` will not take it back afterwards - it reports the
scope as owned and leaves it alone.

`namespaces` shows which is which, with `--owned` and `--reserved` to filter,
because a registry that has reserved the defaults holds scores of names and the
useful entries would otherwise be buried:

```
namespaces: 1 owned, 75 reserved
  @jennifer  mplx [github 12345]
  @admin  (reserved, no owner)
```

#### `reserve-defaults`

Registers every scope in `src/reserved.j` as operator-held, so no self-service
claim can take one. Run it on a fresh registry before it is public, and again
whenever the list grows.

Idempotent, and it **never seizes a scope somebody already owns** - it reports
the conflict and leaves it alone. `--dry-run` prints the plan without writing.

The list holds names that would mislead a reader whoever owns them: `official`,
`admin`, `security`, `api`, `www`, the project's own names, and placeholders like
`test` and `example`.

**Brand names are not on it.** Under the `derived` claim policy, `@microsoft` can
only be claimed by the account called `microsoft`, so the identity provider has
already answered the question; a brand list has no natural edge and would imply
this registry adjudicates trademarks, which it does not. Disputes go through the
operator path instead.

#### `mint-token`

| Flag | Default | Means |
| ---- | ------- | ----- |
| `--deck <name>` | none | narrow it to one deck within the scope |
| `--name <label>` | `ci` | a label, shown in listings |
| `--days <n>` | `90` | how long it lives (`0` = never) |

The **fallback** for non-interactive publishing, where trusted publishing (8.9)
is unavailable: a laptop, a cron job, a CI system that mints no identity token.
Prefer `trust` where you can - a credential that does not exist cannot leak.

The scope must already be owned, for the reason `trust` requires it: a token is a
delegated credential, and a reserved scope has nobody to delegate for. Minting
one there is refused at the mint rather than at the publish, because a secret
that can never authorise anything is worse than none - it fails later, and
somewhere else.

The token is printed **once** and never stored; only its SHA-256 is kept, so a
lost token is replaced rather than recovered. It expires by default, because a
token nobody remembers is the one that leaks, and `--days 0` has to be asked for.
Present it as `Authorization: Bearer jvcp_...`; the prefix is what tells it apart
from a login token, and what lets a secret scanner spot one in a public
repository.

`tokens` shows when each was last used, which is how an unused one gets found and
retired. `revoke-token` drops one without disturbing the others.

#### `yank`

Withdraws a version from **new** resolutions. It stays fetchable, so a lockfile
that already pins it keeps installing; that is the difference between yanking and
deleting, and why deletion is not offered. Reversible with `unyank`.

Also available over HTTP as `POST /yank` and `POST /unyank` for the scope owner.

#### `register-namespace`

| Flag | Default | Means |
| ---- | ------- | ----- |
| `--owner <subject>` | none | the principal the scope binds to |
| `--provider <name>` | `github` | which identity provider issued that subject |
| `--login <name>` | none | the owner's username, kept as a display label |
| `--org` | off | the owner is an organisation; authorise by live membership (8.7) |

This is the **operator grant** of section 8.2, and it bypasses the policy on
purpose: it is how a deployment covers what self-service derivation cannot - an
organisation, a name the provider does not have, a dispute, a departure.

With `--owner` it grants. **Without `--owner` it reserves**: the scope is
registered, so nobody can claim it, and bound to nobody, so nobody can publish
under it either.

Re-running it on a scope that already exists **reassigns** it. That is
deliberate and it is the only way a scope changes hands, so it is worth being
sure before running it.

#### `trust`

| Flag | Default | Means |
| ---- | ------- | ----- |
| `--provider <name>` | `github-actions` | `github-actions`, `gitlab-ci`, or `gitea-actions` |
| `--repository <path>` | none | the repository path, a display label |
| `--workflow <path>` | none | the workflow file permitted to publish |
| `--refs <pattern>` | `refs/tags/*` | which refs may publish |

This is how a package is published **from CI with no stored credential**
(specification 8.9). The workflow presents the identity token its CI system mints
for the job; the registry verifies it against the issuer's keys and matches its
claims to this binding.

**The positional is the repository *id*, not its path** - the immutable numeric
one the forge assigns. A path can be renamed and the freed path registered by
somebody else, exactly as a username can, so a binding on the path would follow
the name rather than the project. Find it with:

```sh
gh api repos/acme/deck-routeros --jq .id
```

The scope must already be owned: a binding is a standing grant to write under it,
so it is gated exactly as a publish is. A binding on a deck with no versions is
**pending** until the first publish, which is what solves the ordering problem of
a deck that does not exist yet.

`--workflow` and `--refs` are what stop *any* job in that repository publishing.
Without a workflow, a pull-request build proposed by a contributor runs with the
same repository identity as the release job.

`--owner` and `revoke` both take the **subject identifier** the identity
provider issued - a numeric id on GitHub - and not a login, because a login can
be renamed or released to somebody else while the subject cannot.

```sh
# @acme belongs to GitHub user 1234567, whatever they call themselves later
jennifer run bin/deckadmin register-namespace acme --owner 1234567 --login alice

# hold @jennifer against anybody claiming it
jennifer run bin/deckadmin register-namespace jennifer
```

`revoke` takes the **subject identifier** the identity provider issued, not a
login, because that is what ownership binds to. It drops every refresh token that
subject holds, so the holder cannot mint new bearer tokens; the bearer tokens
already issued are signed and stateless, so they expire on their own within
`TOKEN_TTL`.

### Running against something other than GitHub

A private registry usually delegates identity to its own SSO and hosts code on
its own forge, and those are **two independent choices**
([specs-server.md](/specs/specs-server.html) section 12):

| Role | Answers | Examples |
| ---- | ------- | -------- |
| identity provider | who is this caller, stably? | GitHub (default), Authelia, GitLab, Gitea, Forgejo, any OIDC provider |
| forge | what is in this repository, and who may push? | GitHub (default), GitLab, Gitea, Forgejo |

On `github.com` one service plays both roles, which is why the defaults look like
a single setting. Inside an organisation they are usually different services, and
the registry must be told about each.

Two consequences worth planning for before deploying:

- **Scopes should be operator-granted, not derived.** Derived claiming exists to
  stop strangers squatting names; inside an organisation there are no strangers,
  and an operator-granted namespace maps onto teams rather than onto whichever
  username somebody happens to hold. Section 12.5 makes the policy configurable
  and recommends `operator` for private deployments.
- **Source authority needs a route to the forge.** When identity and forge are
  different services, the registry holds a token the forge will not accept, so it
  cannot ask "may this caller push here" without being configured for it: a forge
  service account, a per-user linked forge identity, or an explicit decision to
  record sources as unverified. Section 12.4 sets out the three, and warns
  against the tempting shortcut of matching display names.

The intended shape is one module per provider, `src/identity/<name>.j` and
`src/forge/<name>.j`, each exporting a `provider()` that returns a struct of
`func` values the core calls without knowing which module supplied them. Two
consequences worth knowing before adding one:

- **Self-hosted is configuration, not a new module.** GitLab, Gitea, and Forgejo
  self-hosted speak the same API as their hosted counterparts and differ only in
  base URL, so there is one module per API *family*. Forgejo is a Gitea fork and
  needs none of its own. A generic OIDC module covers Authelia and anything else
  standards-compliant, so a bespoke module is worth writing only where a service
  deviates from the standard.
- **A pair carries policy, and policy may only subtract.** It may narrow the name
  grammar, choose a claim policy, and reserve names. It may never widen section
  2.1, because a name outside it produces records a conforming client cannot
  install.

None of this is implemented yet. The identity surface that exists today is
GitHub-only and not yet behind the interface, and the operator tool grants
namespaces without recording an owner at all.

The grammar is declared once, with [`args`](https://jennifer-lang.dev/), so the
help text is generated rather than maintained by hand. `--help` works at both
levels:

```sh
jennifer run bin/deckadmin --help         # the subcommands
jennifer run bin/deckadmin add --help     # add's positionals and flags
```

The process exits non-zero when a command fails, so it composes in a script. A
malformed command line (an unknown flag, a missing positional, a bad value) is
reported the same way, before anything touches the store.

### Flags for add and update

| Flag | Meaning |
| ---- | ------- |
| `--ref <tag>` | the tag this version was published from (git) |
| `--commit <sha>` | the full 40-character lowercase SHA that tag pointed at (git) |
| `--checksum sha256:<hex>` | the digest of the uploaded artifact (tar.gz) |
| `--requires "dep constraint, ..."` | this version's runtime dependencies |
| `--engines "engine range, ..."` | the interpreters that can run it |
| `--capabilities "net, exec"` | the host capabilities its code needs |

Flags may appear anywhere; they are stripped before the positional arguments are
read, so `[description]` keeps its place whatever precedes or follows it. In
`--requires` and `--engines`, each comma-separated entry is a `name constraint`
pair separated by a space, and an entry with no space defaults to `*`.

### The two delivery kinds

Which pin you supply selects the kind, and supplying the wrong one is an error
rather than a silent no-op.

**`git`, the normal case.** Pass `--ref` and `--commit` together. The commit is
the integrity boundary: git verifies object hashes on fetch, so the commit that
arrives is the commit that was published, and no checksum is recorded. The tag is
kept for display and provenance only. Because the commit is what the registry
hands out, force-pushing that tag afterwards changes nothing for consumers.

```sh
jennifer run bin/deckadmin add @acme/routeros 0.1.0 \
    https://github.com/acme/deck-routeros.git \
    --ref v0.1.0 --commit 9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293 \
    "MikroTik RouterOS client" \
    --requires "@acme/net ^1.0.0" \
    --engines "jennifer >=0.24.0" \
    --capabilities "net"
```

An abbreviated SHA is rejected: a version is pinned to the whole hash, and a
short prefix can turn ambiguous as a repository grows.

**`tar.gz`, for an uploaded artifact.** Pass `--checksum` instead. Those bytes
are stable because somebody uploaded them, so the digest is meaningful and is
verified before unpacking.

```sh
jennifer run bin/deckadmin add @acme/routeros 0.1.0 \
    https://example.com/routeros-0.1.0.tar.gz \
    --checksum sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 \
    "MikroTik RouterOS client"
```

Do not point a `tar.gz` version at a GitHub-generated source tarball. Those
bytes are not stable over time, so a digest over one is a pin that can stop
matching without anybody changing anything. Publish such a deck as `git`.

### Scopes

Every registry deck is scoped, as `@scope/deck`. A bare name is a module bundled
with the interpreter or a local file, so `add` rejects it.

A scope must be registered before anything can publish under it:

```sh
jennifer run bin/deckadmin register-namespace acme     # or @acme
jennifer run bin/deckadmin namespaces
```

Registration is idempotent, and it is the operator's grant. The specification
describes deriving scope ownership from a GitHub account instead, which would
retire this step; see [specs-server.md](/specs/specs-server.html) section 8.

## Docker

```sh
REGISTRY_UID=$(id -u) REGISTRY_GID=$(id -g) docker compose up -d --build
docker compose logs -f
docker compose exec jvc jennifer run bin/deckadmin list
docker compose down
```

The image builds on the official interpreter image,
`ghcr.io/jennifer-language/jennifer`, whose module library already ships
everything this app imports (`webapi`, `args`, `html`, `http`, `web`, `flatdb`,
`semver`), so imports resolve with no `-I` flag and nothing needs adding. The
documentation is rendered in its own stage.

### Who the container runs as

The database is bind-mounted from `./data`, so it is readable on the host and
survives a rebuild. That makes the container's user id matter:

**A bind mount keeps the host's ownership.** The container process is just a
numeric uid to the kernel, so if it does not match the host directory's owner,
every write is denied. And because `store.save` is crash-atomic it writes a temp
file *beside* the target, so the **directory** must be writable, not merely the
file. Getting this wrong looks like:

```
fs.writeString: /app/data/decks.json.tmp.59fcd1d6-...: permission denied
```

Two build arguments set the runtime user:

| Argument | Default | Meaning |
| -------- | ------- | ------- |
| `UID` | `10001` | the uid the server runs as |
| `GID` | `999` | its gid |

The Dockerfile defaults are the base image's own `jennifer` user, which is right
for a **named volume**: Docker initialises one from the image, so ownership
matches by construction. Compose passes `${REGISTRY_UID:-1000}` / `${REGISTRY_GID:-1000}`
instead, because it bind-mounts.

```sh
REGISTRY_UID=$(id -u) REGISTRY_GID=$(id -g) docker compose up -d --build
```

Put them in a `.env` beside `docker-compose.yml` to avoid repeating them.

**They are not called `UID` and `GID` at the compose level on purpose.** Bash
makes `UID` readonly and does not export it, so `${UID}` in a compose file
resolves to nothing and would silently take the default, which is the same
failure with an extra layer of confusion on top.

The uid need not name an account inside the container: the `USER` is numeric, so
any host id works without creating a passwd entry for it.

Two things to know before changing the base:

- **The `dev` tag is deliberate.** Every `.j` file here declares
  `pragma-jennifer-version: >=0.25.0`, and so does the bundled `webapi` module.
  The newest release tag is 0.24.0, which a release build compares against and
  refuses; a dev build bypasses the floor. Move to a release tag as soon as one
  satisfies the pragma.
- **`dev` is a moving tag.** Build with `--pull`, or a stale local copy is used
  silently: `docker run` does not re-check a tag it already has, and an older
  `dev` predates `webapi`.

There is no `curl` in that base image, so the container healthcheck is
`bin/healthcheck`, which polls `/health` and exits non-zero when it does not
answer. `REGISTRY_HEALTHURL` overrides the URL it probes.
