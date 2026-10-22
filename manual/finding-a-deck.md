# Finding a deck

There are three ways in: search, browse and tags, and the publisher's scope.

## Search

The search box matches on both the deck name and its description,
case-insensitively. Searching for `router` finds `@acme/routeros` by name, and
also finds a deck whose description mentions routers.

An empty search lists everything. Results, like the browse listing, come 100
to a page.

## Browse and tags

**Browse** (`/browse`) lists every deck published here, alphabetically, 100 to
a page. The front page does not list them.

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

The deck page also links the same record as JSON, which [jvc](https://jvc.jennifer-lang.dev/) reads.
