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
  Both halves are one ASCII letter followed by up to 63 letters or digits.
- **`version` must be SemVer**, and must match the tag you publish from. A tag
  `v1.0.0` whose manifest says `0.9.0` is a mislabelled release.
- **`keywords`** groups your deck for browsing, and is optional. **At most five
  are used**, in the order you write them, and the rest are dropped rather than
  rejected, so put the ones that matter first. Each is lowercased, and must be
  2 to 32 characters of letters, digits, and single inner hyphens: `http-client`
  is a keyword, `HTTP Client` and `c++` are not. Anything malformed is ignored,
  as is anything on the registry's refused list - a small set of terms this
  registry will not build category pages for. Nothing here can fail your
  release; a rejected keyword costs you that keyword only.
- **`capabilities`** is any of `net`, `exec`, `sql`. Declare what your code
  actually uses: the interpreter enforces it when it reads the code, so an
  inaccurate list becomes a runtime failure for whoever installs you. Leave it
  empty if your deck is pure.
- **`[decks]`** is your deck's own dependencies, captured at publish time, and is
  what drives resolution for your consumers. It is never recomputed later, so a
  version keeps resolving the way it did the day it was published.

## Publishing it

`POST /publish` takes a **repository and a tag**, and nothing else about your
deck. The registry resolves the tag to a commit, reads `deck.toml` **at that
commit**, and records what the manifest says. You cannot rename a deck, change
its dependencies, or publish into a scope by asking for one: everything that ends
up in the record came out of your repository.

```sh
jvc publish --tag v0.1.0
```

There are three ways to be allowed to do it. Reach for them in this order.

### From CI, with no credential at all

The best option where your CI supports it. Your workflow presents the identity
token its runner already mints, the registry checks it against a publisher the
scope owner registered in advance, and **no secret exists anywhere** - not in
your repository, not in your CI settings.

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - run: jvc publish --tag ${{ github.ref_name }}
```

Ask the registry operator to register the publisher once, giving them the deck,
your repository's **numeric id**, and the workflow file that publishes. The id
rather than the path, because a repository path can be renamed and re-registered
by somebody else:

```sh
gh api repos/acme/deck-routeros --jq .id
```

### From CI, with a token

Where trusted publishing is unavailable. The operator mints a token scoped to
your scope or to a single deck, and your pipeline presents it:

```sh
JVC_TOKEN=jvcp_... jvc publish --tag v0.1.0
```

It is a standing secret, so it expires, it is revocable on its own, and every
publish it performs is recorded. Prefer the option above when you can.

### From your machine

`jvc login` gets you a short-lived token through your browser, and `jvc publish`
uses it. Fine for a first release; a pipeline should not depend on it, because
the login needs a human.

## Yanking a version

A release that should not be installed any more is **yanked**, not deleted. The
registry offers it at `POST /yank`, authorised the same way a publish by a person
is, with `POST /unyank` to undo it:

```sh
curl -X POST https://registry.example.com/v1/yank \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"name": "@acme/routeros", "version": "0.1.0"}'
```

Check whether your client wraps this in a command of its own before reaching for
curl.

A yanked version stops satisfying new resolutions and stays fetchable, so a
lockfile that already pins it keeps working. That is the whole difference, and it
is why deletion is not offered: removing a version breaks builds that were
working, for people who did nothing wrong.

## Two things have to line up

Publishing binds a **name** to a **source**, and you need the right to both.

- **The name** comes from `deck.toml` at the commit being published, not from
  anything you type. You cannot rename a deck at publish time, and you cannot
  publish a repository into a scope its own manifest does not name. So the scope
  in `name` must be one you hold.
- **The source** must be a public repository you can push to. Naming a scope you
  own is not enough on its own: a repository somebody else controls could name
  your scope in its manifest, and publishing it would put code you do not
  control, and cannot keep working, under your name.

Fork it if you want to publish someone else's deck under your own scope. That is
the honest version of the same act, and it gives you a source you control.

## If you rename your GitHub account

Your scope does not move. `@old` stays yours, keeps working, and keeps accepting
new versions; you may also claim `@new` if it is free. Nothing you have published
breaks.

One thing is worth doing immediately, though, and nobody thinks of it unprompted:
**register a placeholder account holding your old username.** GitHub releases it
the moment you rename, with no grace period, and repository redirects from your
old paths stop working as soon as somebody recreates a repository of the same
name under it.

## Rules that will not change

**Tag your releases, and do not move the tags.** A version is pinned to the
commit its tag pointed at when it was published. Moving the tag afterwards is
harmless to consumers, because the registry keeps handing out the recorded
commit, but it makes your repository's history disagree with what people are
running.

**A published version is immutable.** Re-publishing an existing version is
refused with a `409`. If a release is wrong, publish a new version and yank the
bad one.

**Do not expect a source tarball to work as a pin.** A `tar.gz` version must be
an artifact somebody uploaded, with a stable `sha256`. Archives that a forge
generates on demand are not byte-stable over time, so a checksum over one can
stop matching without anybody touching your code. Publish from git instead.

## Scopes

A scope has to be registered before anything can publish under it. Two you can
claim yourself:

- **your own login.** `alice` claims `@alice`.
- **an organisation you belong to.** A member of `acme` claims `@acme`, and the
  scope belongs to the organisation rather than to you.

Anything else - a name that is not an account on your forge, a dispute, a
reassignment - is the operator's to grant. Ask them, naming the account that
should own it.

### "does not match your github username"

A claim for an organisation you are certain you belong to can still be refused.
The registry only knows the organisations **GitHub told it about** when you
logged in, and GitHub does not necessarily tell it about all of them: an
organisation that has enabled third-party application restrictions is omitted
entirely until somebody approves this registry for it. Your membership is real;
the registry simply cannot see it.

Log in again and read what comes back - the organisations the registry saw are
listed there. If one is missing:

1. Open your account's
   [authorised applications](https://github.com/settings/applications), and pick
   the registry.
2. Under **Organization access**, each organisation shows either **Grant** (you
   are an owner: one click) or **Request** (an owner has to approve it).
3. Log in to the registry again. A token is a snapshot, so an approval granted
   after yours was minted does not reach it until you get a new one.

If the organisation's owners will not approve the application - a legitimate
policy - ask the registry operator to grant the scope instead. That path does
not consult GitHub at all.

### Sharing a scope

A scope can have more than one person publishing under it:

- **Co-owners** - other accounts that may publish and yank under the scope.
- **An organisation scope** - the scope belongs to the organisation, and anyone
  who is an active member of it may publish. Somebody who leaves the
  organisation stops being able to, without anybody having to remember to remove
  them.

For a team, though, you usually want neither: a **trusted publisher per deck**
lets each repository publish its own deck with no credential and no shared
account. Reach for co-owners when somebody needs to *administer* the scope, not
merely publish under it.
