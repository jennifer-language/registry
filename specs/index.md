# The deck registry specifications

These are the normative documents. Everything else on this site describes an
implementation; these describe the contract that implementation has to meet, and
where the two disagree, these win.

The key words **MUST**, **SHOULD**, and **MAY** are used in the RFC 2119 sense
throughout both documents.

| Document | Owns |
| -------- | ---- |
| [Server specification](specs-server.md) | the wire format and the server's obligations: the naming grammar, the version record, the discovery document, every endpoint, and what a registry must verify before it accepts a publish |
| [Client specification](specs-client.md) | what a client does: negotiating an API version, fetching and verifying deck code, resolving locally, and logging in |

## Why two documents

They are split because they are owned by two projects. This repository is the
*server*; jvc is the *client*, and the client specification is maintained by the
jvc team and lives here only until it moves.

The dependency runs one way, deliberately: **the client specification references
the server specification for every payload shape rather than restating it.** That
is what keeps the two from drifting into two different descriptions of the same
bytes. When a payload changes, exactly one document changes.

## Reading them

Both are long, and neither is meant to be read front to back. Each is numbered
by section, and cross-references are by number - "8.8 step 6", "section 2.3" -
so a reference resolves without a link.

If you are implementing a registry, section 3 (the version record) and section 5
(the read API) are the shape of the thing, and the conformance checklist at the
end of the server specification is what to test against.

If you are implementing a client, start with section 4 of the client
specification: how a version is negotiated, and what to do when a registry does
not answer the discovery document at all.

## Versioning

The specification version is `0.1.0`, and stays below `1.0.0` until the reference
registry is tagged `1.0.0`; both are then tagged together and move in step, so a
`spec` string has one meaning. Until then the leading zero says what it says in
SemVer: this is not a stable target.

The **API** major does not follow it down. `apis[].version` is an integer in a
URL, not a SemVer field, and there is no v0.
