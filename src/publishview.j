# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * `POST /publish`, as pure data (specification 7).
 *
 * A publish names a repository and a tag; the forge resolves the tag to a
 * commit and reads `deck.toml` at that commit, and the record comes from there.
 * The request cannot name the deck, so the scope check checks a fact, not a
 * claim.
 *
 * Authorisation covers the halves of 7.1 differently:
 *
 * - **A bearer token** identifies a person and establishes name authority
 *   through the scope binding; source authority is route A, the forge's answer
 *   in `Source.authority` (route B, signed tags, is not built).
 * - **A CI identity token** (8.9) identifies a workload; its repository claim is
 *   the forge attesting where the build ran (route C), settling both halves.
 *
 * Everything here is a function of the store and its arguments. The forge calls
 * that produce a `Source` happen in `bin/serve`, so the order of checks is
 * testable without a network.
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
import "./forge.j" as forge;

/**
 * What the forge produced for a publish request, assembled by the caller.
 * @field repository {string} the clone URL that was published from
 * @field tag {string} the tag named in the request, kept for display
 * @field commit {string} the 40-hex commit that tag resolved to (the pin)
 * @field repoId {string} the forge's immutable numeric repository id
 * @field repoOwnerId {string} the numeric id of the owning account
 * @field repoOwner {string} the owner's name, a display label
 * @field manifestText {string} the bytes of `deck.toml` at that commit
 * @field readmeText {string} the bytes of `README.md` at that commit ("" when
 *     the repository has none; a deck without one is not an error)
 * @field commitShadowed {bool} true when the repository also holds a branch or
 *     tag named exactly like the resolved commit, so the manifest may not have
 *     come from the commit (see `checkSource`)
 * @field entryPresent {bool} true when the tree at that commit holds the entry
 *     module the manifest's name implies, `src/<deck>.j` (specification 6.1)
 * @field authority {forge.Permission} what the forge said about the publishing
 *     account's push access to the repository (7.1 route A); unused by trusted
 *     publishing, whose token already proves the repository
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
    commitShadowed as bool,
    entryPresent as bool,
    authority as forge.Permission
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

# refuse builds a reply that leaves the store untouched. Refusals are logged too,
# since that is how a misconfigured pipeline shows up for an operator.
func refuse(db as flatdb.DB, status as int, reason as string) {
    def body as json.Value init json.map();
    $body = json.set($body, "/error", $reason);
    return PublishReply{
        status: $status,
        body: $body,
        db: $db,
        changed: false,
        event: audit.publishRefused($reason, $status)
    };
}

/**
 * Validate a `Source` before anything is decided from it.
 *
 * The commit becomes the record's identity, so an abbreviated or malformed SHA
 * is refused before it is stored as the pin.
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
    # A tag shaped like an object id is refused: served as `ref`, a client that
    # resolves names before objects would fetch what that ref points at while the
    # record still reads as pinned.
    if (store.isObjectIdLike($src.tag)) {
        return "the tag " + $src.tag + " is shaped like a git object id, " +
            "which a client can resolve as a commit; publish from a tag that " +
            "cannot be read as one, such as v" + $src.tag;
    }
    if (not store.isCommit($src.commit)) {
        return "the tag did not resolve to a full commit SHA: " + $src.commit;
    }
    # The manifest was read through the forge's ref-or-sha parameter, which
    # resolves a name before an object, so a ref named after the commit means
    # the bytes in hand came from that ref. Refused, since they are already wrong.
    if ($src.commitShadowed) {
        return "the repository has a branch or tag named " + $src.commit +
            ", which shadows the commit of that id; delete it and publish again";
    }
    return "";
}

/**
 * Where the entry module of the deck a manifest names must be, or "" when the
 * manifest does not parse or names no valid deck (the parse error is then what
 * the publish reports). The caller asks the forge about this file before
 * `checkRelease` judges the answer.
 * @param manifestText {string} the bytes of `deck.toml` at the commit
 * @return {string} the path, such as `src/routeros.j`, or ""
 */
export func entryPathFor(manifestText as string) {
    def m as manifest.Manifest init manifest.parse($manifestText);
    if (not $m.ok or not deckname.isValid($m.name)) {
        return "";
    }
    return "src/" + deckname.entryFile($m.name);
}

/**
 * The deck name a manifest gives, folded, or "" when it does not parse.
 * @param manifestText {string} the bytes of `deck.toml` at the commit
 * @return {string} the deck name, or ""
 */
export func deckNameOf(manifestText as string) {
    def m as manifest.Manifest init manifest.parse($manifestText);
    if (not $m.ok) {
        return "";
    }
    return deckname.fold($m.name);
}

/**
 * Whether what the commit holds is a release of what its manifest says
 * (specification 7, steps 6 and 8).
 *
 * The tag and the manifest must name the same version, allowing one leading `v`
 * on the tag (2.3); otherwise the record's `ref` and `version` disagree. The
 * tree must hold the entry module, without which a client installs nothing.
 *
 * Neither depends on the store, so both are checked as soon as the manifest is
 * read.
 * @param src {Source} the forge's output
 * @param m {manifest.Manifest} the parsed manifest, already `ok`
 * @return {string} "" when it is a release of what it says, or the complaint
 */
export func checkRelease(src as Source, m as manifest.Manifest) {
    def tagged as string init $src.tag;
    if (strings.startsWith($tagged, "v")) {
        $tagged = strings.substring($tagged, 1, len($tagged));
    }
    if (not ($tagged == $m.version)) {
        return "the tag " + $src.tag + " disagrees with the version in deck.toml, " +
            $m.version + "; tag the release " + $m.version + " or v" + $m.version;
    }
    if (not $src.entryPresent) {
        return "the tree at " + $src.commit + " has no " + entryPathFor($src.manifestText) +
            ", the entry module a deck must contain";
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
        # Already normalised by `manifest.parse`.
        keywords: $m.keywords
    };
    def out as flatdb.DB init store.putVersion($db, $m.name, $m.description, $ver);
    # The README is recorded only when present: an absent one must not blank a
    # previously published one.
    if (not (strings.trim($src.readmeText) == "")) {
        $out = store.putReadme($out, $m.name, $src.readmeText);
    }
    return $out;
}

# succeed writes the version and builds the 201.
func succeed(db as flatdb.DB, m as manifest.Manifest, src as Source, now as string, how as string) {
    def out as flatdb.DB init storeVersion($db, $m, $src, $now);
    def body as json.Value init json.map();
    $body = json.set($body, "/name", $m.name);
    $body = json.set($body, "/version", $m.version);
    $body = json.set($body, "/kind", store.KIND_GIT);
    $body = json.set($body, "/url", $src.repository);
    $body = json.set($body, "/ref", $src.tag);
    $body = json.set($body, "/commit", $src.commit);
    return PublishReply{
        status: 201,
        body: $body,
        db: $out,
        changed: true,
        event: audit.deckPublishedFrom($m.name, $m.version, $src.commit, $src.repository, $how)
    };
}

/**
 * The scope checks every publish makes, whoever is calling.
 *
 * An unknown scope is a refusal naming the missing registration, and a scope
 * held by an operator with no owner is refused too. The version-exists check
 * comes after these in every caller, so "already published" never hides a real
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
    # A registered scope bound to nobody is reserved, and every publish here
    # arrives on a delegated credential, which under no owner acts for nobody.
    # Trusted publishers and CI tokens never consult the namespace, so the check
    # lives in the one place all three paths share. `deckadmin add` bypasses
    # this module, so the operator can still write a reserved scope.
    if (store.getNamespace($db, $scopeName).subject == "") {
        return "@" + $scopeName +
            " is held by an operator and has no owner to publish under it";
    }
    return "";
}

# sourceAuthorityProblem is why the forge's answer does not establish source
# authority (7.1), or "". Only a known grant counts; an unanswered check fails.
func sourceAuthorityProblem(src as Source) {
    if ($src.authority.known and $src.authority.push) {
        return "";
    }
    if ($src.authority.known) {
        return "you may not publish from " + $src.repository + ": " + $src.authority.reason;
    }
    return "could not establish that you may push to " + $src.repository + ": " +
        $src.authority.reason;
}

/**
 * Whose push access a CI-token publish is checked against (7.1, 8.10).
 *
 * A CI token proves nothing about a repository, so an account stands behind it:
 * its recorded minter, otherwise the owner of the scope it writes under. An
 * organisation scope has no person as owner, so a token there needs a recorded
 * minter. Returns an empty subject when nobody qualifies.
 * @param db {flatdb.DB} the store to read
 * @param t {citoken.Token} the token's record
 * @param deckName {string} the deck the manifest names
 * @return {identity.Subject} the account to check, or an empty one
 */
export func ciPrincipal(db as flatdb.DB, t as citoken.Token, deckName as string) {
    def none as map of string to string init {};
    if (not ($t.subject == "")) {
        return identity.Subject{
            provider: $t.provider,
            id: $t.subject,
            login: "",
            orgs: $none,
            orgsCheckedAt: ""
        };
    }
    def scopeName as string init deckname.scopeOf(deckname.fold($deckName));
    if ($scopeName == "" or not store.hasNamespace($db, $scopeName)) {
        return identity.Subject{provider: "", id: "", login: "", orgs: $none, orgsCheckedAt: ""};
    }
    def ns as store.Namespace init store.getNamespace($db, $scopeName);
    if ($ns.kind == store.SCOPE_ORG) {
        return identity.Subject{provider: "", id: "", login: "", orgs: $none, orgsCheckedAt: ""};
    }
    return identity.Subject{
        provider: $ns.provider,
        id: $ns.subject,
        login: $ns.login,
        orgs: $none,
        orgsCheckedAt: ""
    };
}

# alreadyPublished reports whether this version already exists, build metadata
# aside: `1.0.0+b` is the same release as a published `1.0.0+a` (SemVer 10).
# A published version never changes (specification 9), so a lockfile always
# resolves to the same code.
func alreadyPublished(db as flatdb.DB, m as manifest.Manifest) {
    return not (store.publishedAs($db, $m.name, $m.version) == "");
}

# parsed reads the manifest; callers turn a parse failure into a 400. A missing
# or unreadable manifest is reported by the caller before this.
func parsed(src as Source) {
    return manifest.parse($src.manifestText);
}

/**
 * Publish authorised by a bearer token: a person with a scope binding.
 *
 * The token establishes name authority only. Source authority (7.1) comes from
 * `src.authority`, which the caller obtained from the forge.
 * @param db {flatdb.DB} the store
 * @param who {identity.Subject} the authenticated caller
 * @param src {Source} what the forge produced
 * @param now {string} the publish timestamp (Unix seconds as text)
 * @return {PublishReply} the outcome, and the store to persist on success
 */
export func byToken(db as flatdb.DB, who as identity.Subject, src as Source, now as string) {
    def complaint as string init checkSource($src);
    if (not ($complaint == "")) {
        return refuse($db, 400, $complaint);
    }
    def m as manifest.Manifest init parsed($src);
    if (not $m.ok) {
        return refuse($db, 400, $m.error);
    }
    def releaseComplaint as string init checkRelease($src, $m);
    if (not ($releaseComplaint == "")) {
        return refuse($db, 400, $releaseComplaint);
    }
    def deckComplaint as string init checkDeck($db, $m);
    if (not ($deckComplaint == "")) {
        return refuse($db, 403, $deckComplaint);
    }
    def verdict as policy.Decision init scope.authorise($db, $who, deckname.scopeOf($m.name));
    if (not $verdict.allowed) {
        return refuse($db, 403, $verdict.reason);
    }
    # Source authority (7.1) comes after the scope check, so a stranger learns
    # nothing from it, and before the conflict check, which stays last.
    def sourceComplaint as string init sourceAuthorityProblem($src);
    if (not ($sourceComplaint == "")) {
        return refuse($db, 403, $sourceComplaint);
    }
    if (alreadyPublished($db, $m)) {
        return refuse($db, 409, $m.name + "@" + $m.version + " is already published");
    }
    return succeed($db, $m, $src, $now, "token");
}

/**
 * Publish authorised by a CI token (8.10), the fallback where trusted
 * publishing is unavailable.
 *
 * Establishes name authority only, like a bearer token, but bound to one scope
 * or one deck.
 *
 * The token is stamped as used on success (8.10), so unused tokens can be found
 * and retired.
 * @param db {flatdb.DB} the store
 * @param t {citoken.Token} the record found for the presented token
 * @param src {Source} what the forge produced
 * @param now {string} the publish timestamp (Unix seconds as text)
 * @return {PublishReply} the outcome, and the store to persist on success
 */
export func byCiToken(db as flatdb.DB, t as citoken.Token, src as Source, now as string) {
    def complaint as string init checkSource($src);
    if (not ($complaint == "")) {
        return refuse($db, 400, $complaint);
    }
    def m as manifest.Manifest init parsed($src);
    if (not $m.ok) {
        return refuse($db, 400, $m.error);
    }
    def releaseComplaint as string init checkRelease($src, $m);
    if (not ($releaseComplaint == "")) {
        return refuse($db, 400, $releaseComplaint);
    }
    def deckComplaint as string init checkDeck($db, $m);
    if (not ($deckComplaint == "")) {
        return refuse($db, 403, $deckComplaint);
    }
    # Re-read under the caller's lock, so a token revoked during the forge calls
    # does not publish.
    def current as citoken.Token init store.getCiToken($db, $t.fingerprint);
    if ($current.fingerprint == "") {
        return refuse($db, 401, "the CI token was revoked");
    }
    # The token is matched against the name read at the commit, so a token for
    # one deck cannot publish another by naming it in the request.
    def v as citoken.Verdict init citoken.check($current, $m.name, convert.toInt($now));
    if (not $v.allowed) {
        return refuse($db, 403, $v.reason);
    }
    # A CI token is name authority only (8.10); the repository is checked against
    # the account behind it, which `ciPrincipal` chose for the caller.
    def sourceComplaint as string init sourceAuthorityProblem($src);
    if (not ($sourceComplaint == "")) {
        return refuse($db, 403, $sourceComplaint);
    }
    if (alreadyPublished($db, $m)) {
        return refuse($db, 409, $m.name + "@" + $m.version + " is already published");
    }
    def out as PublishReply init succeed($db, $m, $src, $now, "ci-token");
    $out.db = store.touchCiToken($out.db, $t.fingerprint, $now);
    return $out;
}

/**
 * Publish authorised by a CI identity token (8.9): a workload with a binding.
 *
 * The caller has verified the signature; this checks the binding registered for
 * this deck against the claims (audience and issuer included), the repository
 * id against the forge's, and that the run built this tag and commit.
 *
 * The binding is looked up by the deck name from the manifest, so a repository
 * cannot publish to another deck by naming it. No binding is created on first
 * use (8.9 forbids it), since that would let the first publisher capture a name.
 * @param db {flatdb.DB} the store
 * @param claims {trustpub.Claims} the verified token's claims
 * @param audience {string} the audience this registry publishes and requires
 * @param issuer {string} the issuer required for the claims' provider
 * @param src {Source} what the forge produced
 * @param now {string} the publish timestamp (Unix seconds as text)
 * @return {PublishReply} the outcome, and the store to persist on success
 */
export func byTrustedPublisher(
    db as flatdb.DB,
    claims as trustpub.Claims,
    audience as string,
    issuer as string,
    src as Source,
    now as string) {
    def complaint as string init checkSource($src);
    if (not ($complaint == "")) {
        return refuse($db, 400, $complaint);
    }
    def m as manifest.Manifest init parsed($src);
    if (not $m.ok) {
        return refuse($db, 400, $m.error);
    }
    def releaseComplaint as string init checkRelease($src, $m);
    if (not ($releaseComplaint == "")) {
        return refuse($db, 400, $releaseComplaint);
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
    # The build's repository (token) and the URL's repository (forge) must match,
    # or a build in one repository could publish code from another (7.1). An
    # empty forge id is a refusal.
    if ($src.repoId == "" or not ($src.repoId == $claims.repositoryId)) {
        return refuse(
            $db,
            403,
            "the token is for repository " + $claims.repositoryId +
                " but the source is repository " + $src.repoId);
    }
    def run as trustpub.Verdict init
        trustpub.matchesRelease($claims, $src.tag, $src.commit, convert.toInt($now));
    if (not $run.allowed) {
        return refuse($db, 403, $run.reason);
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
 * Authorised as a bearer-token publish, since yanking changes what every fresh
 * resolution produces. Takes a deck name and version, since only a flag on an
 * existing record changes.
 *
 * Reversible. The version stays fetchable, so a lockfile that pins it keeps
 * installing; a mistaken yank is undone by unyanking.
 * @param db {flatdb.DB} the store
 * @param who {identity.Subject} the authenticated caller
 * @param name {string} the deck name
 * @param version {string} the version to withdraw or restore
 * @param yanked {bool} true to withdraw, false to restore
 * @return {PublishReply} the outcome, and the store to persist on success
 */
export func setYanked(
    db as flatdb.DB,
    who as identity.Subject,
    name as string,
    version as string,
    yanked as bool) {
    def deck as string init deckname.fold($name);
    if ($deck == "" or $version == "") {
        return refuse($db, 400, "missing `name` or `version`");
    }
    if (not deckname.isScoped($deck)) {
        return refuse($db, 400, "not a registry deck name: " + $deck);
    }
    # The scope check runs before the existence check, so a caller with no rights
    # to a scope cannot learn which versions it holds by watching 404 vs 403.
    def verdict as policy.Decision init scope.authorise($db, $who, deckname.scopeOf($deck));
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
        # Idempotent, so a retry after a lost response succeeds.
        return PublishReply{status: 200, body: $body, db: $db, changed: false, event: audit.none()};
    }
    return PublishReply{
        status: 200,
        body: $body,
        db: store.setYanked($db, $deck, $version, $yanked),
        changed: true,
        event: audit.versionYanked($deck, $version, $yanked)
    };
}
