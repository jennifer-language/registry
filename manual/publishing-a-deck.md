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

[engines]
jennifer = ">=0.24.0"

[decks]
"@acme/net" = "^1.0.0"
```

- **`name` must be scoped.** A bare name is rejected: it is not a registry deck.
  Both halves are one ASCII letter followed by up to 63 letters or digits.
- **`version` must be SemVer**, and must match the tag you publish from. A tag
  `v1.0.0` whose manifest says `0.9.0` is a mislabelled release.
- **`capabilities`** is any of `net`, `exec`, `sql`. Declare what your code
  actually uses: the interpreter enforces it when it reads the code, so an
  inaccurate list becomes a runtime failure for whoever installs you. Leave it
  empty if your deck is pure.
- **`[decks]`** is captured at publish time and is what drives resolution for
  your consumers. It is never recomputed later.

## Getting it listed

**There is no publish API yet.** Today, publishing is an operator action: the
person running the registry records your version with the operator CLI. Send
them the repository, the tag, and the commit that tag points at.

```sh
git rev-parse v0.1.0        # the commit to hand over
```

The [reference](/reference/cli.html) documents the command they run. The
[server specification](/reference/specs-server.html) describes the `POST
/publish` flow that will replace this, where you name a repository and a tag and
the registry reads `deck.toml` at that commit itself rather than trusting
anything you send.

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
refused. If a release is wrong, publish a new version, and ask for the bad one
to be yanked.

**Do not expect a source tarball to work as a pin.** A `tar.gz` version must be
an artifact somebody uploaded, with a stable `sha256`. Archives that a forge
generates on demand are not byte-stable over time, so a checksum over one can
stop matching without anybody touching your code. Publish from git instead.

## Scopes

A scope has to be registered before anything can publish under it, and the
registry operator grants it. The specification describes deriving scope
ownership from a GitHub account instead, so that `@acme` belongs to whoever
controls the `acme` user or organisation; until that exists, ask the operator.
