# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The operator verbs behind `bin/deckadmin`, which only binds them to
 * `args.dispatch`. `parser` declares the grammar; each `cmd*` takes the current
 * DB, the parsed command line and a timestamp, and returns an `AdminResult`
 * with the (possibly edited) DB, whether to `store.save` it, and a message. All
 * editing goes through `store`.
 * @module admin
 * @example
 * import "./admin.j" as admin;
 * def parsed as args.Result init admin.parse(os.ARGS);
 * def r as admin.AdminResult init admin.cmdAdd($db, $parsed, "1700000000");
 * # if ($r.changed) { store.save($r.db); }
 */

use io;
use strings;
use convert;
import "flatdb.j" as flatdb;
import "args.j" as args;
import "./store.j" as store;
import "./deckname.j" as deckname;
import "./scope.j" as scope;
import "./audit.j" as audit;
import "./trustpub.j" as trustpub;
import "./citoken.j" as citoken;
import "./reserved.j" as reserved;
import "./keywords.j" as keywords;
import "./token.j" as token;
import "./constraint.j" as constraint;

/**
 * The outcome of an admin operation.
 * @field db {flatdb.DB} the resulting store (unchanged for read-only commands)
 * @field ok {bool} true when the command succeeded
 * @field changed {bool} true when the store was edited and should be saved
 * @field message {string} the message to print
 * @field event {audit.Event} what to record in the operational log (the null
 *     event for a command that changed nothing worth recording)
 */
export def struct AdminResult {
    db as flatdb.DB,
    ok as bool,
    changed as bool,
    message as string,
    event as audit.Event
};

# ownershipCommands adds the scope-ownership and credential half of the grammar.
# Split out of `parser` for length.
func ownershipCommands(p as args.Parser) {
    def out as args.Parser init $p;
    def ns as args.Parser init args.parser("register-namespace", "register a scope");
    $ns = args.positional($ns, "scope", "the scope to register (acme or @acme)");
    $ns = args.flag($ns, "owner", "", "", "the subject id to bind it to (omit to reserve)");
    $ns = args.flag($ns, "provider", "", "github", "the identity provider that issued it");
    $ns = args.flag($ns, "login", "", "", "the owner's username, a display label");
    $ns = args.boolFlag(
        $ns,
        "org",
        "",
        "the owner is an organisation: authorise by the memberships captured at login (8.7)");
    $out = args.command(
        $out,
        "register-namespace",
        "register a scope decks may publish under",
        $ns);

    def ao as args.Parser init args.parser(
        "add-owner",
        "let another principal write under a scope");
    $ao = args.positional($ao, "scope", "the scope");
    $ao = args.positional($ao, "subject", "the principal id to add");
    $out = args.command($out, "add-owner", "add a co-owner to a scope", $ao);

    def ro as args.Parser init args.parser("remove-owner", "revoke a co-owner");
    $ro = args.positional($ro, "scope", "the scope");
    $ro = args.positional($ro, "subject", "the principal id to remove");
    $out = args.command($out, "remove-owner", "remove a co-owner from a scope", $ro);

    def nsl as args.Parser init args.parser("namespaces", "list registered scopes");
    $nsl = args.boolFlag($nsl, "owned", "", "only scopes that have an owner");
    $nsl = args.boolFlag($nsl, "reserved", "", "only scopes held with no owner");
    $out = args.command($out, "namespaces", "list registered scopes", $nsl);

    def rs as args.Parser init args.parser(
        "reserve-defaults",
        "hold every reserved scope, so nobody can claim one");
    $rs = args.boolFlag($rs, "dry-run", "n", "list what would be reserved, change nothing");
    $out = args.command($out, "reserve-defaults", "hold every reserved scope operator-held", $rs);

    def kw as args.Parser init args.parser(
        "keywords",
        "inspect the refused-keyword list, or encode a term for it");
    $kw = args.positionalList($kw, "words", "terms to encode; with none, print the current list");
    $out = args.command(
        $out,
        "keywords",
        "show the refused-keyword list, or encode terms for it",
        $kw);

    def ct as args.Parser init args.parser(
        "mint-token",
        "mint a CI token for non-interactive publishing");
    $ct = args.positional($ct, "scope", "the scope it may write under");
    $ct = args.flag($ct, "deck", "", "", "narrow it to one deck within that scope");
    $ct = args.flag($ct, "name", "", "ci", "a label, shown in listings");
    $ct = args.flag($ct, "days", "", "90", "how long it lives (0 = never expires)");
    $out = args.command($out, "mint-token", "mint a CI token (shown once)", $ct);

    def ctl as args.Parser init args.parser("tokens", "list CI tokens");
    $out = args.command($out, "tokens", "list CI tokens", $ctl);

    def ctr as args.Parser init args.parser("revoke-token", "revoke one CI token");
    $ctr = args.positional($ctr, "fingerprint", "the token fingerprint from `tokens`");
    $out = args.command($out, "revoke-token", "revoke one CI token", $ctr);
    return $out;
}

/**
 * How this invocation logs, resolved from the command line and the environment.
 * @field path {string} the log file ("" for none)
 * @field level {string} the minimum level
 * @field format {string} the record format
 * @field console {bool} whether to also print each event
 * @field quiet {bool} whether to suppress the human result message
 */
export def struct LogOptions {
    path as string,
    level as string,
    format as string,
    console as bool,
    quiet as bool
};

/**
 * Resolve the logging configuration: a flag beats the environment, which beats
 * the default. Pure, so the precedence is testable without a process.
 *
 * The console defaults off, unlike the server, because `deckadmin` already
 * prints a result line; `--verbose` turns it on.
 * @param r {args.Result} the parsed command line
 * @param envPath {string} REGISTRY_LOG
 * @param envLevel {string} REGISTRY_LOG_LEVEL
 * @param envFormat {string} REGISTRY_LOG_FORMAT
 * @return {LogOptions} the resolved options
 */
export func logOptions(
    r as args.Result,
    envPath as string,
    envLevel as string,
    envFormat as string) {
    def path as string init args.asString($r, "log");
    if ($path == "") {
        $path = $envPath;
    }
    def level as string init args.asString($r, "log-level");
    if ($level == "") {
        $level = $envLevel;
    }
    def format as string init args.asString($r, "log-format");
    if ($format == "") {
        $format = $envFormat;
    }
    # A file defaults to a parseable format; the console gets text.
    if ($format == "") {
        $format = "logfmt";
    }
    return LogOptions{
        path: $path,
        level: $level,
        format: $format,
        console: args.asBool($r, "verbose"),
        quiet: args.asBool($r, "quiet")
    };
}

# parseRequires parses a "--requires" spec ("dep constraint, dep constraint")
# into a deck-name -> constraint map. A pair with no space defaults to "*".
func parseRequires(spec as string) {
    def out as map of string to string init {};
    if (strings.trim($spec) == "") {
        return $out;
    }
    for (def part in strings.split($spec, ",")) {
        def p as string init strings.trim($part);
        if ($p == "") {
            continue;
        }
        def sp as int init strings.indexOf($p, " ");
        if ($sp < 0) {
            $out[deckname.fold($p)] = "*";
        } else {
            def name as string init strings.trim(strings.substring($p, 0, $sp));
            $out[deckname.fold($name)] = strings.trim(strings.substring($p, $sp + 1, len($p)));
        }
    }
    return $out;
}

# parseList parses a comma-separated "--capabilities" spec ("net, exec") into a
# list, dropping blanks. Order and duplicates are the caller's business.
func parseList(spec as string) {
    def out as list of string init [];
    for (def part in strings.split($spec, ",")) {
        def p as string init strings.trim($part);
        if (not ($p == "")) {
            $out[] = $p;
        }
    }
    return $out;
}

# readResult / failResult / editResult build the three AdminResult shapes.
#
# A read records nothing. A failure records a `commandFailed`, so the log shows
# failed invocations too. An edit takes its event from the command that made
# the change, rather than reconstructing it from the message.
func readResult(db as flatdb.DB, message as string) {
    return AdminResult{db: $db, ok: true, changed: false, message: $message, event: audit.none()};
}

func failResult(db as flatdb.DB, message as string) {
    return AdminResult{
        db: $db,
        ok: false,
        changed: false,
        message: $message,
        event: audit.commandFailed("", $message)
    };
}

func editResult(db as flatdb.DB, message as string, ev as audit.Event) {
    return AdminResult{db: $db, ok: true, changed: true, message: $message, event: $ev};
}

# publishParser builds the shared shape of `add` and `update`, which are the
# same upsert under two names.
func publishParser(name as string, help as string) {
    def p as args.Parser init args.parser($name, $help);
    $p = args.positional($p, "deck", "the scoped deck name, @scope/deck");
    $p = args.positional($p, "version", "the SemVer version to publish");
    $p = args.positional($p, "url", "the git clone URL, or the artifact URL");
    $p = args.positionalOpt($p, "description", "", "a one-line summary of this version");
    $p = args.flag($p, "ref", "", "", "the tag this version was published from (git)");
    $p = args.flag($p, "commit", "", "", "the 40-hex SHA that tag pointed at (git)");
    $p = args.flag($p, "checksum", "", "", "sha256:<hex> of the artifact (tar.gz)");
    $p = args.flag($p, "requires", "", "", "runtime deps: \"dep constraint, ...\"");
    $p = args.flag($p, "engines", "", "", "engines: \"engine range, ...\"");
    $p = args.flag($p, "capabilities", "", "", "host capabilities: \"net, exec\"");
    return $p;
}

/**
 * The deckadmin command-line grammar: subcommands, positionals and flags. Also
 * the source of the `--help` text.
 * @return {args.Parser} the parser for the whole CLI
 */
export func parser() {
    def p as args.Parser init args.parser(
        "deckadmin",
        "maintain the jvc deck repository. A deck name is scoped (@scope/deck) " +
            "and its scope must be registered first. A git version is pinned by the " +
            "commit its tag pointed at, which is the integrity boundary; a tar.gz " +
            "version is pinned by its checksum.");
    # Logging flags belong to the root parser, so they go before the command:
    # `deckadmin --log data/registry.log add ...`. After the command they are
    # matched against its own grammar and rejected as unknown.
    $p = args.flag($p, "log", "", "", "append events to this file (REGISTRY_LOG)");
    $p = args.flag(
        $p,
        "log-level",
        "",
        "",
        "debug, info, warn, or error (REGISTRY_LOG_LEVEL; default info)");
    $p = args.flag(
        $p,
        "log-format",
        "",
        "",
        "text, logfmt, or json (REGISTRY_LOG_FORMAT; default logfmt for a file)");
    $p = args.boolFlag($p, "verbose", "v", "also print each event to the console");
    $p = args.boolFlag($p, "quiet", "q", "suppress the result message");
    $p = args.command(
        $p,
        "add",
        "publish a version (an upsert)",
        publishParser("add", "publish a version (an upsert)"));
    $p = args.command($p, "update", "an alias of add", publishParser("update", "an alias of add"));

    def rm as args.Parser init args.parser("remove", "remove a version, or a whole deck");
    $rm = args.positional($rm, "deck", "the deck name");
    $rm = args.positionalOpt($rm, "version", "", "the version to remove (omit for the whole deck)");
    $p = args.command($p, "remove", "remove a version, or a whole deck", $rm);

    def ls as args.Parser init args.parser("list", "list decks, or one deck's versions");
    $ls = args.positionalOpt($ls, "deck", "", "the deck whose versions to list");
    $p = args.command($p, "list", "list decks, or one deck's versions", $ls);

    $p = ownershipCommands($p);
    def yk as args.Parser init args.parser("yank", "withdraw a version from new resolutions");
    $yk = args.positional($yk, "deck", "the deck name");
    $yk = args.positional($yk, "version", "the version to withdraw");
    $p = args.command($p, "yank", "withdraw a version (it stays fetchable)", $yk);

    def uy as args.Parser init args.parser("unyank", "restore a withdrawn version");
    $uy = args.positional($uy, "deck", "the deck name");
    $uy = args.positional($uy, "version", "the version to restore");
    $p = args.command($p, "unyank", "restore a withdrawn version", $uy);

    def tp as args.Parser init args.parser(
        "trust",
        "let a CI workflow publish a deck with no stored credential");
    $tp = args.positional($tp, "deck", "the deck the workflow may publish");
    $tp = args.positional($tp, "repositoryId", "the forge's immutable numeric repository id");
    $tp = args.flag(
        $tp,
        "provider",
        "",
        trustpub.GITHUB,
        "github-actions, gitlab-ci, or gitea-actions");
    $tp = args.flag($tp, "repository", "", "", "the repository path, a display label");
    $tp = args.flag($tp, "workflow", "", "", "the workflow file permitted to publish");
    $tp = args.flag($tp, "refs", "", "refs/tags/*", "which refs may publish");
    $p = args.command($p, "trust", "register a trusted publisher for a deck", $tp);

    def tpl as args.Parser init args.parser("publishers", "list trusted publishers");
    $p = args.command($p, "publishers", "list trusted publishers", $tpl);

    def tpr as args.Parser init args.parser("untrust", "remove a trusted publisher");
    $tpr = args.positional($tpr, "deck", "the deck to cut off");
    $p = args.command($p, "untrust", "remove a deck's trusted publisher", $tpr);

    def rv as args.Parser init args.parser("revoke", "invalidate an identity's tokens");
    $rv = args.positional($rv, "accountId", "the numeric account id at the identity provider");
    $p = args.command($p, "revoke", "invalidate an identity's refresh tokens", $rv);
    return $p;
}

# checkPin validates the delivery pin for a kind, returning "" when it is well
# formed and the operator-facing complaint otherwise. A git version is pinned by
# its commit and a tar.gz version by its checksum; supplying the other kind's
# pin is an error.
func checkPin(kind as string, ref as string, commit as string, checksum as string) {
    if ($kind == store.KIND_GIT) {
        if ($ref == "" or $commit == "") {
            return "a git version needs both --ref and --commit";
        }
        if (not store.isCommit($commit)) {
            return "not a full 40-character lowercase commit SHA: " + $commit;
        }
        # As in the publish endpoint: a client that resolves a name before an
        # object would follow a ref shaped like an object id instead of the pin.
        # A record written here is indistinguishable from one written over HTTP.
        if (store.isObjectIdLike($ref)) {
            return "--ref " + $ref + " is shaped like a git object id, which a " +
                "client can resolve as a commit; use a tag that cannot be read as one";
        }
        if (not ($checksum == "")) {
            return "--checksum does not apply to a git version; the commit is the pin";
        }
        return "";
    }
    if ($checksum == "") {
        return "a tar.gz version needs --checksum sha256:<hex>, " +
            "or pass --ref and --commit to publish from a repository";
    }
    if (not store.isChecksum($checksum)) {
        return "not a sha256:<64 lowercase hex digits> checksum: " + $checksum;
    }
    return "";
}

# The schemes a version's URL may use. Anything else (empty, `javascript:`, a
# bare word) is a record no client can fetch from.
def const URL_SCHEMES as list of string init ["https://", "http://", "ssh://", "git://", "file://"];

# urlProblem is why a version's URL cannot be stored, or "". Looser than the
# publish endpoint's `forge.repositoryProblem`, which knows the forge: an
# operator may record a mirror or a local path. Whitespace, quotes and angle
# brackets are refused because the URL is printed into pages and shell snippets.
func urlProblem(url as string) {
    def known as bool init false;
    for (def scheme in URL_SCHEMES) {
        if (strings.startsWith($url, $scheme) and len($url) > len($scheme)) {
            $known = true;
        }
    }
    if (not $known) {
        return "not a fetchable URL: " + $url + " (" + strings.join(URL_SCHEMES, ", ") + ")";
    }
    for (def ch in strings.chars($url)) {
        if ($ch <= " " or $ch == "\u007f" or strings.contains("\"'<>`\\", $ch)) {
            return "the URL has a space, quote, or control character in it: " + $url;
        }
    }
    return "";
}

/**
 * Publish a version (the `add` / `update` upsert). Reads its arguments from the
 * parsed command line and returns the edited store; the caller persists it when
 * `changed` is set.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} the publish timestamp (Unix seconds as text)
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdAdd(db as flatdb.DB, r as args.Result, now as string) {
    def requires as map of string to string init parseRequires(args.asString($r, "requires"));
    def engines as map of string to string init parseRequires(args.asString($r, "engines"));
    def capabilities as list of string init parseList(args.asString($r, "capabilities"));
    def ref as string init args.asString($r, "ref");
    def commit as string init args.asString($r, "commit");
    def checksum as string init args.asString($r, "checksum");
    # Folded on the way in, so a lookup in any casing finds it (specification 2.1).
    def name as string init deckname.fold(args.asString($r, "deck"));
    def version as string init args.asString($r, "version");
    def url as string init args.asString($r, "url");
    if (not deckname.isValid($name)) {
        return failResult(
            $db,
            "not a valid deck name: " + $name +
                " (lowercase; the scope may carry hyphens, the deck may not)");
    }
    # A bare name denotes a bundled module or a local file, so only scoped names
    # are publishable.
    if (not deckname.isScoped($name)) {
        return failResult(
            $db,
            "not a registry deck name: " + $name +
                " (a published deck is scoped, as @scope/deck)");
    }
    if (not constraint.isUsableVersion($version)) {
        return failResult(
            $db,
            "not a valid version: " + $version +
                " (SemVer, with no number longer than 18 digits)");
    }
    # The rules a publish applies to `[decks]` (manifest.j).
    for (def dep in $requires) {
        if (not deckname.isValid($dep) or not deckname.isScoped($dep)) {
            return failResult($db, "not a deck name in --requires: " + $dep);
        }
        if (not constraint.isValidConstraint($requires[$dep])) {
            return failResult(
                $db,
                "not a valid version constraint for " + $dep + ": " +
                    $requires[$dep]);
        }
    }
    for (def engine in $engines) {
        if (not constraint.isValidConstraint($engines[$engine])) {
            return failResult(
                $db,
                "not a valid version constraint for engine " + $engine + ": " +
                    $engines[$engine]);
        }
    }
    def urlComplaint as string init urlProblem($url);
    if (not ($urlComplaint == "")) {
        return failResult($db, $urlComplaint);
    }
    # A scoped deck may only be published under a registered scope.
    def scope as string init deckname.scopeOf($name);
    if (not store.hasNamespace($db, $scope)) {
        return failResult(
            $db,
            "namespace @" + $scope +
                " is not registered; run 'deckadmin register-namespace " + $scope + "'");
    }
    # A repository pin selects git; without one the version is an artifact and
    # needs a checksum.
    def kind as string init store.KIND_TARGZ;
    if (not ($ref == "") or not ($commit == "")) {
        $kind = store.KIND_GIT;
    }
    def complaint as string init checkPin($kind, $ref, $commit, $checksum);
    if (not ($complaint == "")) {
        return failResult($db, $complaint);
    }
    def description as string init args.asString($r, "description");
    def ver as store.DeckVersion init store.DeckVersion{
        version: $version,
        kind: $kind,
        url: $url,
        ref: $ref,
        commit: $commit,
        checksum: $checksum,
        requires: $requires,
        engines: $engines,
        capabilities: $capabilities,
        description: $description,
        publishedAt: $now,
        yanked: false,
        license: "",
        keywords: []
    };
    # A version is replaced only by its exact string; a twin differing only in
    # build metadata would put a second commit behind one version number.
    def twin as string init store.publishedAs($db, $name, $version);
    if (not ($twin == "" or $twin == $version)) {
        return failResult(
            $db,
            $name + "@" + $twin + " is the same version as " + $version +
                " (build metadata does not count); give " + $twin + " to replace it");
    }
    # Asked before the edit: a replacement logs at a higher level.
    def replaced as bool init store.hasVersion($db, $name, $version);
    def pin as string init $commit;
    if ($kind == store.KIND_TARGZ) {
        $pin = $checksum;
    }
    def out as flatdb.DB init store.putVersion($db, $name, $description, $ver);
    return editResult(
        $out,
        "stored " + $name + "@" + $version + " (" + $kind + ")",
        audit.deckPublished($name, $version, $kind, $pin, $replaced));
}

/**
 * Remove one version, or a whole deck when no version is given.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} unused; kept so every command shares one handler shape
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdRemove(db as flatdb.DB, r as args.Result, now as string) {
    def name as string init deckname.fold(args.asString($r, "deck"));
    def version as string init args.asString($r, "version");
    if ($version == "") {
        if (not store.hasDeck($db, $name)) {
            return failResult($db, "no such deck: " + $name);
        }
        return editResult(
            store.removeDeck($db, $name),
            "removed deck " + $name,
            audit.deckRemoved($name, ""));
    }
    if (not store.hasVersion($db, $name, $version)) {
        return failResult($db, "no such version: " + $name + "@" + $version);
    }
    def out as flatdb.DB init store.removeVersion($db, $name, $version);
    return editResult(
        $out,
        "removed " + $name + "@" + $version,
        audit.deckRemoved($name, $version));
}

/**
 * Register a scope so scoped decks may publish under it.
 *
 * With `--owner` it binds the scope to that principal; without one it reserves
 * the scope operator-held: nobody may claim it or write under it. Re-running it
 * with an owner reassigns the scope.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} the registration timestamp (Unix seconds as text)
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdRegisterNamespace(db as flatdb.DB, r as args.Result, now as string) {
    def scope as string init deckname.fold(args.asString($r, "scope"));
    # accept either "@jennifer" or "jennifer"
    if (strings.startsWith($scope, "@")) {
        $scope = strings.substring($scope, 1, len($scope));
    }
    # The scope grammar permits hyphens; the deck grammar does not.
    if (not deckname.isScopeIdent($scope)) {
        return failResult(
            $db,
            "not a valid scope name: " + $scope +
                " (lowercase letters, digits and hyphens; not leading, trailing or doubled)");
    }
    def owner as string init args.asString($r, "owner");
    if (store.hasNamespace($db, $scope) and $owner == "") {
        return readResult($db, "namespace @" + $scope + " already registered");
    }
    # An operator grant bypasses the policy and may re-grant an existing scope:
    # it covers what derivation cannot, such as a dispute (specification 8.2).
    def reassigned as bool init store.hasNamespace($db, $scope);
    # A change of owner drops the old owner's CI tokens and trusted publishers.
    # Re-granting to the same owner (a kind change, say) keeps them.
    def handover as bool init false;
    if ($reassigned) {
        def before as store.Namespace init store.getNamespace($db, $scope);
        $handover = not ($before.subject == $owner and
            $before.provider == args.asString($r, "provider"));
    }
    def kind as string init store.SCOPE_USER;
    if (args.asBool($r, "org")) {
        $kind = store.SCOPE_ORG;
    }
    def out as scope.ClaimResult init scope.grantAs(
        $db,
        $scope,
        args.asString($r, "provider"),
        $owner,
        args.asString($r, "login"),
        $kind,
        $now);
    if (not $out.allowed) {
        return failResult($db, $out.reason);
    }
    def granted as flatdb.DB init $out.db;
    def message as string init $out.reason;
    if ($handover) {
        $granted = store.dropDelegations($granted, $scope);
        $message = $message + "; its CI tokens and trusted publishers were dropped";
    }
    return editResult(
        $granted,
        $message,
        audit.scopeRegistered(
            $scope,
            args.asString($r, "provider"),
            $owner,
            args.asString($r, "login"),
            $reassigned));
}

/**
 * Invalidate every refresh token of an account (specification 8.5). Issued
 * bearer tokens are stateless and expire on their own.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} unused; kept so every command shares one handler shape
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdRevoke(db as flatdb.DB, r as args.Result, now as string) {
    def raw as string init args.asString($r, "accountId");
    def id as int init 0;
    try {
        $id = convert.toInt($raw);
    } catch (err) {
        return failResult($db, "not a numeric account id: " + $raw);
    }
    def held as int init store.countRefresh($db, $id);
    def out as flatdb.DB init store.revokeAccount($db, $id);
    return editResult(
        $out,
        "revoked the refresh tokens of account " + $raw,
        audit.tokensRevoked($raw, $held));
}

/**
 * Register every reserved scope operator-held, so no self-service claim can take
 * one (see `reserved.j` for what is on the list and why brands are not).
 *
 * Idempotent, and never touches an existing scope: an owned name is reported and
 * left alone. Taking a name back is an operator grant. `--dry-run` prints the
 * plan.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} the registration timestamp (Unix seconds as text)
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdReserveDefaults(db as flatdb.DB, r as args.Result, now as string) {
    def names as list of string init reserved.defaults();
    def malformed as list of string init reserved.invalidAmong($names);
    if (len($malformed) > 0) {
        return failResult(
            $db,
            "the reserved list contains names the grammar rejects: " +
                strings.join($malformed, ", "));
    }
    def dry as bool init args.asBool($r, "dry-run");
    def out as flatdb.DB init $db;
    def added as list of string init [];
    def held as list of string init [];
    def owned as list of string init [];
    for (def name in $names) {
        if (not store.hasNamespace($db, $name)) {
            $added[] = $name;
            if (not $dry) {
                $out = scope.grant($out, $name, "", "", "", $now).db;
            }
            continue;
        }
        if (store.getNamespace($db, $name).subject == "") {
            $held[] = $name;
        } else {
            $owned[] = $name;
        }
    }
    def lines as list of string init [];
    if ($dry) {
        $lines[] = "dry run; nothing was changed.";
    }
    $lines[] = "would reserve " + convert.toString(len($added)) + " scope(s)";
    if (not $dry) {
        $lines[len($lines) - 1] = "reserved " + convert.toString(len($added)) + " scope(s)";
    }
    if (len($added) > 0) {
        $lines[] = "  " + strings.join($added, " ");
    }
    if (len($held) > 0) {
        $lines[] = "already reserved: " + convert.toString(len($held));
    }
    if (len($owned) > 0) {
        # Somebody owns a listed name: named and left for the operator.
        $lines[] = "OWNED BY SOMEBODY, left untouched: " + strings.join($owned, " ");
    }
    if (len($added) == 0 or $dry) {
        return readResult($db, strings.join($lines, "\n"));
    }
    return editResult(
        $out,
        strings.join($lines, "\n"),
        audit.scopesReserved(len($added), len($owned)));
}

/**
 * Mint a CI token: the non-interactive fallback where trusted publishing is
 * unavailable (specification 8.10).
 *
 * The secret is printed once; only its SHA-256 is stored. A lost token is
 * revoked and replaced.
 *
 * It expires by default (`--days 90`); `--days 0` opts out.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} the minting timestamp (Unix seconds as text)
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdMintToken(db as flatdb.DB, r as args.Result, now as string) {
    def scopeName as string init deckname.fold(args.asString($r, "scope"));
    if (strings.startsWith($scopeName, "@")) {
        $scopeName = strings.substring($scopeName, 1, len($scopeName));
    }
    if (not deckname.isScopeIdent($scopeName)) {
        return failResult($db, "not a valid scope name: " + $scopeName);
    }
    if (not store.hasNamespace($db, $scopeName)) {
        return failResult($db, "namespace @" + $scopeName + " is not registered");
    }
    # A reserved scope has nobody to delegate for, and `publishview.checkDeck`
    # would refuse every use of the token, so refuse to mint it here.
    if (store.getNamespace($db, $scopeName).subject == "") {
        return failResult(
            $db,
            "@" + $scopeName + " is reserved: it is held by " +
                "an operator and has no owner for a token to act for");
    }
    def deck as string init deckname.fold(args.asString($r, "deck"));
    if (not ($deck == "")) {
        if (not deckname.isScoped($deck)) {
            return failResult($db, "not a registry deck name: " + $deck);
        }
        if (not (deckname.scopeOf($deck) == $scopeName)) {
            return failResult($db, $deck + " is not under @" + $scopeName);
        }
    }
    def secret as string init citoken.PREFIX + token.newRefresh();
    def days as int init convert.toInt(args.asString($r, "days"));
    def rec as citoken.Token init citoken.Token{
        fingerprint: token.fingerprint($secret),
        name: args.asString($r, "name"),
        scope: $scopeName,
        deck: $deck,
        provider: "",
        subject: "",
        createdAt: $now,
        expiresAt: citoken.expiryOf(convert.toInt($now), $days * 86400),
        lastUsedAt: ""
    };
    def where as string init "@" + $scopeName;
    if (not ($deck == "")) {
        $where = $deck;
    }
    def lines as list of string init [
        "minted a CI token for " + $where + " (shown once, not recoverable):",
        "",
        "    " + $secret,
        "",
        "fingerprint: " + $rec.fingerprint
    ];
    if ($rec.expiresAt == "") {
        $lines[] = "expires:     never (consider --days)";
    } else {
        $lines[] = "expires:     " + $rec.expiresAt;
    }
    return editResult(
        store.putCiToken($db, $rec),
        strings.join($lines, "\n"),
        audit.ciTokenMinted($rec.fingerprint, $rec.name, $where, $rec.expiresAt));
}

/**
 * List CI tokens by fingerprint, with when each was last used.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} unused; kept so every command shares one handler shape
 * @param now {string} unused; kept so every command shares one handler shape
 * @return {AdminResult} a read-only result carrying the listing
 */
export func cmdTokens(db as flatdb.DB, r as args.Result, now as string) {
    def prints as list of string init store.listCiTokens($db);
    if (len($prints) == 0) {
        return readResult($db, "no CI tokens");
    }
    def lines as list of string init ["CI tokens:"];
    for (def fp in $prints) {
        def t as citoken.Token init store.getCiToken($db, $fp);
        def where as string init "@" + $t.scope;
        if (not ($t.deck == "")) {
            $where = $t.deck;
        }
        def used as string init "never used";
        if (not ($t.lastUsedAt == "")) {
            $used = "last used " + $t.lastUsedAt;
        }
        def expires as string init "no expiry";
        if (not ($t.expiresAt == "")) {
            $expires = "expires " + $t.expiresAt;
        }
        $lines[] = "  " + $t.name + " -> " + $where + " (" + $expires + ", " +
            $used + ")";
        $lines[] = "    " + $fp;
    }
    return readResult($db, strings.join($lines, "\n"));
}

/**
 * Revoke one CI token.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} unused; kept so every command shares one handler shape
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdRevokeToken(db as flatdb.DB, r as args.Result, now as string) {
    def fp as string init strings.trim(args.asString($r, "fingerprint"));
    def t as citoken.Token init store.getCiToken($db, $fp);
    if ($t.fingerprint == "") {
        return failResult($db, "no such token: " + $fp);
    }
    return editResult(
        store.deleteCiToken($db, $fp),
        "revoked the CI token " + $t.name,
        audit.ciTokenRevoked($fp, $t.name));
}

/**
 * Withdraw a version from new resolutions, or restore it.
 *
 * The version stays recorded and fetchable, so a lockfile that pins it still
 * installs; only fresh resolutions skip it (specification 9).
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} unused; kept so every command shares one handler shape
 * @param yanked {bool} true to withdraw, false to restore
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdSetYanked(db as flatdb.DB, r as args.Result, now as string, yanked as bool) {
    def name as string init deckname.fold(args.asString($r, "deck"));
    def version as string init args.asString($r, "version");
    if (not store.hasVersion($db, $name, $version)) {
        return failResult($db, "no such version: " + $name + "@" + $version);
    }
    def verb as string init "yanked";
    if (not $yanked) {
        $verb = "restored";
    }
    if (store.isYanked($db, $name, $version) == $yanked) {
        return readResult($db, $name + "@" + $version + " is already " + $verb);
    }
    return editResult(
        store.setYanked($db, $name, $version, $yanked),
        $verb + " " + $name + "@" + $version,
        audit.versionYanked($name, $version, $yanked));
}

/**
 * Register a trusted publisher: the CI workflow permitted to publish a deck
 * with no stored credential (specification 8.9).
 *
 * The scope must already be owned, so a binding never bypasses name authority.
 * A binding on a deck with no versions is pending until the first publish.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} the registration timestamp (Unix seconds as text)
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdTrust(db as flatdb.DB, r as args.Result, now as string) {
    def deck as string init deckname.fold(args.asString($r, "deck"));
    if (not deckname.isValid($deck) or not deckname.isScoped($deck)) {
        return failResult($db, "not a registry deck name: " + $deck);
    }
    def provider as string init args.asString($r, "provider");
    if (not trustpub.isKnownProvider($provider)) {
        return failResult(
            $db,
            "unknown CI provider: " + $provider +
                " (github-actions, gitlab-ci, or gitea-actions)");
    }
    def repoId as string init strings.trim(args.asString($r, "repositoryId"));
    if ($repoId == "") {
        return failResult(
            $db,
            "a trusted publisher needs the repository id, " +
                "not the path: a path can be renamed and re-registered by somebody else");
    }
    # A binding is a standing write grant, so it is gated like a publish.
    def scopeName as string init deckname.scopeOf($deck);
    if (not store.hasNamespace($db, $scopeName)) {
        return failResult(
            $db,
            "namespace @" + $scopeName +
                " is not registered; run 'deckadmin register-namespace " + $scopeName + "'");
    }
    # A reserved scope has no owner for the publisher to act for; a binding
    # would open a name the registry holds shut.
    if (store.getNamespace($db, $scopeName).subject == "") {
        return failResult(
            $db,
            "@" + $scopeName + " is reserved: it is held by " +
                "an operator and has no owner for a trusted publisher to act for; " +
                "grant it first with 'deckadmin register-namespace " + $scopeName +
                " --owner <id>'");
    }
    def pending as bool init not store.hasDeck($db, $deck);
    def b as trustpub.Binding init trustpub.Binding{
        provider: $provider,
        repositoryId: $repoId,
        repository: args.asString($r, "repository"),
        workflow: args.asString($r, "workflow"),
        refPattern: args.asString($r, "refs"),
        deck: $deck,
        pending: $pending,
        createdAt: $now
    };
    def what as string init "trusted " + $repoId + " to publish " + $deck;
    if ($pending) {
        $what = $what + " (pending: the deck has no versions yet)";
    }
    return editResult(
        store.putBinding($db, $b),
        $what,
        audit.publisherTrusted($deck, $provider, $repoId, $b.repository, $pending));
}

/**
 * Remove a deck's trusted publisher, cutting off its repository.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} unused; kept so every command shares one handler shape
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdUntrust(db as flatdb.DB, r as args.Result, now as string) {
    def deck as string init deckname.fold(args.asString($r, "deck"));
    if (not store.hasBinding($db, $deck)) {
        return failResult($db, "no trusted publisher for " + $deck);
    }
    def b as trustpub.Binding init store.getBinding($db, $deck);
    return editResult(
        store.removeBinding($db, $deck),
        "removed the trusted publisher for " + $deck,
        audit.publisherUntrusted($deck, $b.repositoryId));
}

/**
 * List every deck with a trusted publisher.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} unused; kept so every command shares one handler shape
 * @param now {string} unused; kept so every command shares one handler shape
 * @return {AdminResult} a read-only result carrying the listing
 */
export func cmdPublishers(db as flatdb.DB, r as args.Result, now as string) {
    def decks as list of string init store.listBindings($db);
    if (len($decks) == 0) {
        return readResult($db, "no trusted publishers registered");
    }
    def lines as list of string init ["trusted publishers:"];
    for (def d in $decks) {
        def b as trustpub.Binding init store.getBinding($db, $d);
        def label as string init $b.repository;
        if ($label == "") {
            $label = "repository " + $b.repositoryId;
        }
        def line as string init "  " + $b.deck + " <- " + $label +
            " (" + $b.provider + ", id " + $b.repositoryId + ", " + $b.refPattern + ")";
        if (trustpub.pendingExpired($b, convert.toInt($now))) {
            $line = $line + " [pending, expired]";
        } elseif ($b.pending) {
            $line = $line + " [pending]";
        }
        $lines[] = $line;
    }
    return readResult($db, strings.join($lines, "\n"));
}

/**
 * Add a co-owner: a second principal that may write under a scope.
 *
 * Not a transfer: the scope keeps its one owner, and a co-owner may publish and
 * yank under it. Transfer is `register-namespace`.
 *
 * Co-owners are subject ids under the scope's provider, with no login stored,
 * since only the id authorises.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} unused; kept so every command shares one handler shape
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdAddOwner(db as flatdb.DB, r as args.Result, now as string) {
    def scopeName as string init deckname.fold(args.asString($r, "scope"));
    if (strings.startsWith($scopeName, "@")) {
        $scopeName = strings.substring($scopeName, 1, len($scopeName));
    }
    if (not store.hasNamespace($db, $scopeName)) {
        return failResult($db, "namespace @" + $scopeName + " is not registered");
    }
    def subject as string init strings.trim(args.asString($r, "subject"));
    if ($subject == "") {
        return failResult($db, "a co-owner is a principal id, not a login");
    }
    def ns as store.Namespace init store.getNamespace($db, $scopeName);
    if ($ns.subject == "") {
        return failResult(
            $db,
            "@" + $scopeName + " is reserved and has no owner; " +
                "grant it first with 'register-namespace " + $scopeName + " --owner <id>'");
    }
    if ($ns.subject == $subject) {
        return readResult($db, $subject + " already owns @" + $scopeName);
    }
    def before as int init len(store.ownersOf($db, $scopeName));
    def out as flatdb.DB init store.addCoOwner($db, $scopeName, $subject);
    if (len(store.ownersOf($out, $scopeName)) == $before) {
        return readResult($db, $subject + " is already a co-owner of @" + $scopeName);
    }
    return editResult(
        $out,
        "added " + $subject + " as a co-owner of @" + $scopeName,
        audit.coOwnerAdded($scopeName, $ns.provider, $subject));
}

/**
 * Remove a co-owner. The owner cannot be removed this way, which would leave
 * decks nobody can yank; reassignment is `register-namespace`.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} unused; kept so every command shares one handler shape
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func cmdRemoveOwner(db as flatdb.DB, r as args.Result, now as string) {
    def scopeName as string init deckname.fold(args.asString($r, "scope"));
    if (strings.startsWith($scopeName, "@")) {
        $scopeName = strings.substring($scopeName, 1, len($scopeName));
    }
    if (not store.hasNamespace($db, $scopeName)) {
        return failResult($db, "namespace @" + $scopeName + " is not registered");
    }
    def subject as string init strings.trim(args.asString($r, "subject"));
    def ns as store.Namespace init store.getNamespace($db, $scopeName);
    if ($ns.subject == $subject and not ($subject == "")) {
        return failResult(
            $db,
            $subject + " is the owner of @" + $scopeName +
                ", not a co-owner; reassign it with 'register-namespace " + $scopeName +
                " --owner <id>'");
    }
    def out as flatdb.DB init store.removeCoOwner($db, $scopeName, $subject);
    def before as int init len(store.ownersOf($db, $scopeName));
    if (len(store.ownersOf($out, $scopeName)) == $before) {
        return failResult($db, $subject + " is not a co-owner of @" + $scopeName);
    }
    return editResult(
        $out,
        "removed " + $subject + " from @" + $scopeName,
        audit.coOwnerRemoved($scopeName, $ns.provider, $subject));
}

/**
 * List the registered namespace scopes.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} unused; kept so every command shares one handler shape
 * @param now {string} unused; kept so every command shares one handler shape
 * @return {AdminResult} a read-only result carrying the listing
 */
export func cmdNamespaces(db as flatdb.DB, r as args.Result, now as string) {
    def scopes as list of string init store.listNamespaces($db);
    if (len($scopes) == 0) {
        return readResult($db, "(no namespaces registered)");
    }
    # The reserved defaults are many, so each line says whether the scope has an
    # owner, and `--owned` / `--reserved` filter.
    def onlyOwned as bool init args.asBool($r, "owned");
    def onlyReserved as bool init args.asBool($r, "reserved");
    def lines as list of string init [];
    def owned as int init 0;
    def held as int init 0;
    for (def scope in $scopes) {
        def ns as store.Namespace init store.getNamespace($db, $scope);
        def isHeld as bool init $ns.subject == "";
        if ($isHeld) {
            $held = $held + 1;
        } else {
            $owned = $owned + 1;
        }
        if ($onlyOwned and $isHeld) {
            continue;
        }
        if ($onlyReserved and not $isHeld) {
            continue;
        }
        if ($isHeld) {
            $lines[] = "  @" + $scope + "  (reserved, no owner)";
        } else {
            def who as string init $ns.login;
            if ($who == "") {
                $who = "(no login recorded)";
            }
            def line as string init "  @" + $scope + "  " + $who + " [" +
                $ns.provider + " " + $ns.subject + "]";
            if ($ns.kind == store.SCOPE_ORG) {
                $line = $line + " (org)";
            }
            if (len($ns.coOwners) > 0) {
                $line = $line + " +" + convert.toString(len($ns.coOwners)) +
                    " co-owner(s): " + strings.join($ns.coOwners, " ");
            }
            $lines[] = $line;
        }
    }
    def head as string init "namespaces: " + convert.toString($owned) + " owned, " +
        convert.toString($held) + " reserved";
    if (len($lines) == 0) {
        return readResult($db, $head + "\n  (none matching)");
    }
    return readResult($db, $head + "\n" + strings.join($lines, "\n"));
}

/**
 * List every deck, or one deck's versions.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} unused; kept so every command shares one handler shape
 * @return {AdminResult} a read-only result carrying the listing
 */
export func cmdList(db as flatdb.DB, r as args.Result, now as string) {
    def name as string init deckname.fold(args.asString($r, "deck"));
    if ($name == "") {
        def decks as list of string init store.listDecks($db);
        if (len($decks) == 0) {
            return readResult($db, "(registry is empty)");
        }
        def msg as string init "decks:";
        for (def deck in $decks) {
            def count as int init len(store.listVersions($db, $deck));
            $msg = $msg + "\n  " + $deck + " (" + io.sprintf("%d", $count) + " version(s))";
        }
        return readResult($db, $msg);
    }
    if (not store.hasDeck($db, $name)) {
        return failResult($db, "no such deck: " + $name);
    }
    def msg as string init "versions of " + $name + ":";
    for (def version in store.listVersions($db, $name)) {
        $msg = $msg + "\n  " + $version;
    }
    return readResult($db, $msg);
}

/**
 * `deckadmin keywords`: read the refused-keyword list, or encode terms for it.
 *
 * The list is stored base64 (see `keywords.j`). This command decodes it and
 * encodes additions; it is not an endpoint, so the decoded list is never
 * fetchable.
 *
 * With no arguments it prints the list by group; with words, the lines to paste
 * into the module. Reads and writes nothing, so it needs no registry.
 * @param db {flatdb.DB} the store, returned untouched
 * @param r {args.Result} the parsed command line
 * @param now {string} unused; kept so the shape matches its siblings
 * @return {AdminResult} the listing or the encoded terms
 */
export func cmdKeywords(db as flatdb.DB, r as args.Result, now as string) {
    def words as list of string init args.asList($r, "words");
    if (len($words) == 0) {
        return readResult($db, keywordListing());
    }
    def msg as string init "encoded, newest first - paste into the right group " +
        "in src/keywords.j:";
    for (def word in $words) {
        def folded as string init keywords.fold($word);
        def note as string init "";
        if (not keywords.isWellFormed($folded)) {
            # Lookups run on folded, well-formed keywords, so this never matches.
            $note = "   # WARNING: not a well-formed keyword; it would never match";
        }
        if (keywords.isBlocked($folded)) {
            $note = "   # already refused";
        }
        $msg = $msg + "\n  \"" + keywords.encode($folded) + "\"," + $note;
    }
    return readResult($db, $msg);
}

# keywordListing renders the refused list in plaintext, grouped by reason.
func keywordListing() {
    def msg as string init "refused keywords (decoded; " +
        io.sprintf("%d", len(keywords.blocked())) + " terms)";
    def groups as list of list of string init [
        ["child sexual abuse - never relax this group", "abuse"],
        ["sexual content - refused as a category here", "adult"],
        ["hate speech aimed at people", "slur"]
    ];
    for (def group in $groups) {
        $msg = $msg + "\n\n  " + $group[0] + ":";
        $msg = $msg + "\n    " + strings.join(keywordGroup($group[1]), " ");
    }
    $msg = $msg + "\n\n  also refused as a substring of any longer keyword:";
    $msg = $msg + "\n    " + strings.join(keywords.blockedSubstrings(), " ");
    return $msg;
}

# keywordGroup returns one group of the list by name.
func keywordGroup(which as string) {
    if ($which == "abuse") {
        return keywords.abuse();
    }
    if ($which == "adult") {
        return keywords.adult();
    }
    return keywords.slur();
}

/**
 * Parse an argument vector against the CLI grammar. `-h` / `--help` sets the
 * result's `done` flag with `helpText` to print instead of exiting.
 * @param argv {list of string} the argument vector (os.ARGS; index 0 is skipped)
 * @return {args.Result} the parsed command line
 * @throws {Error} kind "args" on an unknown flag, a missing required argument,
 *     or a bad-type value
 */
export func parse(argv as list of string) {
    return args.parse(parser(), $argv);
}
