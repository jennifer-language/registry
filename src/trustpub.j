# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Trusted publishing: a CI job publishes with no stored credential
 * (specification 8.9).
 *
 * CI systems mint a short-lived OIDC token per job whose claims name the
 * repository, the workflow, and the ref. The registry verifies that token against
 * the issuer's published keys and matches its claims to a binding an owner
 * registered in advance. The issuer attests what ran where, which also yields the
 * `repositoryId` that 7.3 wants recorded.
 *
 * Claim extraction, audience and issuer checks, ref matching, and the verdict are
 * pure. Only `fetchJwks` touches the network, so every decision on whether an
 * unauthenticated request may write is testable without a socket.
 *
 * Provider shapes live in one `match`, unlike `identity/` and `forge/`, because a
 * provider contributes only the names of four claims.
 * @module trustpub
 * @example
 * import "./trustpub.j" as trustpub;
 * def c as trustpub.Claims init trustpub.verified($jwt, $jwksJson, "github-actions");
 * def v as trustpub.Verdict init trustpub.check($binding, $c, "jennifer-registry",
 *     trustpub.expectedIssuer($c.provider, ""));
 */

use strings;
use json;
use convert;
import "http.j" as http;
import "jwt.j" as jwt;
import "./deckname.j" as deckname;

# The providers whose claim shapes are known. A token from anything else is
# refused: reading the wrong claim would compare a repository id against a
# field the issuer never promised to populate.
export def const GITHUB as string init "github-actions";
export def const GITLAB as string init "gitlab-ci";
export def const GITEA as string init "gitea-actions";

# The issuer GitHub Actions tokens carry on github.com. GitLab and Gitea issue
# under their own base URL and are checked against the configured issuer.
export def const GITHUB_ISSUER as string init "https://token.actions.githubusercontent.com";

/**
 * The claims this registry reads from an already signature-verified token.
 * Kept separate from verification so matching is testable on hand-written claims.
 * @field provider {string} which issuer shape this was read with
 * @field issuer {string} the `iss` claim
 * @field audience {string} the `aud` claim
 * @field repositoryId {string} the forge's immutable numeric repository id
 * @field repository {string} the repository path, for display only
 * @field workflow {string} the workflow file that ran, without any ref suffix
 * @field ref {string} the git ref the job ran against, always in its full
 *     `refs/...` form (GitLab's bare name is completed from `ref_type`)
 * @field sha {string} the commit the job ran at ("" when the token has none)
 * @field issuedAt {int} the `iat` claim, Unix seconds (0 when absent)
 */
export def struct Claims {
    provider as string,
    issuer as string,
    audience as string,
    repositoryId as string,
    repository as string,
    workflow as string,
    ref as string,
    sha as string,
    issuedAt as int
};

/**
 * A registered trusted publisher: the workload permitted to write to a deck.
 *
 * Keyed on `repositoryId`, never on `repository`: a renamed repository's freed
 * path can be claimed by somebody else (compare 8.1 on logins). The path is for
 * display.
 * @field provider {string} which issuer this binding accepts
 * @field repositoryId {string} the immutable repository id that may publish
 * @field repository {string} the repository path, a display label
 * @field workflow {string} the workflow file permitted to publish
 * @field refPattern {string} which refs may publish ("" means any)
 * @field deck {string} the deck this binding writes to
 * @field pending {bool} true before the deck exists (8.9 first publish)
 * @field createdAt {string} when it was registered (Unix seconds as text)
 */
export def struct Binding {
    provider as string,
    repositoryId as string,
    repository as string,
    workflow as string,
    refPattern as string,
    deck as string,
    pending as bool,
    createdAt as string
};

/**
 * The outcome of matching a token to a binding.
 * @field allowed {bool} whether the write is authorised
 * @field reason {string} why, phrased for a build log
 */
export def struct Verdict {
    allowed as bool,
    reason as string
};

func no(reason as string) {
    return Verdict{allowed: false, reason: $reason};
}

/**
 * How long a pending binding (8.9 first publish) stays usable, in seconds:
 * 30 days. An unused one must not hold a deck name indefinitely.
 */
export def const PENDING_TTL_SECONDS as int init 2592000;

/**
 * Whether a pending binding has outlived `PENDING_TTL_SECONDS` unused. A
 * settled binding never expires.
 * @param b {Binding} the binding
 * @param now {int} the current time (Unix seconds)
 * @return {bool} true when it may no longer be used
 */
export func pendingExpired(b as Binding, now as int) {
    if (not $b.pending or $b.createdAt == "") {
        return false;
    }
    return $now - convert.toInt($b.createdAt) > PENDING_TTL_SECONDS;
}

/**
 * Whether a presented bearer credential is a CI identity token from `issuer`,
 * read from its unverified `iss`. For routing only (8.9: the token is sent in
 * place of a bearer token); `verified` then checks it in full.
 * @param token {string} the presented credential
 * @param issuer {string} the issuer this registry accepts ("" accepts none)
 * @return {bool} true when it should be verified as an identity token
 */
export func isIdentityToken(token as string, issuer as string) {
    if ($issuer == "" or len(strings.split($token, ".")) != 3) {
        return false;
    }
    try {
        def claims as json.Value init jwt.decode($token);
        return json.has($claims, "/iss") and json.asString($claims, "/iss") == $issuer;
    } catch (err) {
        return false;
    }
}

/**
 * Is this a provider whose claim shape is known?
 * @param provider {string} the provider name
 * @return {bool} true when claims can be read from it
 */
export func isKnownProvider(provider as string) {
    return $provider == GITHUB or $provider == GITLAB or $provider == GITEA;
}

# text reads a claim as a string, "" when absent. A numeric claim (repository
# ids are numbers) is converted, since the binding stores text and 42 never
# equals "42".
func text(doc as json.Value, pointer as string) {
    if (not json.has($doc, $pointer)) {
        return "";
    }
    if (json.typeOf($doc, $pointer) == "int") {
        return convert.toString(json.asInt($doc, $pointer));
    }
    return json.asString($doc, $pointer);
}

/**
 * Strip the `@ref` suffix a workflow claim may carry.
 *
 * GitHub's `job_workflow_ref` is
 * `owner/repo/.github/workflows/publish.yml@refs/tags/v1.2.0`. The ref is
 * matched separately against `refPattern`.
 * @param claim {string} the raw workflow claim
 * @return {string} the workflow path alone
 */
export func workflowPath(claim as string) {
    def at as int init strings.indexOf($claim, "@");
    if ($at < 0) {
        return $claim;
    }
    return strings.substring($claim, 0, $at);
}

/**
 * Read the claims this registry needs from a verified token, for one provider.
 *
 * Claim names differ per provider, hence `provider` in a binding. `sub` is not
 * used: its shape varies by provider and configuration.
 * @param provider {string} which shape to read
 * @param doc {json.Value} the verified token's claim set
 * @return {Claims} the extracted claims; empty fields for an unknown provider
 */
export func claimsFrom(provider as string, doc as json.Value) {
    def out as Claims init Claims{
        provider: $provider,
        issuer: text($doc, "/iss"),
        audience: text($doc, "/aud"),
        repositoryId: "",
        repository: "",
        workflow: "",
        ref: text($doc, "/ref"),
        sha: strings.lower(text($doc, "/sha")),
        issuedAt: 0
    };
    if (json.has($doc, "/iat") and json.typeOf($doc, "/iat") == "int") {
        $out.issuedAt = json.asInt($doc, "/iat");
    }
    match ($provider) {
        when GITLAB {
            $out.repositoryId = text($doc, "/project_id");
            $out.repository = text($doc, "/project_path");
            $out.workflow = workflowPath(text($doc, "/workflow_ref"));
            # GitLab's `ref` is a bare name and `ref_type` says which kind.
            # Completed so a tag pattern means a tag on every provider; a bare
            # pattern such as `v*` would match branches too.
            $out.ref = fullRef($out.ref, text($doc, "/ref_type"));
        }
        when GITHUB, GITEA {
            $out.repositoryId = text($doc, "/repository_id");
            $out.repository = text($doc, "/repository");
            $out.workflow = workflowPath(text($doc, "/job_workflow_ref"));
            if ($out.workflow == "") {
                # Gitea names it plainly; GitHub uses job_workflow_ref.
                $out.workflow = workflowPath(text($doc, "/workflow"));
            }
        }
    }
    return $out;
}

# fullRef completes a bare ref name from its type ("tag" or "branch"). A full
# ref or an unknown type is returned unchanged, so it cannot match a `refs/...`
# pattern.
func fullRef(ref as string, refType as string) {
    if ($ref == "" or strings.startsWith($ref, "refs/")) {
        return $ref;
    }
    match ($refType) {
        when "tag" { return "refs/tags/" + $ref; }
        when "branch" { return "refs/heads/" + $ref; }
    }
    return $ref;
}

/**
 * Does the CI run a token speaks for match the release being published?
 *
 * Without this, any run of a bound workflow could publish any tag of the
 * repository, an older or unreviewed one included. Checks:
 *
 * - the token's `sha`, where it carries one, must be the commit the tag points
 *   at;
 * - a token issued for a tag must be for this tag;
 * - a token must not be issued in the future (8.9 step 2, `iat`), with a minute
 *   of clock skew allowed.
 * @param c {Claims} the verified token's claims
 * @param tag {string} the tag in the publish request
 * @param commit {string} the commit that tag resolved to
 * @param now {int} the current time, Unix seconds
 * @return {Verdict} allowed, or why not
 */
export func matchesRelease(c as Claims, tag as string, commit as string, now as int) {
    if ($c.issuedAt > $now + 60) {
        return no("the token was issued in the future");
    }
    if (not ($c.sha == "") and not ($c.sha == strings.lower($commit))) {
        return no("the token is for a run at commit " + $c.sha + ", but " + $tag +
            " points at " + $commit);
    }
    if (strings.startsWith($c.ref, "refs/tags/") and not ($c.ref == "refs/tags/" + $tag)) {
        return no("the token is for " + $c.ref + ", not for the tag " + $tag);
    }
    return Verdict{allowed: true, reason: "the run built " + $tag};
}

/**
 * Does a ref satisfy a binding's pattern?
 *
 * Two forms only: an exact ref, and a trailing star, as in `refs/tags/` with
 * one appended. Each further metacharacter is another way for a pattern to
 * match more than its author meant.
 *
 * An empty pattern means any ref, a permissive default a binding should narrow.
 * @param pattern {string} the binding's pattern
 * @param ref {string} the ref from the token
 * @return {bool} true when the ref is permitted
 */
export func refMatches(pattern as string, ref as string) {
    if ($pattern == "") {
        return true;
    }
    if (not strings.endsWith($pattern, "*")) {
        return $pattern == $ref;
    }
    def prefix as string init strings.substring($pattern, 0, len($pattern) - 1);
    # A bare "*" is any ref; otherwise the ref must extend the prefix.
    return strings.startsWith($ref, $prefix);
}

/**
 * The issuer a provider's token must carry.
 *
 * GitHub Actions on github.com is a fixed string. A self-hosted GitLab, Gitea,
 * or Forgejo issues under its own base URL, which the deployment supplies. An
 * empty result is a refusal, since a wildcard would accept any instance.
 * @param provider {string} the provider
 * @param configuredIssuer {string} the deployment's configured issuer ("" if none)
 * @return {string} the issuer to require, or "" when none can be determined
 */
export func expectedIssuer(provider as string, configuredIssuer as string) {
    if (not (strings.trim($configuredIssuer) == "")) {
        return strings.trim($configuredIssuer);
    }
    if ($provider == GITHUB) {
        return GITHUB_ISSUER;
    }
    return "";
}

/**
 * Check a verified token's claims against a registered binding.
 *
 * Assumes the signature and expiry are already verified; this is the rest of
 * 8.9. Cheapest checks come first, and a refusal names its cause.
 *
 * Without the audience check, a token minted for another service or another
 * registry would be replayable here.
 * @param b {Binding} the registered binding
 * @param c {Claims} the verified token's claims
 * @param audience {string} the audience this registry published and requires
 * @param issuer {string} the issuer required for this provider
 * @return {Verdict} allow, or refuse naming the cause
 */
export func check(b as Binding, c as Claims, audience as string, issuer as string) {
    if (not isKnownProvider($c.provider)) {
        return no("unknown CI provider: " + $c.provider);
    }
    if (not ($b.provider == $c.provider)) {
        return no("this binding accepts " + $b.provider + ", not " + $c.provider);
    }
    # An unconfigured audience would make every token acceptable, so it is a
    # refusal rather than a skipped check.
    if (strings.trim($audience) == "") {
        return no("this registry has no trusted-publishing audience configured");
    }
    if (not ($c.audience == $audience)) {
        return no("token audience is not this registry");
    }
    if (strings.trim($issuer) == "") {
        return no("no issuer is configured for " + $c.provider);
    }
    if (not ($c.issuer == $issuer)) {
        return no("token was not issued by " + $issuer);
    }
    # An empty id on either side must never match: an absent claim and an
    # unconfigured binding would otherwise authorise each other.
    if ($c.repositoryId == "" or $b.repositoryId == "") {
        return no("the token carries no repository id");
    }
    if (not ($c.repositoryId == $b.repositoryId)) {
        return no("repository " + $c.repository + " is not the one bound to " + $b.deck);
    }
    if (not ($b.workflow == "")) {
        if (not ($c.workflow == $b.workflow)) {
            return no("workflow " + $c.workflow + " is not the one bound to " + $b.deck);
        }
    }
    if (not refMatches($b.refPattern, $c.ref)) {
        return no("ref " + $c.ref + " does not match " + $b.refPattern);
    }
    return Verdict{allowed: true, reason: "published by " + $c.repository + " via " + $c.ref};
}

/**
 * The key a binding is stored and looked up under: the deck it writes to.
 * Folded, so a binding registered for `@Acme/Tool` is found for `@acme/tool`.
 * @param deck {string} the deck name
 * @return {string} the folded key
 */
export func keyFor(deck as string) {
    return deckname.fold($deck);
}

# --- verification (the one impure part) --------------------------------------

# The OIDC discovery path every issuer serves, and the limits on fetching it.
# A key set is small, so a large response means something is wrong.
def const DISCOVERY_PATH as string init "/.well-known/openid-configuration";
def const TIMEOUT_MS as int init 10000;
def const MAX_BYTES as int init 262144;

/**
 * The OIDC discovery document URL for an issuer.
 * @param issuer {string} the issuer, with or without a trailing slash
 * @return {string} the discovery URL
 */
export func discoveryUrl(issuer as string) {
    def base as string init strings.trim($issuer);
    while (strings.endsWith($base, "/")) {
        $base = strings.substring($base, 0, len($base) - 1);
    }
    return $base + DISCOVERY_PATH;
}

/**
 * Fetch an issuer's JWKS, following its discovery document.
 *
 * The only network call in this module: the discovery document names
 * `jwks_uri`, which is fetched in turn, so an issuer can move its keys.
 *
 * A caller should cache the result; fetching per request adds two round trips
 * to every publish and ties availability to the issuer's.
 * @param issuer {string} the issuer to fetch from
 * @return {string} the raw JWKS JSON
 * @throws {Error} when either request fails or the document has no `jwks_uri`
 */
export func fetchJwks(issuer as string) {
    def headers as map of string to string init {"Accept": "application/json"};
    def disco as http.Response init http.requestWith(
        "GET",
        discoveryUrl($issuer),
        $headers,
        "",
        TIMEOUT_MS,
        MAX_BYTES);
    def doc as json.Value init json.decode($disco.body);
    if (not json.has($doc, "/jwks_uri")) {
        throw Error{
            kind: "trustpub",
            message: "the OIDC discovery document for " + $issuer + " has no jwks_uri",
            file: "",
            line: 0,
            col: 0
        };
    }
    def keys as http.Response init http.requestWith(
        "GET",
        json.asString($doc, "/jwks_uri"),
        $headers,
        "",
        TIMEOUT_MS,
        MAX_BYTES);
    return $keys.body;
}

/**
 * Verify a CI identity token's signature against a JWKS, and read its claims.
 *
 * Signature and expiry only: `kid` resolution, the RS256 signature, `exp` and
 * `nbf`, and `requireExp` refuses a token with no `exp` (8.9 step 2). `iss` and
 * `aud` are left to `check`; this alone authorises nothing. The algorithm is
 * pinned to RS256, which stops a token nominating `none` or an attacker-computable
 * HMAC.
 * @param token {string} the raw compact JWT
 * @param jwksJson {string} the issuer's key set
 * @param provider {string} which claim shape to read
 * @return {Claims} the verified token's claims
 * @throws {Error} when the signature, the expiry, or the encoding is bad
 */
export func verified(token as string, jwksJson as string, provider as string) {
    def policy as jwt.Policy init jwt.Policy{iss: "", aud: "", requireExp: true};
    return claimsFrom($provider, jwt.verifyJwksWith($token, $jwksJson, "RS256", $policy));
}
