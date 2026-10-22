# The executables

Three Jennifer programs live in `bin/`, with no `.j` extension and run through
their shebangs. They are thin: they read the environment, call a module in
`src/`, and print the result. The logic and the tests are in the modules.

| | |
| - | - |
| `bin/serve` | the HTTP server and website, over `src/apiview.j` and `src/webview.j` |
| `bin/deckadmin` | the operator CLI, over `src/admin.j` |
| `bin/healthcheck` | the container's health probe, not run by hand |

`bin/entrypoint.sh` is the container's shell entrypoint (see Docker below).

`serve` and `deckadmin` read the same database, so `deckadmin` edits show up in
the server without a restart: the server re-parses the file when its mtime or
size changes, and at least every 30 seconds.

## Configuration

Settings come from three places, each overriding the one before:

1. built-in defaults: a read-only, plain-HTTP registry
2. `config.toml` (or `$REGISTRY_CONFIG`), if present
3. the environment

The file describes the deployment; the environment varies one instance or
injects a secret without editing a file into an image. `config.toml.example`
documents every key beside the variable that overrides it.

An environment variable set to an empty string counts as unset, so a stray blank
cannot erase what the file configured. Booleans are the exception and parse
their value (`1 true yes on` / `0 false no off`), so that `0` can switch off
what the file switched on.

Every variable `serve` and `deckadmin` read can instead be given as
`<NAME>_FILE`, naming a file that holds the value (trimmed), the way Docker and
Kubernetes mount secrets. The plain variable wins over `_FILE`, which wins over
the legacy `JVC_*` name.

A configuration that cannot be served is refused at startup with the reason.

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

`agreeTos` defaults to `false`: accepting a CA's terms is the operator's
decision.

**Port 80 must reach the plain listener from the internet.** The CA connects
there for the challenge, so the plain listener is not a redirect to HTTPS. It
starts first and stays up, so the registry keeps serving while a certificate is
obtained or renewed.

**Use the staging directory first.** It issues untrusted certificates with far
higher rate limits; production limits are per registered domain per week, and a
misconfigured deployment can exhaust them. The registry logs at boot when it is
pointed at staging, since otherwise the first sign is a browser warning.

```
REGISTRY_ACME_DIRECTORY=https://acme-staging-v02.api.letsencrypt.org/directory
```

Renewal is decided from the recorded issue time, `renewBeforeDays` before the
90 day lifetime expires, and is checked **only at startup**: a long-running
server does not renew, so restart it within that window. A renewal that fails
while a certificate is still on disk serves the stored one, without logging the
failure; a failed first issuance leaves the registry on plain HTTP with an
`error` in the log.

## Environment

> **Renamed.** These variables were `JVC_*`, which collided with the `jvc`
> client on a host running both. The old names are still read and warn on use;
> a later version will stop reading them. They are not ignored because an unset
> variable falls back to a default, and a configured deployment would serve a
> different database instead of failing.
>
> `JVC_TOKEN` is unaffected: it belongs to the client.

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
| `REGISTRY_MAX_IN_FLIGHT` | `32` | `serve` | requests worked on at once (below) |
| `REGISTRY_RESPOND_TIMEOUT` | `120` | `serve` | seconds before the server answers `503` itself (below) |
| `REGISTRY_SOURCE_AUTHORITY` | chosen | `serve` | how a publish proves push access: `login` or `service` (below) |
| `REGISTRY_TRUSTPUB_AUDIENCE` | unset | `serve` | the `aud` a CI token must carry; gates trusted publishing |
| `REGISTRY_TRUSTPUB_PROVIDER` | `github-actions` | `serve` | `github-actions`, `gitlab-ci`, or `gitea-actions` |
| `REGISTRY_TRUSTPUB_ISSUER` | per provider | `serve` | the OIDC issuer, required for anything self-hosted |

The server's console always receives the log as human-readable text; the file
is an extra copy and the only one that survives a restart. Both binaries write
to the same file: the server never sees a publish and `deckadmin` never sees a
request. Nothing rotates it; point logrotate at it.

**Behind a proxy the access log records the proxy** unless you name the header
carrying the real address. Unset is the safe default: the connection's peer
cannot be forged, a header can be sent by anybody. Name one only if something in
front of the registry sets it and strips any client-supplied copy; otherwise the
audit log records what callers claim.

Behind Cloudflare use `CF-Connecting-IP`, which Cloudflare overwrites on every
request, so it survives any number of hops. Behind one proxy alone use
`X-Forwarded-For`; the last entry is taken, the address that proxy saw. The
first entry is the client only when every proxy strips what the client sent,
and a proxy that appends (the usual setting) leaves a forged one in front.

`REGISTRY_LOG_REQUESTS` is separate from the level because an access log is wanted at
`info` far more often than the rest of `debug`, and a container with a 30-second
health probe otherwise fills its log with probes.

**`REGISTRY_IDENTITY_CLIENTID` and `REGISTRY_TOKEN_KEY` gate the login surface.**
Set both and the registry serves the token exchange, `POST /claim`, `/owners`,
`/yank` and `/unyank`, and advertises them; leave either unset and those routes
are not registered, no `auth` object appears in the discovery document, and a
client reports that this registry accepts no logins. `POST /publish` is served
either way, but without logins it accepts only trusted publishing and CI tokens.

`REGISTRY_TOKEN_KEY` is a secret of at least 32 characters (`openssl rand -hex 32`;
a shorter one is refused at boot). Changing it invalidates every outstanding
bearer token at once, the remedy if one leaks.

**`REGISTRY_TRUSTPUB_AUDIENCE` gates publishing from CI** (specification 8.9). Set it
and `POST /publish` accepts a CI identity token in place of a bearer token, and
the discovery document advertises the audience so a job knows what to ask its CI
system for. It is not a secret, but it must be specific to this registry (its
hostname, for example) so that a token minted for another service is refused.

The issuer's key set is fetched once at boot and held for the process, so a key
rotation needs a restart. Fetching per request would add two round trips to
every publish and make the registry unavailable whenever the issuer is.

`REGISTRY_FORGE*` configures how a publish reads a repository: resolving a tag to a
commit and reading `deck.toml` at it. Identity and forge are configured
separately; they coincide only on `github.com`.

A missing database file opens as an empty registry, so a first run needs no seed
file.

## serve

```sh
jennifer serve bin/serve
REGISTRY_DB=/srv/registry.json REGISTRY_ADDR=:9000 jennifer serve bin/serve
```

It serves the JSON routes in [api.md](api.md) and the website below. The write
routes are `POST /publish` (always served), and `POST /claim`, `/owners`,
`/yank`, `/unyank` and the token exchange (served only when logins are
configured); everything else an operator changes goes through `deckadmin` on the
server's filesystem.

### Sizing: requests in flight

Every read shares one parsed copy of the database, parsed again only when the
file changes (and at least every 30 seconds). A copy takes about **4 times the
database file's size** in memory (measured: a 3.9 MB file of 5,000 decks is about
15 MB), so concurrent lookups cost little. Every listing and search reads one
shared deck index built from that copy, once per change of the file: at 5,000
decks building it takes about 0.7 seconds, and the request that triggers it
waits that long while the others wait for its copy. Listing pages show 100 decks
at a time (`?page=`).

`REGISTRY_MAX_IN_FLIGHT` (`maxInFlight` in `config.toml`, default 32) bounds how
many requests are handled at once; a request beyond the limit waits rather than
being refused. A publish holds its place through its forge calls, so the default
is not lower. Measured at 5,000 decks: with 8 in flight, twenty
concurrent `/browse` requests peaked at about 0.2 GB; with 32, sixty-four
concurrent `/browse` requests at about 0.3 GB and sixty-four searches for a term
matching every deck at about 0.5 GB. A page of a listing answers in 10 to 50 ms
once the index is built.

**Slow uploads do not hold a place.** The HTTP engine reads a request's body
before the request takes one of the `maxInFlight` places, and answers `408` to
a body that has not arrived within 10 seconds, so connections that trickle a
body cannot stall other requests (measured: 40 such connections with the limit
at 8 left health checks answering at once). Interpreters before
0.24.0-dev+167 take the place first, and there 8 such connections stop the
server; run those behind a buffering reverse proxy.

A request not answered within `REGISTRY_RESPOND_TIMEOUT` seconds (default 120)
is answered `503` by the HTTP engine, so a limit set too low for the load shows
up as slow pages first and as those errors after. Keep the timeout above the
slowest publish, which waits on several forge calls of up to 10 seconds each. A
publish still waiting on its forge when the timeout passes is dropped, not
recorded, and the operational log says so.

Repeat reads of pages and listings are answered `304 Not Modified` from a tag of
the database file without parsing it, so a browser or caching proxy in front
costs nothing until the registry changes.

### The website

Read-only: no form that writes anything, no session, no account UI.

| Route | Is |
| ----- | -- |
| `/` | search, links to `/browse` and `/tags`, and the deck count (HTML), or the service index (JSON) |
| `/search?q=` | results (HTML), or the JSON result set |
| `/browse` | every deck, 100 to a page (`?page=`) |
| `/tags`, `/tag/<keyword>` | the keywords in use, and the decks carrying one |
| `/scope/<name>` | the decks under one scope |
| `/deck/<scope>/<deck>` | a deck page: versions, pins, dependencies, engines, capabilities |
| `/manual/` | the user manual: finding, using, and publishing decks |
| `/reference/` | these pages, rendered |
| `/specs/` | the server and client specifications |

`/` and `/search` pick their format from the request's `Accept` header, so a
browser and a client can share one URL. Deck pages sit under `/deck/` because
`/decks/:name/:version` belongs to the JSON API and would match a two-segment
scoped deck page as a name plus a version.

The three static sections are three
[Grimoire](https://github.com/jennifer-language/grimoire) books; grimoire builds one source directory into one output
directory. Each output directory must be named for the URL it serves at, because
`web.serveDir` joins the whole request path onto the static root.

| Source | Config | Served from | At |
| ------ | ------ | ----------- | -- |
| `manual/` | `grimoire-manual.toml` | `public/manual/` | `/manual/` |
| `reference/` | `grimoire.toml` | `public/reference/` | `/reference/` |
| `specs/` | `grimoire-specs.toml` | `public/specs/` | `/specs/` |

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

`public/` is gitignored, and the container image builds all three books in its own
stage, so no rendered copy is committed or shipped stale. A deployment that has
not built a section answers it with a page naming the command that produces it.

`--clean` empties the output directory first. Grimoire defaults to `--no-clean`,
so without it a deleted or renamed page keeps serving under its old URL.

## deckadmin

```sh
jennifer run bin/deckadmin [logging flags] <command> [args]
```

### Logging flags

These are root flags and go before the command, where the argument parser
resolves them. `deckadmin --log x.log add ...` works;
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
by default because `deckadmin` already prints a result line; turn it on to read
the structured form.

The file is the same one the server appends to. The server never sees a publish
and `deckadmin` never sees a request, so only the shared file shows both.

| Command | Does |
| ------- | ---- |
| `add <deck> <version> <url> [description] [flags]` | publish a version (an upsert; see below) |
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
| `reserve-defaults [-n\|--dry-run]` | hold every reserved scope so nobody can claim one |
| `keywords [words...]` | print the refused-keyword list decoded, or encode terms for it |
| `mint-token <scope> [flags]` | mint a CI token, shown once (8.10) |
| `tokens` | list CI tokens and when each was last used |
| `revoke-token <fingerprint>` | revoke one CI token |
| `yank <deck> <version>` | withdraw a version from new resolutions |
| `unyank <deck> <version>` | restore a withdrawn version |
| `revoke <accountId>` | invalidate an identity's refresh tokens |

#### Organisation scopes

`--org` marks the owner as an organisation rather than a person. Every later
write then asks whether the caller is an active member of that organisation.

```sh
jennifer run bin/deckadmin register-namespace acme \
    --owner 77777 --login acme-inc --org
```

`--owner` is then the organisation's numeric id. Active members can publish
under the scope and removed members cannot, with no list for an operator to
maintain. Pending invitations and billing managers are excluded.

Memberships are read at login and carried in the registry's own token; nothing
asks the provider again. Where the provider token is kept, it is sealed and used
only to ask whether the caller may push to the repository they publish from,
never to re-read memberships. A refresh reissues them without renewing the
timestamp, so somebody removed from an organisation keeps write access until
their token ages out.

Implemented for GitHub. The other identity modules return no memberships, which
makes an organisation scope unwritable there rather than writable by anybody.

#### Co-owners

A scope has one owner and any number of co-owners. A co-owner publishes and
yanks under the scope as the owner does but does not become the scope's
identity; `register-namespace` remains the way to hand a scope on.

```sh
jennifer run bin/deckadmin add-owner acme 67890
jennifer run bin/deckadmin remove-owner acme 67890
```

The argument is the principal id, not a login, so a rename never changes who may
write. Co-owners live under the scope's own provider; the same numeric id at a
different provider is a different person and is refused.

- **A reserved scope cannot take a co-owner.** There is no owner to co-own with,
  and accepting one would leave a scope nobody holds that somebody can write to.
  Grant it first.
- **The owner cannot be removed this way.** Losing the last owner would leave
  decks nobody can yank. Reassign with `register-namespace` instead.

The scope's owner can also add and remove co-owners itself, through
`POST /owners` (`jvc owners`). A co-owner cannot: one compromised account could
otherwise add others that outlive its own removal, or remove the rest.

Reassigning a scope to a different owner drops its CI tokens and trusted
publishers, since the old owner granted them; the new owner mints and binds
their own. Re-granting to the same owner keeps them. Removing a deck removes
its trusted publisher too.

A team that only needs to publish rarely needs co-owners: a CI token scoped to
the namespace, or a trusted publisher per deck, lets people and pipelines
publish without a second administrative credential. Add a co-owner when somebody
needs to manage the scope.

#### Handing a reserved scope to somebody

A reserved scope is registered with no owner, so the command that grants any
scope hands it over:

```sh
jennifer run bin/deckadmin register-namespace jennifer --owner 12345 --login mplx
```

This makes `@jennifer`, `@official`, or any other held name publishable; from
then on the ordinary ownership rules apply. `reserve-defaults` does not take
it back; it reports the scope as owned and leaves it alone.

`namespaces` shows which is which; `--owned` and `--reserved` filter, since a
registry that has reserved the defaults holds scores of names:

```
namespaces: 1 owned, 75 reserved
  @jennifer  mplx [github 12345]
  @admin  (reserved, no owner)
```

#### `reserve-defaults`

Registers every scope in `src/reserved.j` as operator-held, so no self-service
claim can take one. Run it on a fresh registry before it is public, and again
whenever the list grows.

Idempotent. It never seizes a scope somebody already owns; it reports the
conflict and leaves it. `--dry-run` prints the plan without writing.

The list holds names that would mislead a reader whoever owns them: `official`,
`admin`, `security`, `api`, `www`, the project's own names, and placeholders like
`test` and `example`.

Brand names are not on it. Under the `derived` claim policy, `@microsoft` can
only be claimed by the account called `microsoft`, so the identity provider
decides; a brand list has no clear edge and would imply that this registry
adjudicates trademarks. Disputes go through the operator path.

#### `mint-token`

| Flag | Default | Means |
| ---- | ------- | ----- |
| `--deck <name>` | none | narrow it to one deck within the scope |
| `--name <label>` | `ci` | a label, shown in listings |
| `--days <n>` | `90` | how long it lives (`0` = never) |

The fallback for non-interactive publishing where trusted publishing (8.9) is
unavailable: a laptop, a cron job, a CI system that mints no identity token.
Prefer `trust` where possible; a credential that does not exist cannot leak.

The scope must already be owned, as for `trust`: a token is a delegated
credential, and a reserved scope has nobody to delegate for. The mint is
refused, so the failure does not surface later at a publish.

The token is printed once and never stored; only its SHA-256 is kept, so a lost
token is replaced, not recovered. It expires by default, since a forgotten token
is the one that leaks; `--days 0` must be asked for. Present it as
`Authorization: Bearer jvcp_...`; the prefix distinguishes it from a login token
and lets a secret scanner find one in a public repository.

`tokens` shows when each was last used, so unused ones can be found and retired.
`revoke-token` drops one without disturbing the others.

A CI token is name authority only (specification 8.10): it says the holder may
publish under the scope, and nothing about the repository. A publish with one is
still checked for push access against the account it acts for: the minting
account where the token records one, otherwise the scope's owner. So an
operator-minted token needs an owner who can push to the repository and, in
`login` mode, who has logged in since credentials were kept. An organisation
scope has no person as its owner, so a token for one cannot pass this check.

#### `yank`

Withdraws a version from new resolutions. It stays fetchable, so a lockfile that
already pins it keeps installing; for that reason deletion is not offered.
Reversible with `unyank`.

Also available over HTTP as `POST /yank` and `POST /unyank` for the scope owner.

#### `register-namespace`

| Flag | Default | Means |
| ---- | ------- | ----- |
| `--owner <subject>` | none | the principal the scope binds to |
| `--provider <name>` | `github` | which identity provider issued that subject |
| `--login <name>` | none | the owner's username, kept as a display label |
| `--org` | off | the owner is an organisation; authorise by live membership (8.7) |

The operator grant of section 8.2. It bypasses the policy, to cover what
self-service derivation cannot: an organisation, a name the provider does not
have, a dispute, a departure.

With `--owner` it grants. Without `--owner` it reserves: the scope is
registered, so nobody can claim it, and bound to nobody, so nobody can publish
under it.

Re-running it on an existing scope **reassigns** it. This is the only way a
scope changes hands.

#### `trust`

| Flag | Default | Means |
| ---- | ------- | ----- |
| `--provider <name>` | `github-actions` | `github-actions`, `gitlab-ci`, or `gitea-actions` |
| `--repository <path>` | none | the repository path, a display label |
| `--workflow <path>` | none | the workflow file permitted to publish |
| `--refs <pattern>` | `refs/tags/*` | which refs may publish |

Publishing from CI with no stored credential (specification 8.9). The workflow
presents the identity token its CI system mints for the job; the registry
verifies it against the issuer's keys and matches its claims to this binding.

**The positional is the repository id, not its path**: the immutable numeric id
the forge assigns. A path can be renamed and the freed path registered by
somebody else, as a username can, so a binding on the path would follow the name
rather than the project. Find it with:

```sh
gh api repos/acme/deck-routeros --jq .id
```

The scope must already be owned: a binding is a standing grant to write under it,
so it is gated as a publish is. A binding on a deck with no versions is
**pending** until the first publish, so a deck can be bound before it exists.

`--workflow` and `--refs` stop other jobs in that repository from publishing.
Without a workflow, a pull-request build proposed by a contributor runs with the
same repository identity as the release job.

`--owner` and `revoke` both take the subject identifier the identity provider
issued (a numeric id on GitHub), not a login, because a login can be renamed or
released to somebody else while the subject cannot.

```sh
# @acme belongs to GitHub user 1234567, whatever they call themselves later
jennifer run bin/deckadmin register-namespace acme --owner 1234567 --login alice

# hold @jennifer against anybody claiming it
jennifer run bin/deckadmin register-namespace jennifer
```

`revoke` drops every refresh token the subject holds, so the holder cannot mint
new bearer tokens; bearer tokens already issued are signed and stateless and
expire on their own within an hour (`TOKEN_TTL` in `bin/serve`).

### Running against something other than GitHub

A private registry usually delegates identity to its own SSO and hosts code on
its own forge. These are two independent choices
([specs-server.md](/specs/specs-server.html) section 12):

| Role | Answers | Examples |
| ---- | ------- | -------- |
| identity provider | who is this caller, stably? | GitHub (default), Authelia, GitLab, Gitea, Forgejo, any OIDC provider |
| forge | what is in this repository, and who may push? | GitHub (default), GitLab, Gitea, Forgejo |

On `github.com` one service plays both roles, so the defaults look like a single
setting. Inside an organisation they are usually different services, and the
registry must be configured for each.

Before deploying:

- **Scopes should be operator-granted, not derived.** Derived claiming stops
  strangers squatting names; inside an organisation there are none, and an
  operator-granted namespace maps onto teams rather than onto usernames.
  Section 12.5 makes the policy configurable and recommends `operator` for
  private deployments.
- **Source authority needs a route to the forge.** Every publish by a person or
  a CI token asks the forge whether that account may push to the repository
  (specification 7.1, route A), and refuses unless the answer is yes.
  `REGISTRY_SOURCE_AUTHORITY` (`forge.sourceAuthority`) says how:

  | Value | Asks with | Use when |
  | ----- | --------- | -------- |
  | `login` | the caller's own provider token, kept **sealed** from their login | identity and forge are one service |
  | `service` | `REGISTRY_FORGE_TOKEN`, about the caller's **username** | identity and forge differ but share one user directory |

  Unset, it is `login` when identity and forge are the same service (same
  provider family and base URL) and `service` otherwise. The server refuses to
  start with `login` across two services, or with `service` and no forge token.

  In `login` mode the token is sealed with AES-256-GCM under a key derived from
  `REGISTRY_TOKEN_KEY`, replaced at each login, never returned, and dropped by
  `revoke`. Rotating the signing key makes every kept token unreadable, so those
  accounts are asked to log in again. Accounts that logged in before tokens were
  kept are in the same position.

  In `service` mode the caller's login is taken as their forge username. That
  holds only when both services read one directory (one LDAP or OIDC source),
  which the operator asserts: section 12.5 forbids matching display names that
  merely look alike. The forge token must see every repository decks are
  published from.

There is one module per provider, `src/identity/<name>.j` and
`src/forge/<name>.j`, each exporting a `provider()` that returns a struct of
`func` values the core calls without knowing which module supplied them. Before
adding one:

- **Self-hosted is configuration, not a new module.** GitLab, Gitea, and Forgejo
  self-hosted speak the same API as their hosted counterparts and differ only in
  base URL, so there is one module per API family. Forgejo is a Gitea fork and
  needs no module of its own. A generic OIDC module covers Authelia and anything
  else standards-compliant; write a bespoke module only for a service that
  deviates from the standard.
- **A pair carries policy, and policy may only subtract.** It may narrow the name
  grammar, choose a claim policy, and reserve names. It may never widen section
  2.1, because a name outside it produces records a conforming client cannot
  install.

The identity modules for GitHub, GitLab, Gitea, and generic OIDC, and the forge
modules for GitHub, GitLab, and Gitea, exist behind that interface. Organisation
memberships are read from GitHub only; the others report none.

The grammar is declared once with [`args`](https://jennifer-lang.dev/), which
generates the help text. `--help` works at both levels:

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

`add` over an existing version replaces the whole record: a `yanked` flag, and
the licence and keywords a `POST /publish` recorded, are reset, so re-add a
yanked version only to restore it.

### The refused-keyword list: `keywords`

With no arguments, prints the refused-keyword list decoded, by group. With
terms, prints each folded and base64-encoded, ready to paste into
`src/keywords.j`, and says whether it is already refused. It reads no registry
and takes no lock.

### The two delivery kinds

The pin supplied selects the kind; supplying the wrong one is an error.

**`git`, the normal case.** Pass `--ref` and `--commit` together. The commit is
the integrity boundary: git verifies object hashes on fetch, so the commit that
arrives is the commit that was published, and no checksum is recorded. The tag is
kept for display and provenance only. The registry hands out the commit, so
force-pushing the tag afterwards changes nothing for consumers.

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

**A `--ref` shaped like an object id is rejected too**: 7 to 64 hex digits, in
either case. A git ref and a git object id share one syntactic space, so a tag
called `4a3b1c...` is ambiguous with the commit of that id, and wherever a name
is resolved before an object it answers in the commit's place. The fetch then
verifies an object hash correctly, but the object is not the pin. The publish
endpoint refuses such a ref as well, since a record written here is
indistinguishable from one written over HTTP. The commit is the integrity
boundary only if the client asks for the object and checks what it got, which
[the client specification](/specs/specs-client.html) section 4.1.1 requires.

**`tar.gz`, for an uploaded artifact.** Pass `--checksum` instead. Uploaded bytes
are stable, so the digest is meaningful and is verified before unpacking.

```sh
jennifer run bin/deckadmin add @acme/routeros 0.1.0 \
    https://example.com/routeros-0.1.0.tar.gz \
    --checksum sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 \
    "MikroTik RouterOS client"
```

Do not point a `tar.gz` version at a GitHub-generated source tarball. Those
bytes are not stable over time, so a digest over one can stop matching without
anybody changing anything. Publish such a deck as `git`.

### Scopes

Every registry deck is scoped, as `@scope/deck`. A bare name is a module bundled
with the interpreter or a local file, so `add` rejects it.

A scope must be registered before anything can publish under it:

```sh
jennifer run bin/deckadmin register-namespace acme     # or @acme
jennifer run bin/deckadmin namespaces
```

Registration is idempotent and is the operator's grant. The specification also
describes deriving scope ownership from a GitHub account; see
[specs-server.md](/specs/specs-server.html) section 8.

## Docker

```sh
REGISTRY_UID=$(id -u) REGISTRY_GID=$(id -g) docker compose up -d --build
docker compose logs -f
docker compose exec jvc jennifer run bin/deckadmin list
docker compose down
```

The image builds on the official interpreter image,
`ghcr.io/jennifer-language/jennifer`, whose module library ships everything this
app imports (`webapi`, `args`, `html`, `http`, `web`, `flatdb`, `semver`), so
imports resolve with no `-I` flag. The documentation is rendered in its own
stage.

### Who the container runs as

The database is bind-mounted from `./data`, so it is readable on the host and
survives a rebuild.

**A bind mount keeps the host's ownership.** The container process is a numeric
uid to the kernel, so if it does not match the host directory's owner, every
write is denied. `store.save` is crash-atomic and writes a temp file beside the
target, so the directory must be writable, not only the file. The error looks
like:

```
fs.writeString: /app/data/decks.json.tmp.59fcd1d6-...: permission denied
```

Two build arguments set the runtime user:

| Argument | Default | Meaning |
| -------- | ------- | ------- |
| `UID` | `10001` | the uid the server runs as |
| `GID` | `999` | its gid |

The Dockerfile defaults are the base image's `jennifer` user, which suits a
named volume: Docker initialises one from the image, so ownership matches.
Compose passes `${REGISTRY_UID:-1000}` / `${REGISTRY_GID:-1000}` instead,
because it bind-mounts.

```sh
REGISTRY_UID=$(id -u) REGISTRY_GID=$(id -g) docker compose up -d --build
```

Put them in a `.env` beside `docker-compose.yml` to avoid repeating them.

They are not called `UID` and `GID` at the compose level because bash makes
`UID` readonly and does not export it, so `${UID}` in a compose file resolves to
nothing and the default is used without warning.

The uid need not name an account inside the container: the `USER` is numeric, so
any host id works without a passwd entry.

Started as root instead (`user: "0:0"`), `bin/entrypoint.sh` chowns the data
directory to the build-time uid and gid when they differ, then drops to them
before running the interpreter, so the registry never runs as root. Its
variables are `REGISTRY_DATA_DIR` (default `/app/data`) and `REGISTRY_RUN_UID` /
`REGISTRY_RUN_GID`, which the image bakes from the build arguments.

Before changing the base:

- **The image is pinned to the 0.25.0 release.** Every `.j` file here declares
  `pragma-jennifer-version: >=0.25.0`, and so does the bundled `webapi` module,
  so no older release runs it. Move the pin only once the tests pass and the
  server starts on the newer version.
- **`dev` is a moving tag.** A base taken from it needs `--pull`, or a stale
  local copy is used without warning: `docker run` does not re-check a tag it
  already has, and an older `dev` predates `webapi`.

There is no `curl` in the base image, so the container healthcheck is
`bin/healthcheck`, which polls `/health` and exits non-zero when it does not
answer. It probes `http://127.0.0.1:8080/health` and does not follow
`REGISTRY_ADDR`; `REGISTRY_HEALTHURL` overrides the URL.
