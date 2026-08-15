# The deck registry manual

A **deck** is a distributable, versioned bundle of Jennifer modules. You import
it; you never run it. This registry is where jvc, Jennifer's deck manager, looks
decks up.

These pages are task-shaped: finding a deck, depending on one, and getting your
own published. If you want the exact shape of an HTTP response or the rules a
registry must implement, that is the [reference](/reference/) instead.

| | |
| - | - |
| [Finding a deck](finding-a-deck.md) | search, and how to read a deck page |
| [Using a deck](using-a-deck.md) | depending on one, and what install does |
| [Publishing a deck](publishing-a-deck.md) | what your repository needs, and how to get it listed |

## What the registry does, and does not

**It indexes; it does not host.** Your deck's code stays in your git repository.
The registry stores metadata and the coordinates that identify exactly which
commit a version is, and jvc fetches the code from your repository directly.

Two things follow from that, and they are worth knowing before you depend on
anything:

- A published version is pinned to a **commit**, not to a tag. If an author
  force-pushes `v1.0.0` to different code after publishing, your install is
  unaffected: the registry hands out the commit it recorded at publish time.
- If a repository or its objects disappear, that version becomes uninstallable.
  The registry cannot serve the code, because it never had a copy.

**A published version is immutable.** Nothing is ever re-published over an
existing version. A bad release is withdrawn by *yanking* it, which stops new
installs from choosing it while leaving existing lockfiles working.
