# The deck registry manual

A **deck** is a distributable, versioned bundle of Jennifer modules. You import
it; you never run it. This registry is where jvc, Jennifer's deck manager, looks
decks up.

These pages are task-shaped: finding a deck, depending on one, and getting your
own published. If you want the exact shape of an HTTP response, that is the
[administrator manual](/reference/); if you want the rules any registry must
implement, that is the [specifications](/specs/).

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

## The registry does not see your installs

This follows from indexing rather than hosting, and it is worth stating on its
own, because it is the part with consequences for you rather than for your
dependencies.

**When you install a deck, the registry is not in the loop.** jvc fetches the
code from the deck's own repository. We do not proxy it, redirect it, or receive
a notification about it. There is no request to this server that says a
particular machine installed a particular deck, because no such request exists to
make.

So there is no install history here to leak, subpoena, sell, or breach:

- **No record of who installed what.** Not anonymised, not aggregated, not
  retained for 30 days. It is not collected, which is a stronger guarantee than
  any retention policy, because a policy can be changed and a deployment that
  never receives the data cannot change its mind about it.
- **No account is needed to consume anything.** Reading, searching, resolving,
  and installing are all unauthenticated. You log in only to *publish*, and even
  then the registry holds an account id and a login name, never a password.
- **No tracking on the website.** The pages carry no analytics, no third-party
  requests, and no cookies. The only script is the light/dark switch, and the
  only thing stored in your browser is which of the two you picked.

What the registry *does* see is a client asking **where** a deck lives - the
metadata lookup that precedes a fetch. Those are counted per deck, in aggregate,
and shown on the deck page as **resolutions**. That count is a number per deck
per hour and nothing else: no address, no account, no user agent, nothing that
distinguishes one client from another, so it cannot be turned back into who
asked.

That is also why deck pages do not show a download count, and why you should be
suspicious if they ever start to. Counting real downloads would require putting
this server in the path of every install - which would mean seeing every install,
and being able to log it. The absence of that number is the privacy property
working as intended.

Your dependencies' repositories are a different matter: fetching from a forge is
a request to that forge, and it sees it. That is between you and them, and no
registry can promise otherwise.
