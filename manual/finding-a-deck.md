# Finding a deck

There are three ways in: search, browse and tags, and the publisher's scope.

## Search

The search box matches on both the deck name and its description,
case-insensitively. Searching for `router` finds `@acme/routeros` by name, and
also finds a deck whose description mentions routers.

An empty search lists everything. Results, like the browse listing, come 25
to a page; "Per page" under a listing switches to 10, 50 or 100, and a new
search keeps the choice.

## Browse and tags

**Browse** (`/browse`) lists every deck published here, alphabetically by deck
name and then by scope, so `@deckyard/routeros` and `@jennifer/routeros` sit
side by side: the same deck under two scopes is usually a fork or a move, and
worth seeing together. To see one publisher's decks, open their scope instead.
The front page does not list them. It features up to six instead, one per
card: the most resolved in the last 30 days, the busiest this week, the one
most other decks require, the newest, the latest release, and a deck of the
day that changes daily (UTC) and gives every deck a turn. The deck of the day
holds for the whole day: a deck published today joins the rotation tomorrow,
and when another card already shows today's deck, that card stands in for it.
A deck appears on one card at most, and only decks with a live version are
featured. Resolutions are
lookups, not downloads; the deck page explains the difference.

**Tags** (`/tags`) help when you know the kind of deck you want but not its name. Each
deck carries up to five keywords chosen by its author, and the tag index shows
them twice: as a cloud sized by how many decks carry each one, and as a complete
alphabetical list.
Each tag has its own page at `/tag/<keyword>` listing the decks that carry it.

Tags come from the deck's newest version, so a keyword an author drops in a later
release stops grouping the deck.

## Who published it

Every deck page names the **scope** it was published under and links to that
scope's page, `/scope/<name>`, which lists everything else published under it
and who holds it.

From a terminal, the same search is available as JSON:

```sh
curl 'https://example.registry/search?q=router'
```

## Following new decks

New and updated decks are a feed: `/feed.atom` (Atom) or `/feed.rss` (RSS), or
one publisher's at `/feed/@<scope>.atom`. Each item is one published version,
marked `new` for a deck's first version and `updated` for a later one. A feed
shows what was published in the last 30 days, at most 50 items and at least
the latest 10; `?days=` (up to 365) and `?limit=` (up to 100) change that.
Yanked versions are left out.

## Deck names

A registry deck name is always scoped: `@scope/deck`, as in
`@jennifer/routeros`. The scope is the owning vendor or project.

A bare name with no `@` and no `/` is not a registry deck: it is a module that
ships with the interpreter, or a local file.

## Reading a deck page

Each deck has a stable page at `/deck/<scope>/<deck>`. It lists every published
version, newest first, yanked ones included, and for each one:

| Column | What it tells you |
| ------ | ----------------- |
| **Version** | the SemVer version |
| **Status** | `live`, or `yanked` (struck through: new installs skip it) |
| **Kind** | `git` for a repository-hosted deck, `tar.gz` for an uploaded artifact |
| **Pin** | the commit the version was published from, or the artifact checksum |
| **Requires** | the other decks this version needs, with their version constraints |
| **Engines** | which interpreters can run it, and at which versions |
| **Capabilities** | the host facilities its code needs: `net`, `exec`, `sql` |

**Capabilities:** a deck declaring `net` cannot run on a build of the
interpreter that lacks networking, and the interpreter enforces that when it
reads the code. Empty means the deck is pure and runs anywhere.

**Engines** is an allowlist of alternatives. Your interpreter has to be named
there, and its version has to satisfy that entry's constraint. An empty or
absent table means no restriction.

Above the table are the deck's tags and a snippet to depend on it; below it,
the licence and source of the newest release that is not yanked, the resolution
counts, and the README as of the last release that carried one. A banner says
so when the newest version, or every version, is yanked.

**A deck that moved** to another name shows a banner naming the new deck in
place of the snippet: change the `[decks]` entry and the imports to the new
name. jvc refuses to add, install or update the old one; a lockfile that pins
one of its versions still installs, with a warning. The old name is not an
alias, so its versions are never the new deck's.

The deck page also links the same record as JSON, which [jvc](https://jvc.jennifer-lang.dev/) reads.
