# The deck registry specifications

These are the normative documents. The rest of this site describes an
implementation; these describe the contract it has to meet, and where the two
disagree, these win.

The key words **MUST**, **SHOULD**, and **MAY** are used in the RFC 2119 sense
throughout both documents.

| Document | Owns |
| -------- | ---- |
| [Server specification](specs-server.md) | the wire format and the server's obligations: the naming grammar, the version record, the discovery document, every endpoint, and what a registry must verify before it accepts a publish |
| [Client specification](specs-client.md) | what a client does: negotiating an API version, fetching and verifying deck code, resolving locally, and logging in |

## Why two documents

Two projects own them. This repository is the server; [jvc](https://jvc.jennifer-lang.dev/) is the client, and
the client specification is maintained by the jvc team and lives here until it
moves.

The dependency runs one way: the client specification references the server
specification for every payload shape rather than restating it, so the two
cannot drift apart. When a payload changes, exactly one document changes.

## Reading them

Neither is meant to be read front to back. Each is numbered by section, and
cross-references are by number ("8.9 step 3", "section 2.3"), so a reference
resolves without a link.

To implement a registry, start with section 3 (the version record) and section 5
(the read API), and test against the conformance checklist at the end of the
server specification.

To implement a client, start with section 3 of the client specification: how a
version is negotiated, and what to do when a registry does not answer the
discovery document at all.

## Versioning

The specification version is `0.1.0`, and stays below `1.0.0` until the reference
registry is tagged `1.0.0`; both are then tagged together and move in step, so a
`spec` string has one meaning. Until then, as in SemVer, it is not a stable
target.

The API major does not follow it down. `apis[].version` is an integer in a
URL, not a SemVer field, and there is no v0.
