# The deck registry manual

A **deck** is a distributable, versioned bundle of Jennifer modules. You import
it; you never run it. This registry is where jvc, Jennifer's deck manager, looks
decks up.

These pages cover finding a deck, depending on one, and publishing your own. The
exact shape of an HTTP response is in the [administrator manual](/reference/);
the rules any registry must implement are in the [specifications](/specs/).

| | |
| - | - |
| [Finding a deck](finding-a-deck.md) | search, and how to read a deck page |
| [Using a deck](using-a-deck.md) | depending on one, and what install does |
| [Publishing a deck](publishing-a-deck.md) | what your repository needs, and how to get it listed |

## What the registry does, and does not

**It indexes; it does not host.** Your deck's code stays in your git repository.
The registry stores metadata and the coordinates that identify exactly which
commit a version is, and jvc fetches the code from your repository directly.
Two things follow:

- A published version is pinned to a **commit**, not to a tag. If an author
  force-pushes `v1.0.0` to different code after publishing, your install is
  unaffected: the registry hands out the commit it recorded at publish time.
- If a repository or its objects disappear, that version becomes uninstallable.
  The registry cannot serve the code, because it never had a copy.

**A published version is immutable.** Nothing is ever re-published over an
existing version. A bad release is withdrawn by *yanking* it, which stops new
installs from choosing it while leaving existing lockfiles working.

## The registry does not see your installs

This also follows from indexing rather than hosting.

When you install a deck, jvc fetches the code from the deck's own repository.
The registry does not proxy it, redirect it, or receive a notification about it.
No request to this server says that a particular machine installed a particular
deck.

So there is no install history here to leak, subpoena, sell, or breach:

- **No record of who installed what.** Not anonymised, not aggregated, not
  retained for 30 days: it is not collected. A retention policy can be changed;
  a deployment that never receives the data cannot change its mind about it.
- **No account is needed to consume anything.** Reading, searching, resolving,
  and installing are all unauthenticated. You log in only to *publish*, and even
  then the registry holds your account id, login name, and organisation
  memberships, plus, where it asks your forge with your own credential whether
  you may push to a repository, that forge token, encrypted. Never a password.
- **No tracking on the website.** The pages carry no analytics, no third-party
  requests, and no cookies. The only script is the light/dark switch, and the
  only thing stored in your browser is which of the two you picked.

What the registry does see is a client asking where a deck lives: the metadata
lookup that precedes a fetch. Those lookups are counted per deck, in aggregate,
and shown on the deck page as **resolutions**. The count is a number per deck
per hour, day, and month, and nothing else: no address, no account, no user
agent, nothing that distinguishes one client from another, so it cannot be traced
back to who asked.

For the same reason deck pages show no download count; be suspicious if they
ever start to. Counting real downloads would require putting this server in the
path of every install, where it could see and log every install.

Your dependencies' repositories are a different matter: fetching from a forge is
a request to that forge, and the forge sees it. No registry can promise
otherwise.
