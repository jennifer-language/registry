# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * `POST /publish`, as pure data (specification 7).
 *
 * The registry does not trust the request body for anything that matters. A
 * publish names a **repository and a tag**; the caller's forge resolves that tag
 * to a commit and reads `deck.toml` **at that commit**, and everything the
 * record says about the deck comes from there. The request cannot name the deck,
 * because then the scope check would be checking a claim rather than a fact.
 *
 * Two ways to be authorised, and they answer different halves of 7.1:
 *
 * - **A bearer token** identifies a person. It establishes *name* authority
 *   through the scope binding, and nothing about the source, so a deployment
 *   must still satisfy source authority by route A or B.
 * - **A CI identity token** (8.9) identifies a *workload*, and its repository
 *   claim is the forge attesting where the build ran. That is route C, so it
 *   settles both halves at once.
 *
 * Everything here is a function of the store and its arguments. The forge calls
 * that produce a `Source` happen in `bin/serve`, which is what keeps the
 * ordering of these checks - the part that decides who may write - testable
 * without a network.
 * @module publishview
 * @example
 * import "./publishview.j" as publishview;
 * def out as publishview.PublishReply init publishview.byToken($db, $who, $src, $now);
 * # if (out.changed) { store.save(out.db); }
 */

use json;
use strings;
use convert;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./scope.j" as scope;
import "./identity.j" as identity;
import "./policy.j" as policy;
import "./manifest.j" as manifest;
import "./trustpub.j" as trustpub;
import "./deckname.j" as deckname;
import "./audit.j" as audit;
import "./citoken.j" as citoken;

/**
 * What the forge produced for a publish request. Assembled by the caller, which
 * owns every network call; this module only reads it.
 * @field repository {string} the clone URL that was published from
 * @field tag {string} the tag named in the request, kept for display
 * @field commit {string} the 40-hex commit that tag resolved to - the pin
 * @field repoId {string} the forge's immutable numeric repository id
 * @field repoOwnerId {string} the numeric id of the owning account
 * @field repoOwner {string} the owner's name, a display label
 * @field manifestText {string} the bytes of `deck.toml` at that commit
 * @field readmeText {string} the bytes of `README.md` at that commit ("" when
 *     the repository has none; a deck without one is not an error)
 * @field commitShadowed {bool} true when the repository also holds a **branch or
 *     tag named exactly like the resolved commit**, which means the manifest
 *     above cannot be trusted to have come from the commit (see `checkSource`)
 */
export def struct Source {
    repository as string,
    tag as string,
    commit as string,
    repoId as string,
    repoOwnerId as string,
    repoOwner as string,
    manifestText as string,
    readmeText as string,
    commitShadowed as bool
};

/**
 * The outcome of a publish: the response, and the store it wants persisted.
 * @field status {int} the HTTP status
 * @field body {json.Value} the response body
 * @field db {flatdb.DB} the resulting store
 * @field changed {bool} true when the store was edited and should be saved
 * @field event {audit.Event} what to record in the operational log
 */
export def struct PublishReply {
    status as int,
    body as json.Value,
    db as flatdb.DB,
    changed as bool,
    event as audit.Event
};

# refuse builds a reply that leaves the store untouched. The event is recorded
# for a refusal as well as a success: a rejected publish is how a misconfigured
# pipeline looks from the server side, and it is the thing an operator is
# usually trying to find.
func refuse(db as flatdb.DB, status as int, reason as string) {
    def body as json.Value init json.map();
    $body = json.set($body, "/error", $reason);
    return PublishReply{
        status: $status, body: $body, db: $db, changed: false,
        event: audit.publishRefused($reason, $status)
    };
}

/**
 * Validate a `Source` before anything is decided from it.
 *
 * The commit is checked here because it becomes the record's identity: an
 * abbreviated or malformed SHA would be stored as the pin and handed to every
 * client that installs the version.
 * @param src {Source} the forge's output
 * @return {string} "" when usable, or the complaint
 */
export func checkSource(src as Source) {
    if (strings.trim($src.repository) == "") {
        return "missing `repository`";
    }
    if (strings.trim($src.tag) == "") {
        return "missing `tag`";
    }
    # A tag shaped like an object id is refused before anything is resolved. The
    # registry would otherwise store it and serve it to every client as `ref`,
    # and a client that looks a name up before an object gets whatever that ref
    # points at while the record still reads as pinned.
    if (store.isObjectIdLike($src.tag)) {
        return "the tag " + $src.tag + " is shaped like a git object id, " +
            "which a client can resolve as a commit; publish from a tag that " +
            "cannot be read as one, such as v" + $src.tag;
    }
    if (not store.isCommit($src.commit)) {
        return "the tag did not resolve to a full commit SHA: " + $src.commit;
    }
    # The manifest above was read through the forge's ref-or-sha parameter, which
    # resolves a **name** before an object. So a branch or tag named after the
    # resolved commit stands in front of it, and everything read "at the commit"
    # came from wherever that ref points instead - while the record still says
    # `commit`. Refused rather than worked around, because at this point the
    # bytes in hand are already the wrong ones.
    if ($src.commitShadowed) {
        return "the repository has a branch or tag named " + $src.commit +
            ", which shadows the commit of that id; delete it and publish again";
    }
    return "";
}

# storeVersion writes the version the manifest describes, pinned to the commit
# the tag resolved to. Always KIND_GIT: a publish names a repository and a tag,
# and the commit is the integrity boundary (3.2).
func storeVersion(db as flatdb.DB, m as manifest.Manifest, src as Source, now as string) {
    def ver as store.DeckVersion init store.DeckVersion{
        version: $m.version,
        kind: store.KIND_GIT,
        url: $src.repository,
        ref: $src.tag,
        commit: $src.commit,
        checksum: "",
        requires: $m.requires,
        engines: $m.engines,
        capabilities: $m.capabilities,
        description: $m.description,
        publishedAt: $now,
        yanked: false,
        license: $m.license,
        # Already normalised by `manifest.parse`, so a publish carries the tags
        # the registry will actually index rather than what the file asked for.
        keywords: $m.keywords
    };
    def out as flatdb.DB init store.putVersion($db, $m.name, $m.description, $ver);
    # The README is recorded after the deck exists, and only when the repository
    # had one: an absent README must not blank a previously published one, since
    # that would make a release from a stripped-down branch erase the page.
    if (not (strings.trim($src.readmeText) == "")) {
        $out = store.putReadme($out, $m.name, $src.readmeText);
    }
    return $out;
}

# succeed writes the version and builds the 201.
func succeed(db as flatdb.DB, m as manifest.Manifest, src as Source, now as string,
        how as string) {
    def out as flatdb.DB init storeVersion($db, $m, $src, $now);
    def body as json.Value init json.map();
    $body = json.set($body, "/name", $m.name);
    $body = json.set($body, "/version", $m.version);
    $body = json.set($body, "/kind", store.KIND_GIT);
    $body = json.set($body, "/url", $src.repository);
    $body = json.set($body, "/ref", $src.tag);
    $body = json.set($body, "/commit", $src.commit);
    return PublishReply{
        status: 201, body: $body, db: $out, changed: true,
        event: audit.deckPublishedFrom($m.name, $m.version, $src.commit,
            $src.repository, $how)
    };
}

/**
 * The checks every publish makes, whoever is calling.
 *
 * The order is the point. A malformed request is a `400` and never reaches the
 * store; an unknown scope is a `404`-shaped refusal that names the missing
 * registration; and **the version-exists check comes last among these**, because
 * "already published" is the answer a well-formed, authorised, repeated publish
 * should get, and reporting it in place of a real problem would hide the real
 * problem.
 * @param db {flatdb.DB} the store to read
 * @param m {manifest.Manifest} the parsed manifest, already `ok`
 * @return {string} "" when the publish may proceed, or the complaint
 */
export func checkDeck(db as flatdb.DB, m as manifest.Manifest) {
    def scopeName as string init deckname.scopeOf($m.name);
    if (not store.hasNamespace($db, $scopeName)) {
        return "namespace @" + $scopeName + " is not registered on this registry";
    }
    # A registered scope bound to nobody is *reserved*: an operator holds the
    # name so that nobody can claim it and nobody can write under it. Every
    # publish that reaches this module arrives on a **delegated** credential - a
    # person's bearer token, a workload's identity token, a CI token - and a
    # delegation under a scope with no owner is a delegation on nobody's behalf.
    #
    # `scope.authorise` already refuses it for the bearer-token path, but the
    # other two never consult the namespace at all: a trusted publisher is
    # authorised by its binding and a CI token by its own record, so without
    # this the invariant would hold only where those credentials are created and
    # not where they are relied on. It belongs here, in the one check all three
    # share. The operator's own `deckadmin add` does not come through here, so a
    # reserved scope stays writable by the operator holding it.
    if (store.getNamespace($db, $scopeName).subject == "") {
        return "@" + $scopeName +
            " is held by an operator and has no owner to publish under it";
    }
    return "";
}

# conflict reports whether this exact version already exists. Immutability is
# absolute (specification 9): a published version's bytes never change, because
# a lockfile that resolved it once must resolve to the same code forever.
func alreadyPublished(db as flatdb.DB, m as manifest.Manifest) {
    return store.hasVersion($db, $m.name, $m.version);
}

# parsed reads the manifest and turns a parse failure into a 400. A manifest the
# repository does not have, or cannot be read, is the caller's problem to report
# before getting here.
func parsed(src as Source) {
    return manifest.parse($src.manifestText);
}

/**
 * Publish authorised by a bearer token: a **person** with a scope binding.
 *
 * Establishes name authority only. The deployment is responsible for source
 * authority (7.1 route A or B) before calling, or for recording the source as
 * unverified; this module cannot check it, because a bearer token says nothing
 * about a repository.
 * @param db {flatdb.DB} the store
 * @param who {identity.Subject} the authenticated caller
 * @param src {Source} what the forge produced
 * @param now {string} the publish timestamp (Unix seconds as text)
 * @return {PublishReply} the outcome, and the store to persist on success
 */
export func byToken(db as flatdb.DB, who as identity.Subject, src as Source,
        now as string) {
    def complaint as string init checkSource($src);
    if (not ($complaint == "")) {
        return refuse($db, 400, $complaint);
    }
    def m as manifest.Manifest init parsed($src);
    if (not $m.ok) {
        return refuse($db, 400, $m.error);
    }
    def deckComplaint as string init checkDeck($db, $m);
    if (not ($deckComplaint == "")) {
        return refuse($db, 403, $deckComplaint);
    }
    def verdict as policy.Decision init scope.authorise($db, $who,
        deckname.scopeOf($m.name));
    if (not $verdict.allowed) {
        return refuse($db, 403, $verdict.reason);
    }
    if (alreadyPublished($db, $m)) {
        return refuse($db, 409, $m.name + "@" + $m.version + " is already published");
    }
    return succeed($db, $m, $src, $now, "token");
}

/**
 * Publish authorised by a **CI token** (8.10): the fallback where trusted
 * publishing is unavailable.
 *
 * Establishes name authority only, exactly like a bearer token, because
 * possession of a secret says nothing about a repository. What it adds over a
 * user's token is that it is narrower: bound to one scope or one deck, so a
 * leak costs that much and no more.
 *
 * The token is stamped as used on success, which 8.10 requires: once a standing
 * secret exists, finding the unused ones is the only way they get retired.
 * @param db {flatdb.DB} the store
 * @param t {citoken.Token} the record found for the presented token
 * @param src {Source} what the forge produced
 * @param now {string} the publish timestamp (Unix seconds as text)
 * @return {PublishReply} the outcome, and the store to persist on success
 */
export func byCiToken(db as flatdb.DB, t as citoken.Token, src as Source,
        now as string) {
    def complaint as string init checkSource($src);
    if (not ($complaint == "")) {
        return refuse($db, 400, $complaint);
    }
    def m as manifest.Manifest init parsed($src);
    if (not $m.ok) {
        return refuse($db, 400, $m.error);
    }
    def deckComplaint as string init checkDeck($db, $m);
    if (not ($deckComplaint == "")) {
        return refuse($db, 403, $deckComplaint);
    }
    # The token is matched against the name read at the commit, so a token for
    # one deck cannot publish another by naming it in the request.
    def v as citoken.Verdict init citoken.check($t, $m.name, convert.toInt($now));
    if (not $v.allowed) {
        return refuse($db, 403, $v.reason);
    }
    if (alreadyPublished($db, $m)) {
        return refuse($db, 409, $m.name + "@" + $m.version + " is already published");
    }
    def out as PublishReply init succeed($db, $m, $src, $now, "ci-token");
    $out.db = store.touchCiToken($out.db, $t.fingerprint, $now);
    return $out;
}

/**
 * Publish authorised by a CI identity token (8.9): a **workload** with a binding.
 *
 * The claims are already signature-verified by the caller; what happens here is
 * everything a signature does not establish - audience, issuer, and whether
 * these claims match the binding registered for *this deck*.
 *
 * The binding is looked up by the deck name **from the manifest**, so a
 * repository cannot publish to a deck it is not bound to by naming a different
 * one in the request. There is no fallback to creating a binding: 8.9 forbids
 * it, because auto-binding on first use would let whichever repository publishes
 * first capture a name.
 * @param db {flatdb.DB} the store
 * @param claims {trustpub.Claims} the verified token's claims
 * @param audience {string} the audience this registry publishes and requires
 * @param issuer {string} the issuer required for the claims' provider
 * @param src {Source} what the forge produced
 * @param now {string} the publish timestamp (Unix seconds as text)
 * @return {PublishReply} the outcome, and the store to persist on success
 */
export func byTrustedPublisher(db as flatdb.DB, claims as trustpub.Claims,
        audience as string, issuer as string, src as Source, now as string) {
    def complaint as string init checkSource($src);
    if (not ($complaint == "")) {
        return refuse($db, 400, $complaint);
    }
    def m as manifest.Manifest init parsed($src);
    if (not $m.ok) {
        return refuse($db, 400, $m.error);
    }
    def deckComplaint as string init checkDeck($db, $m);
    if (not ($deckComplaint == "")) {
        return refuse($db, 403, $deckComplaint);
    }
    if (not store.hasBinding($db, $m.name)) {
        return refuse($db, 403, "no trusted publisher is registered for " + $m.name);
    }
    def b as trustpub.Binding init store.getBinding($db, $m.name);
    def v as trustpub.Verdict init trustpub.check($b, $claims, $audience, $issuer);
    if (not $v.allowed) {
        return refuse($db, 403, $v.reason);
    }
    # The token said which repository the build ran in; the forge said which
    # repository this URL is. They must be the same, or a build in a repository
    # the caller controls could publish code from one they do not (7.1).
    if (not ($src.repoId == "") and not ($src.repoId == $claims.repositoryId)) {
        return refuse($db, 403, "the token is for repository " + $claims.repositoryId +
            " but the source is repository " + $src.repoId);
    }
    if (alreadyPublished($db, $m)) {
        return refuse($db, 409, $m.name + "@" + $m.version + " is already published");
    }
    def out as PublishReply init succeed($db, $m, $src, $now, "trusted-publisher");
    # A pending binding becomes a normal one on the first successful publish.
    if ($b.pending) {
        def settled as trustpub.Binding init $b;
        $settled.pending = false;
        $out.db = store.putBinding($out.db, $settled);
    }
    return $out;
}

/**
 * `POST /yank` and `POST /unyank`: withdraw a version from new resolutions, or
 * restore it (specification 9).
 *
 * Authorised exactly as a publish is, and for the same reason: yanking changes
 * what every fresh resolution produces, so it is as privileged as adding a
 * version. It takes a deck name and a version directly rather than a repository
 * and a tag, because there is nothing to read at a commit - the record already
 * exists, and this only flips a flag on it.
 *
 * Reversible by design. The version stays in the record and stays fetchable, so
 * a lockfile that pins it keeps installing; a mistaken yank is undone by
 * unyanking rather than by republishing, which immutability forbids.
 * @param db {flatdb.DB} the store
 * @param who {identity.Subject} the authenticated caller
 * @param name {string} the deck name
 * @param version {string} the version to withdraw or restore
 * @param yanked {bool} true to withdraw, false to restore
 * @return {PublishReply} the outcome, and the store to persist on success
 */
export func setYanked(db as flatdb.DB, who as identity.Subject, name as string,
        version as string, yanked as bool) {
    def deck as string init deckname.fold($name);
    if ($deck == "" or $version == "") {
        return refuse($db, 400, "missing `name` or `version`");
    }
    if (not deckname.isScoped($deck)) {
        return refuse($db, 400, "not a registry deck name: " + $deck);
    }
    # The scope check runs before the existence check, so a caller with no rights
    # to a scope cannot learn which versions it holds by watching 404 vs 403.
    def verdict as policy.Decision init scope.authorise($db, $who,
        deckname.scopeOf($deck));
    if (not $verdict.allowed) {
        return refuse($db, 403, $verdict.reason);
    }
    if (not store.hasVersion($db, $deck, $version)) {
        return refuse($db, 404, "no such version: " + $deck + "@" + $version);
    }
    def body as json.Value init json.map();
    $body = json.set($body, "/name", $deck);
    $body = json.set($body, "/version", $version);
    $body = json.set($body, "/yanked", $yanked);
    if (store.isYanked($db, $deck, $version) == $yanked) {
        # Idempotent: asking for the state it is already in is a success, so a
        # retried request after a lost response does not read as a failure.
        return PublishReply{
            status: 200, body: $body, db: $db, changed: false, event: audit.none()
        };
    }
    return PublishReply{
        status: 200,
        body: $body,
        db: store.setYanked($db, $deck, $version, $yanked),
        changed: true,
        event: audit.versionYanked($deck, $version, $yanked)
    };
}
