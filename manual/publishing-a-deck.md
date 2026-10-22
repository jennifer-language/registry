# Publishing a deck

## What your repository needs

A deck is an ordinary git repository. At the commit you publish, it must contain:

```
deck.toml
src/<deck>.j        the entry module
src/...             anything else your deck imports
template/           optional, used by scaffolding; never vendored
```

The entry module is named after the deck: `@acme/routeros` needs
`src/routeros.j`. Only `src/` is installed into a consumer's vendor tree.

Your `deck.toml` describes the version being published:

```toml
[package]
name = "@acme/routeros"
version = "0.1.0"
description = "MikroTik RouterOS client"
capabilities = ["net"]
keywords = ["router", "mikrotik", "network"]

[engines]
jennifer = ">=0.24.0"

[decks]
"@acme/net" = "^1.0.0"
```

- **`name` must be scoped.** A bare name is rejected: it is not a registry deck.
  Names are folded to lowercase. The deck half is a letter followed by up to 63
  letters or digits, since it becomes a Jennifer namespace; the scope half may
  also carry single hyphens between them (`@jennifer-language`). Windows device
  names such as `con` are refused for either half.
- **`version` must be SemVer**, and must match the tag you publish from. A tag
  `v1.0.0` whose manifest says `0.9.0` is a mislabelled release.
- **`keywords`** groups your deck for browsing, and is optional. At most five
  are used, in the order you write them, and the rest are dropped rather than
  rejected, so put the ones that matter first. Each is lowercased, and must be
  2 to 32 characters of letters, digits, and single inner hyphens: `http-client`
  is a keyword, `HTTP Client` and `c++` are not. Anything malformed is ignored,
  as is anything on the registry's refused list (a small set of terms this
  registry will not build category pages for). A rejected keyword never fails
  your release; it is dropped.
- **`capabilities`** is any of `net`, `exec`, `sql`. Declare what your code
  uses: the interpreter enforces it when it reads the code, so an inaccurate
  list becomes a runtime failure for whoever installs you. Leave it empty if your
  deck is pure.
- **`[decks]`** is your deck's own dependencies, captured at publish time, and
  drives resolution for your consumers. It is never recomputed, so a version
  keeps resolving the way it did the day it was published.

## Publishing it

`POST /publish` takes a repository and a tag, and nothing else about your deck.
The registry resolves the tag to a commit, reads `deck.toml` at that commit, and
records what the manifest says. You cannot rename a deck, change its
dependencies, or publish into a scope by asking for one: everything in the
record comes from your repository.

```sh
jvc publish --tag v0.1.0
```

There are three ways to be authorised, in order of preference.

### From CI, with no credential at all

Use this where your CI supports it. Your workflow presents the identity token
its runner already mints, the registry checks it against a publisher registered
for the deck in advance, and no secret exists anywhere: not in your
repository, not in your CI settings.

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - run: jvc publish --tag ${{ github.ref_name }}
```

Ask the registry operator to register the publisher once, giving them the deck,
your repository's **numeric id**, and the workflow file that publishes. The id
is used because a repository path can be renamed and re-registered by somebody
else:

```sh
gh api repos/acme/deck-routeros --jq .id
```

The run has to publish what it built: the tag you publish must point at the
commit the workflow ran at, and a run started by a tag can publish only that
tag. A release workflow triggered by pushing the tag, as above, satisfies both.

### From CI, with a token

Use this where trusted publishing is unavailable. The operator mints a token
scoped to your scope or to a single deck, and your pipeline presents it:

```sh
JVC_TOKEN=jvcp_... jvc publish --tag v0.1.0
```

It is a standing secret, so it expires (after 90 days unless the operator says
otherwise), it is revocable on its own, and every
publish it performs is recorded. Prefer the option above when you can.

### From your machine

`jvc login` gets you a short-lived token through your browser, and `jvc publish`
uses it. Fine for a first release; a pipeline should not depend on it, because
the login needs a human.

## Yanking a version

A release that should not be installed any more is yanked, not deleted, with
`POST /yank`, authorised the same way as a publish by a person. `POST /unyank`
undoes it:

```sh
jvc yank @acme/routeros 0.1.0
jvc unyank @acme/routeros 0.1.0
```

Underneath, that is one request with your login's bearer token:

```sh
curl -X POST https://registry.example.com/v1/yank \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"name": "@acme/routeros", "version": "0.1.0"}'
```

A yanked version stops satisfying new resolutions and stays fetchable, so a
lockfile that already pins it keeps working. Deletion is not offered because
removing a version breaks working builds.

## Two things have to line up

Publishing binds a name to a source, and you need the right to both.

- **The name** comes from `deck.toml` at the commit being published, not from
  anything you type. You cannot rename a deck at publish time, and you cannot
  publish a repository into a scope its own manifest does not name. So the scope
  in `name` must be one you hold.
- **The source** must be a public repository you can push to. Owning the scope
  is not enough: a repository somebody else controls could name your scope in
  its manifest, and publishing it would put code you do not control, and cannot
  keep working, under your name.

To publish someone else's deck under your own scope, fork it; that gives you a
source you control.

## If you rename your GitHub account

Your scope does not move. `@old` stays yours, keeps working, and keeps accepting
new versions; you may also claim `@new` if it is free. Nothing you have published
breaks.

Do one thing immediately: **register a placeholder account holding your old
username.** GitHub releases it
the moment you rename, with no grace period, and repository redirects from your
old paths stop working as soon as somebody recreates a repository of the same
name under it.

## Rules that will not change

**Tag your releases, and do not move the tags.** A version is pinned to the
commit its tag pointed at when it was published. Moving the tag afterwards does
not affect consumers, because the registry keeps handing out the recorded
commit, but your repository's history then disagrees with what people are
running.

**A published version is immutable.** Re-publishing an existing version is
refused with a `409`. If a release is wrong, publish a new version and yank the
bad one.

**Do not expect a source tarball to work as a pin.** A `tar.gz` version must be
an artifact somebody uploaded, with a stable `sha256`. Archives that a forge
generates on demand are not byte-stable over time, so a checksum over one can
stop matching without anybody touching your code. Publish from git instead.

## Scopes

A scope has to be registered before anything can publish under it. Under the
default claim policy, two you can claim yourself, with `jvc claim <scope>`:

- **your own login.** `alice` claims `@alice`.
- **an organisation you belong to.** A member of `acme` claims `@acme`, and the
  scope belongs to the organisation rather than to you. This needs a registry
  that logs in through GitHub; other providers report no memberships.

Anything else (a name that is not an account on your forge, a dispute, a
reassignment) is the operator's to grant. Ask them, naming the account that
should own it.

### "is neither your github username nor one of the organisations your login carries"

A claim for an organisation you belong to can still be refused. The registry
knows only the organisations GitHub reported when you logged in, and GitHub
omits an organisation that has enabled third-party application restrictions
until somebody approves this registry for it.

The refusal lists the organisations your login carries, and so does
`jvc whoami`. If one is missing:

1. Open your account's
   [authorised applications](https://github.com/settings/applications), and pick
   the registry.
2. Under **Organization access**, each organisation shows either **Grant** (you
   are an owner: one click) or **Request** (an owner has to approve it).
3. Log in to the registry again. A token is a snapshot, so an approval granted
   after yours was minted does not reach it until you get a new one.

If the organisation's owners will not approve the application, ask the registry
operator to grant the scope instead. That path does not consult GitHub.

### Sharing a scope

A scope can have more than one person publishing under it:

- **Co-owners**: other accounts that may publish and yank under the scope.
  The scope's owner adds and removes them (`jvc owners`, or the operator does);
  a co-owner cannot change the list.
- **An organisation scope**: the scope belongs to the organisation, and anyone
  who is an active member of it may publish. Somebody who leaves the
  organisation loses that right without anybody having to remove them, once
  their login expires: memberships are read at login, and a login lasts at most
  30 days however often it is refreshed.

For a team, a **trusted publisher per deck** is usually the better choice: each
repository publishes its own deck with no credential and no shared account. Use
co-owners when somebody needs to administer the scope, not only publish under
it.
