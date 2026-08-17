# Finding a deck

There are three ways in, depending on how well you already know what you want.

## Search

The search box matches on both the deck name and its description,
case-insensitively. Searching for `router` finds `@acme/routeros` by name, and
also finds a deck whose description mentions routers.

An empty search is not an error: it lists everything.

## Browse and tags

**Browse** lists every deck published here. The front page deliberately does not:
a complete listing is not browsing once a registry has more than a page of decks,
and it is the wrong thing to greet somebody with.

**Tags** is the other way in, for when you know the shape of what you want but
not its name. Each deck carries up to five keywords chosen by its author, and the
tag index shows them twice: as a cloud sized by how many decks carry each one,
which tells you what this registry is mostly *for*, and as a complete
alphabetical list, which is what you scan when you already have a word in mind.
Each tag has its own page at `/tag/<keyword>` listing the decks that carry it.

Tags come from the deck's newest version, so a keyword an author drops in a later
release stops grouping the deck.

## Who published it

Every deck page names the **scope** it was published under and links to that
scope's page, which lists everything else published under it and who holds it.
That is the quickest way from "this one deck looks useful" to "what else does
this author maintain".

From a terminal, the same search is available as JSON:

```sh
curl 'https://example.registry/search?q=router'
```

## Deck names

A registry deck name is always **scoped**: `@scope/deck`, as in
`@jennifer/routeros`. The scope is the owning vendor or project.

A bare name with no `@` and no `/` is not a registry deck at all: it is a module
that ships with the interpreter, or a local file. You will not find one here.

## Reading a deck page

Each deck has a page at `/deck/<scope>/<deck>`, which is a stable link you can
share. It lists every published version, newest first, and for each one:

| Column | What it tells you |
| ------ | ----------------- |
| **Version** | the SemVer version |
| **Kind** | `git` for a repository-hosted deck, `tar.gz` for an uploaded artifact |
| **Pin** | the commit the version was published from, or the artifact checksum |
| **Requires** | the other decks this version needs, with their version constraints |
| **Engines** | which interpreters can run it, and at which versions |
| **Capabilities** | the host facilities its code needs: `net`, `exec`, `sql` |

**Capabilities are worth reading before you depend on something.** A deck
declaring `net` cannot run on a build of the interpreter that lacks networking,
and the interpreter enforces that when it reads the code. Empty means the deck
is pure and runs anywhere.

**Engines are an allowlist of alternatives.** Your interpreter has to be named
there, and its version has to satisfy that entry's constraint. An empty or
absent table means no restriction.

The deck page also links the same record as JSON, which is what jvc reads.
