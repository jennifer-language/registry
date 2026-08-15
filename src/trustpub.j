# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Trusted publishing: letting a CI job publish with no stored credential
 * (specification 8.9).
 *
 * A device grant needs a human at a browser, which a pipeline does not have. The
 * alternative to a long-lived token in a CI secret is to let the **forge itself**
 * say where a build ran: CI systems mint a short-lived OIDC token per job whose
 * claims name the repository, the workflow, and the ref. The registry verifies
 * that token against the issuer's published keys and matches its claims to a
 * binding an owner registered in advance.
 *
 * That is stronger than asking the forge about the caller (7.1 route A) and
 * cheaper than verifying a signature the caller produced (route B): it is the
 * issuer stating, under its own signature, what ran where. It also yields the
 * `repositoryId` that 7.3 wants recorded, from the party that assigns it.
 *
 * **Everything here is pure.** Claim extraction, audience and issuer checks, ref
 * matching, and the final verdict are functions of their arguments. The one
 * impure step - fetching the issuer's JWKS and checking the signature - lives in
 * the caller, so every decision this module makes is testable without a socket.
 * That matters more here than anywhere else in the tree: this is the code that
 * decides whether an unauthenticated HTTP request may write to the registry.
 *
 * The provider shapes live in one `match` rather than a module each, unlike
 * `identity/` and `forge/`, because a provider contributes no behaviour - only
 * the names of four claims. A vtable per provider would be four files of field
 * lookups.
 * @module trustpub
 * @example
 * import "./trustpub.j" as trustpub;
 * def c as trustpub.Claims init trustpub.claimsFrom("github-actions", $verifiedToken);
 * def v as trustpub.Verdict init trustpub.check($binding, $c, "jennifer-registry");
 */

use strings;
use json;
use convert;
import "http.j" as http;
import "jwt.j" as jwt;
import "./deckname.j" as deckname;

# The providers whose claim shapes are known. A token from anything else is
# refused rather than guessed at: reading the wrong claim would compare a
# repository id against a field the issuer never promised to populate.
export def const GITHUB as string init "github-actions";
export def const GITLAB as string init "gitlab-ci";
export def const GITEA as string init "gitea-actions";

# The issuer GitHub Actions tokens carry. Fixed for github.com; a self-hosted
# GitLab or Gitea issues under its own base URL, which is why those two are
# checked against the deployment's configured issuer instead of a constant.
export def const GITHUB_ISSUER as string init "https://token.actions.githubusercontent.com";

/**
 * The claims this registry cares about, lifted out of a **already
 * signature-verified** token. Extraction is separate from verification so the
 * matching rules can be tested exhaustively against hand-written claim sets.
 * @field provider {string} which issuer shape this was read with
 * @field issuer {string} the `iss` claim
 * @field audience {string} the `aud` claim
 * @field repositoryId {string} the forge's immutable numeric repository id
 * @field repository {string} the repository path, for display only
 * @field workflow {string} the workflow file that ran, without any ref suffix
 * @field ref {string} the git ref the job ran against
 */
export def struct Claims {
    provider as string,
    issuer as string,
    audience as string,
    repositoryId as string,
    repository as string,
    workflow as string,
    ref as string
};

/**
 * A registered trusted publisher: the workload permitted to write to a deck.
 *
 * Keyed on `repositoryId`, never on `repository`, for the reason 8.1 gives about
 * logins: a repository path can be renamed and the freed path claimed by
 * somebody else, so a binding on the path would follow the name rather than the
 * project. The path is carried for display.
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
    return Verdict{ allowed: false, reason: $reason };
}

/**
 * Is this a provider whose claim shape is known?
 * @param provider {string} the provider name
 * @return {bool} true when claims can be read from it
 */
export func isKnownProvider(provider as string) {
    return $provider == GITHUB or $provider == GITLAB or $provider == GITEA;
}

# text reads a claim as a string, returning "" when absent. A numeric claim (a
# repository id is a number on every provider here) is converted, because the
# binding stores it as text and comparing 42 to "42" would silently never match.
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
 * `owner/repo/.github/workflows/publish.yml@refs/tags/v1.2.0`: the workflow and
 * the ref in one string. The ref is matched separately against `refPattern`, so
 * keeping it here would force every binding to name a specific tag.
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
 * The claim names differ per provider, which is the whole reason `provider` is
 * part of a binding. `sub` is deliberately not used as a key: its shape varies
 * by provider and by configuration, so matching on it would be matching on a
 * string whose meaning the issuer may change.
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
        ref: text($doc, "/ref")
    };
    match ($provider) {
        when GITLAB {
            $out.repositoryId = text($doc, "/project_id");
            $out.repository = text($doc, "/project_path");
            $out.workflow = workflowPath(text($doc, "/workflow_ref"));
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

/**
 * Does a ref satisfy a binding's pattern?
 *
 * Only two forms are supported: an exact ref, and a trailing star, as in
 * `refs/tags/` with one appended. That is deliberate. A general glob in an
 * authorisation check
 * is a liability - every additional metacharacter is another chance for a
 * pattern to match more than its author believed - and these two cover what
 * bindings actually express, which is "any tag" or "this branch".
 *
 * An empty pattern means any ref, which is the permissive default a binding
 * **should** narrow.
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
    # A bare "*" is any ref; otherwise the ref must actually extend the prefix.
    return strings.startsWith($ref, $prefix);
}

/**
 * The issuer a provider's token must carry.
 *
 * GitHub Actions on github.com is a fixed string. A self-hosted GitLab, Gitea,
 * or Forgejo issues under its own base URL, so the deployment supplies it; a
 * registry that accepts those providers without configuring an issuer accepts
 * tokens from any instance, which is why an empty expectation is a refusal
 * rather than a wildcard.
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
 * **Assumes the signature and the expiry are already verified.** This is the
 * second half of 8.9: everything a signature does not establish. The order is
 * chosen so the cheapest and most absolute checks come first, and so a refusal
 * names the specific cause rather than a generic denial.
 *
 * The audience check is not a formality. A CI job hands its identity token to
 * whatever action asks for one, and a token minted for another service - or for
 * a **different registry** - is replayable here without it. It is the one check
 * that makes a token useless outside the place it was meant for.
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
    return Verdict{ allowed: true, reason: "published by " + $c.repository + " via " + $c.ref };
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
# The key set is small; a large response here is a sign of something wrong, not
# of a big JWKS.
def const DISCOVERY_PATH as string init "/.well-known/openid-configuration";
def const TIMEOUT_MS as int init 10000;
def const MAX_BYTES as int init 262144;

/**
 * The OIDC discovery document URL for an issuer. Pure, so the join is tested
 * rather than assumed.
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
 * **The only network call in this module.** Two requests: the discovery document
 * names `jwks_uri`, and that is fetched in turn. Following the document rather
 * than guessing the path is what lets an issuer rotate its key location.
 *
 * A caller should cache the result. Fetching per request would put two round
 * trips in front of every publish and make the registry's availability depend on
 * the issuer's.
 * @param issuer {string} the issuer to fetch from
 * @return {string} the raw JWKS JSON
 * @throws {Error} when either request fails or the document has no `jwks_uri`
 */
export func fetchJwks(issuer as string) {
    def headers as map of string to string init { "Accept": "application/json" };
    def disco as http.Response init http.requestWith("GET", discoveryUrl($issuer),
        $headers, "", TIMEOUT_MS, MAX_BYTES);
    def doc as json.Value init json.decode($disco.body);
    if (not json.has($doc, "/jwks_uri")) {
        throw Error{
            kind: "trustpub",
            message: "the OIDC discovery document for " + $issuer + " has no jwks_uri",
            file: "", line: 0, col: 0
        };
    }
    def keys as http.Response init http.requestWith("GET",
        json.asString($doc, "/jwks_uri"), $headers, "", TIMEOUT_MS, MAX_BYTES);
    return $keys.body;
}

/**
 * Verify a CI identity token's signature against a JWKS, and read its claims.
 *
 * **Signature and expiry only.** `jwt.verifyJwks` resolves the `kid`, checks the
 * RS256 signature, and enforces `exp` / `nbf`; it does not check `iss` or `aud`,
 * which is why `check` exists and why calling this alone authorises nothing. The
 * algorithm is pinned to RS256 rather than read from the token, which is what
 * stops the classic confusion attack of a token that nominates `none` or an HMAC
 * the attacker can compute.
 * @param token {string} the raw compact JWT
 * @param jwksJson {string} the issuer's key set
 * @param provider {string} which claim shape to read
 * @return {Claims} the verified token's claims
 * @throws {Error} when the signature, the expiry, or the encoding is bad
 */
export func verified(token as string, jwksJson as string, provider as string) {
    return claimsFrom($provider, jwt.verifyJwks($token, $jwksJson, "RS256"));
}
