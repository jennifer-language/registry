# Using a deck

## Declaring the dependency

Decks go in your project's `deck.toml`, under `[decks]`, as a name and a version
constraint:

```toml
[decks]
"@acme/routeros" = "^0.1.0"
"@acme/net" = "^1.0.0"
```

Every deck page offers this snippet ready to paste, pinned to that deck's latest
version.

## Version constraints

A constraint is a **single** expression. There are no compound ranges: no `||`,
no comma-separated lists.

| Form | Matches |
| ---- | ------- |
| `*`, `any`, or empty | any published version |
| `1.2.3` or `=1.2.3` | exactly that version |
| `^1.2.3` | `>=1.2.3` and `<2.0.0` |
| `^0.2.3` | `>=0.2.3` and `<0.3.0` (zero-aware) |
| `^0.0.3` | `>=0.0.3` and `<0.0.4` |
| `~1.2.3` or `~1.2` | `>=1.2.0` and `<1.3.0` |
| `>=1.0.0`, `<2.0.0`, ... | the comparator holds |

`^` is the one you usually want: it accepts compatible updates and stops at the
next breaking major. Below `1.0.0`, where the minor is effectively the major, it
narrows automatically.

**A prerelease never satisfies a `^` or `~` range.** Ask for a prerelease
exactly, by version, if you want one.

## What install does

Resolution happens **on your machine**, not on the server. jvc reads each deck's
metadata, works out one version per deck that satisfies every constraint on it
at once, and picks the highest such version. When two of your dependencies
disagree about a shared deck, the winner must satisfy both.

Only the deck's `src/` directory is installed, into `vendor/<scope>/<deck>/`.
So `@acme/routeros` lands in `vendor/acme/routeros/`, and you import it as:

```jennifer
import "@acme/routeros/" as routeros;
```

Everything else in the deck's repository, including its `deck.toml` and any
`template/` directory, is not vendored.

## Lockfiles and reproducibility

The resolved set is recorded with each deck's exact version and commit, so a
later install reproduces the same code without resolving again. That is what
makes a build reproducible: the commit is a content hash, and git verifies
object hashes when it fetches, so the code that arrives is the code that was
published.

## Yanked versions

A yanked version is one the author has withdrawn: a broken release, or one
published by mistake. It stops satisfying constraints for **new** resolutions,
so a fresh install skips it, but it remains fetchable so an existing lockfile
still installs. Yanking is reversible; deletion is not offered.
