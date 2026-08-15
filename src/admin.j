# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The deck-repository maintenance logic: the small set of operations that
 * insert, update, remove, and inspect entries in the registry `flatdb`
 * document. It is the brain behind the `bin/deckadmin` script: `parser`
 * declares the command-line grammar, and each `cmd*` takes the current DB, the
 * parsed command line, and a timestamp, returning an `AdminResult` that carries
 * the (possibly edited) DB, whether anything changed (so the caller knows to
 * `store.save`), and a message to print. Keeping all of it here, rather than in
 * the entry script, makes every branch unit-testable; the entry script only
 * binds the handlers to `args.dispatch`. All editing goes through the `store`
 * module.
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
import "./token.j" as token;
import "semver.j" as semver;

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

/**
 * How this invocation should log. Resolved from the command line and the
 * environment together, so a container sets it once in compose and an operator
 * can still override it for a single command.
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
 * The console defaults **off** here, unlike the server. `deckadmin` already
 * prints a result line, so mirroring every event to the console by default would
 * make each command print itself twice; `--verbose` is for when the structured
 * form is what you want to see.
 * @param r {args.Result} the parsed command line
 * @param envPath {string} JVC_LOG
 * @param envLevel {string} JVC_LOG_LEVEL
 * @param envFormat {string} JVC_LOG_FORMAT
 * @return {LogOptions} the resolved options
 */
export func logOptions(r as args.Result, envPath as string, envLevel as string,
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
    # A file is read by something else later, so it defaults to a parseable
    # format; the console is read by a person, and gets text.
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
            $out[$p] = "*";
        } else {
            $out[strings.trim(strings.substring($p, 0, $sp))] =
                strings.trim(strings.substring($p, $sp + 1, len($p)));
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
# A read records nothing: listing decks is not an event. A failure records a
# `commandFailed`, because a log that shows only what worked hides the
# misconfigured invocation an operator is usually looking for. An edit takes its
# event as an argument, so the command that made the change is also the code that
# describes it - the alternative, reconstructing the event from the message
# string afterwards, would drift the moment a message is reworded.
func readResult(db as flatdb.DB, message as string) {
    return AdminResult{ db: $db, ok: true, changed: false, message: $message,
        event: audit.none() };
}

func failResult(db as flatdb.DB, message as string) {
    return AdminResult{ db: $db, ok: false, changed: false, message: $message,
        event: audit.commandFailed("", $message) };
}

func editResult(db as flatdb.DB, message as string, ev as audit.Event) {
    return AdminResult{ db: $db, ok: true, changed: true, message: $message,
        event: $ev };
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
 * The deckadmin command-line grammar: the subcommands, their positionals, and
 * their flags. Kept here rather than in the entry script so the parse is
 * testable, and so `--help` text is generated from one declaration instead of
 * being maintained by hand.
 * @return {args.Parser} the parser for the whole CLI
 */
export func parser() {
    def p as args.Parser init args.parser("deckadmin",
        "maintain the jvc deck repository. A deck name is scoped (@scope/deck) " +
        "and its scope must be registered first. A git version is pinned by the " +
        "commit its tag pointed at, which is the integrity boundary; a tar.gz " +
        "version is pinned by its checksum.");
    # Logging is configured on the root parser, so these go *before* the command:
    # `deckadmin --log data/registry.log add ...`. `args` hands the accumulated
    # result down into the subcommand parser, which is what makes that work; a
    # flag placed after the command is matched against the command's own grammar
    # and would be rejected as unknown.
    $p = args.flag($p, "log", "", "", "append events to this file (JVC_LOG)");
    $p = args.flag($p, "log-level", "", "",
        "debug, info, warn, or error (JVC_LOG_LEVEL; default info)");
    $p = args.flag($p, "log-format", "", "",
        "text, logfmt, or json (JVC_LOG_FORMAT; default logfmt for a file)");
    $p = args.boolFlag($p, "verbose", "v", "also print each event to the console");
    $p = args.boolFlag($p, "quiet", "q", "suppress the result message");
    $p = args.command($p, "add", "publish a version (an upsert)",
        publishParser("add", "publish a version (an upsert)"));
    $p = args.command($p, "update", "an alias of add",
        publishParser("update", "an alias of add"));

    def rm as args.Parser init args.parser("remove", "remove a version, or a whole deck");
    $rm = args.positional($rm, "deck", "the deck name");
    $rm = args.positionalOpt($rm, "version", "", "the version to remove (omit for the whole deck)");
    $p = args.command($p, "remove", "remove a version, or a whole deck", $rm);

    def ls as args.Parser init args.parser("list", "list decks, or one deck's versions");
    $ls = args.positionalOpt($ls, "deck", "", "the deck whose versions to list");
    $p = args.command($p, "list", "list decks, or one deck's versions", $ls);

    def ns as args.Parser init args.parser("register-namespace", "register a scope");
    $ns = args.positional($ns, "scope", "the scope to register (acme or @acme)");
    $ns = args.flag($ns, "owner", "", "", "the subject id to bind it to (omit to reserve)");
    $ns = args.flag($ns, "provider", "", "github", "the identity provider that issued it");
    $ns = args.flag($ns, "login", "", "", "the owner's username, a display label");
    $p = args.command($p, "register-namespace", "register a scope decks may publish under", $ns);

    def nsl as args.Parser init args.parser("namespaces", "list registered scopes");
    $p = args.command($p, "namespaces", "list registered scopes", $nsl);

    def ct as args.Parser init args.parser("mint-token",
        "mint a CI token for non-interactive publishing");
    $ct = args.positional($ct, "scope", "the scope it may write under");
    $ct = args.flag($ct, "deck", "", "", "narrow it to one deck within that scope");
    $ct = args.flag($ct, "name", "", "ci", "a label, shown in listings");
    $ct = args.flag($ct, "days", "", "90", "how long it lives (0 = never expires)");
    $p = args.command($p, "mint-token", "mint a CI token (shown once)", $ct);

    def ctl as args.Parser init args.parser("tokens", "list CI tokens");
    $p = args.command($p, "tokens", "list CI tokens", $ctl);

    def ctr as args.Parser init args.parser("revoke-token", "revoke one CI token");
    $ctr = args.positional($ctr, "fingerprint", "the token fingerprint from `tokens`");
    $p = args.command($p, "revoke-token", "revoke one CI token", $ctr);

    def yk as args.Parser init args.parser("yank", "withdraw a version from new resolutions");
    $yk = args.positional($yk, "deck", "the deck name");
    $yk = args.positional($yk, "version", "the version to withdraw");
    $p = args.command($p, "yank", "withdraw a version (it stays fetchable)", $yk);

    def uy as args.Parser init args.parser("unyank", "restore a withdrawn version");
    $uy = args.positional($uy, "deck", "the deck name");
    $uy = args.positional($uy, "version", "the version to restore");
    $p = args.command($p, "unyank", "restore a withdrawn version", $uy);

    def tp as args.Parser init args.parser("trust",
        "let a CI workflow publish a deck with no stored credential");
    $tp = args.positional($tp, "deck", "the deck the workflow may publish");
    $tp = args.positional($tp, "repositoryId", "the forge's immutable numeric repository id");
    $tp = args.flag($tp, "provider", "", trustpub.GITHUB,
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
    $rv = args.positional($rv, "accountId", "the numeric GitHub account id");
    $p = args.command($p, "revoke", "invalidate an identity's refresh tokens", $rv);
    return $p;
}

# checkPin validates the delivery pin for a kind, returning "" when it is well
# formed and the operator-facing complaint otherwise. A git version is pinned by
# its commit and a tar.gz version by its checksum; supplying the other kind's
# pin is an error rather than a silent no-op, because it means the operator
# believes something about this version that is not true.
func checkPin(kind as string, ref as string, commit as string, checksum as string) {
    if ($kind == store.KIND_GIT) {
        if ($ref == "" or $commit == "") {
            return "a git version needs both --ref and --commit";
        }
        if (not store.isCommit($commit)) {
            return "not a full 40-character lowercase commit SHA: " + $commit;
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
    # Folded on the way in, so the record is written in exactly one form and a
    # later lookup in any casing finds it (specification 2.1).
    def name as string init deckname.fold(args.asString($r, "deck"));
    def version as string init args.asString($r, "version");
    def url as string init args.asString($r, "url");
    if (not deckname.isValid($name)) {
        return failResult($db, "not a valid deck name: " + $name +
            " (lowercase; the scope may carry hyphens, the deck may not)");
    }
    # A registry deck is always scoped. A bare name denotes a module bundled with
    # the interpreter or a local file, so it is not publishable here.
    if (not deckname.isScoped($name)) {
        return failResult($db, "not a registry deck name: " + $name +
            " (a published deck is scoped, as @scope/deck)");
    }
    if (not semver.isValid($version)) {
        return failResult($db, "not a valid version: " + $version);
    }
    # A scoped deck may only be published under a registered scope.
    def scope as string init deckname.scopeOf($name);
    if (not store.hasNamespace($db, $scope)) {
        return failResult($db, "namespace @" + $scope +
            " is not registered; run 'deckadmin register-namespace " + $scope + "'");
    }
    # The presence of a repository pin is what selects the kind; an absent one
    # means the version is an uploaded artifact and must carry a checksum.
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
        license: ""
    };
    # Whether this overwrites an existing version decides how loudly it is
    # recorded, so it must be asked before the store is edited.
    def replaced as bool init store.hasVersion($db, $name, $version);
    def pin as string init $commit;
    if ($kind == store.KIND_TARGZ) {
        $pin = $checksum;
    }
    def out as flatdb.DB init store.putVersion($db, $name, $description, $ver);
    return editResult($out, "stored " + $name + "@" + $version + " (" + $kind + ")",
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
    def name as string init args.asString($r, "deck");
    def version as string init args.asString($r, "version");
    if ($version == "") {
        if (not store.hasDeck($db, $name)) {
            return failResult($db, "no such deck: " + $name);
        }
        return editResult(store.removeDeck($db, $name), "removed deck " + $name,
            audit.deckRemoved($name, ""));
    }
    if (not store.hasVersion($db, $name, $version)) {
        return failResult($db, "no such version: " + $name + "@" + $version);
    }
    def out as flatdb.DB init store.removeVersion($db, $name, $version);
    return editResult($out, "removed " + $name + "@" + $version,
        audit.deckRemoved($name, $version));
}

/**
 * Register a scope so scoped decks may publish under it.
 *
 * With `--owner` it binds the scope to that principal; without one it reserves
 * the scope **operator-held**, which registers the name so nobody may claim it
 * while binding it to nobody, so nobody may write under it either. Re-running it
 * with an owner is how a scope is reassigned.
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
    # A scope is checked against the *scope* grammar, which permits hyphens; the
    # deck grammar does not, because only the deck half becomes a namespace.
    if (not deckname.isScopeIdent($scope)) {
        return failResult($db, "not a valid scope name: " + $scope +
            " (lowercase letters, digits and hyphens; not leading, trailing or doubled)");
    }
    def owner as string init args.asString($r, "owner");
    if (store.hasNamespace($db, $scope) and $owner == "") {
        return readResult($db, "namespace @" + $scope + " already registered");
    }
    # An operator grant bypasses the policy deliberately: it is the mechanism
    # that covers what derivation cannot, including reassigning a scope after a
    # dispute (specification 8.2), so re-granting an existing scope is allowed.
    def reassigned as bool init store.hasNamespace($db, $scope);
    def out as scope.ClaimResult init scope.grant($db, $scope,
        args.asString($r, "provider"), $owner, args.asString($r, "login"), $now);
    if (not $out.allowed) {
        return failResult($db, $out.reason);
    }
    return editResult($out.db, $out.reason,
        audit.scopeRegistered($scope, args.asString($r, "provider"), $owner,
            args.asString($r, "login"), $reassigned));
}

/**
 * Invalidate every refresh token belonging to an account, which is the operator
 * path the specification requires (section 8.5). Outstanding bearer tokens are
 * signed and stateless, so they run out on their own; what this stops is the
 * holder minting new ones.
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
    return editResult($out, "revoked the refresh tokens of account " + $raw,
        audit.tokensRevoked($raw, $held));
}

/**
 * Mint a CI token: the non-interactive fallback where trusted publishing is
 * unavailable (specification 8.10).
 *
 * **The secret is printed once and never stored.** Only its SHA-256 is written
 * down, so this command is the sole moment the token exists in readable form; if
 * it is lost, the remedy is to revoke and mint another.
 *
 * It expires by default, because a token nobody remembers is the one that leaks.
 * `--days 0` opts out explicitly, which is the point of making it a flag rather
 * than a default.
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
    return editResult(store.putCiToken($db, $rec), strings.join($lines, "\n"),
        audit.ciTokenMinted($rec.fingerprint, $rec.name, $where, $rec.expiresAt));
}

/**
 * List CI tokens. Shows the fingerprint, never anything that could be presented
 * as a credential, plus when each was last used - which is how an unused token
 * gets found and retired.
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
 * Revoke one CI token, without disturbing the others.
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
    return editResult(store.deleteCiToken($db, $fp), "revoked the CI token " + $t.name,
        audit.ciTokenRevoked($fp, $t.name));
}

/**
 * Withdraw a version from new resolutions, or restore it.
 *
 * **Not a deletion.** The version stays in the record and stays fetchable, so a
 * lockfile that already pins it keeps installing; what stops is a *fresh*
 * resolution choosing it (specification 9). Deleting instead would break every
 * consumer who already depends on the version, which punishes them for the
 * publisher's mistake.
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
    return editResult(store.setYanked($db, $name, $version, $yanked),
        $verb + " " + $name + "@" + $version,
        audit.versionYanked($name, $version, $yanked));
}

/**
 * Register a trusted publisher: the CI workflow permitted to publish a deck
 * with no stored credential (specification 8.9).
 *
 * The scope must already be owned, so a binding never bypasses name authority -
 * it only removes the ordering problem of a deck that does not exist yet. A
 * binding on a deck with no versions is **pending**, and the first publish
 * converts it.
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
        return failResult($db, "unknown CI provider: " + $provider +
            " (github-actions, gitlab-ci, or gitea-actions)");
    }
    def repoId as string init strings.trim(args.asString($r, "repositoryId"));
    if ($repoId == "") {
        return failResult($db, "a trusted publisher needs the repository id, " +
            "not the path: a path can be renamed and re-registered by somebody else");
    }
    # Name authority first. A binding is a standing grant to write under a scope,
    # so it is exactly as privileged as a publish and gated the same way.
    def scopeName as string init deckname.scopeOf($deck);
    if (not store.hasNamespace($db, $scopeName)) {
        return failResult($db, "namespace @" + $scopeName +
            " is not registered; run 'deckadmin register-namespace " + $scopeName + "'");
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
    return editResult(store.putBinding($db, $b), $what,
        audit.publisherTrusted($deck, $provider, $repoId, $b.repository, $pending));
}

/**
 * Remove a deck's trusted publisher, which is how a compromised or retired
 * repository is cut off.
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
    return editResult(store.removeBinding($db, $deck),
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
        if ($b.pending) {
            $line = $line + " [pending]";
        }
        $lines[] = $line;
    }
    return readResult($db, strings.join($lines, "\n"));
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
    def msg as string init "namespaces:";
    for (def scope in $scopes) {
        $msg = $msg + "\n  @" + $scope;
    }
    return readResult($db, $msg);
}

/**
 * List every deck, or one deck's versions.
 * @param db {flatdb.DB} the current registry store
 * @param r {args.Result} the parsed command line
 * @param now {string} unused; kept so every command shares one handler shape
 * @return {AdminResult} a read-only result carrying the listing
 */
export func cmdList(db as flatdb.DB, r as args.Result, now as string) {
    def name as string init args.asString($r, "deck");
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
 * Parse an argument vector against the CLI grammar. A thin wrapper over
 * `args.parse` so a caller (and a test) need not build the parser itself.
 * `-h` / `--help` sets the result's `done` flag with `helpText` to print,
 * rather than exiting, so it composes with `try` / `catch`.
 * @param argv {list of string} the argument vector (os.ARGS; index 0 is skipped)
 * @return {args.Result} the parsed command line
 * @throws {Error} kind "args" on an unknown flag, a missing required argument,
 *     or a bad-type value
 */
export func parse(argv as list of string) {
    return args.parse(parser(), $argv);
}
