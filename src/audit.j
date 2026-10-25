# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The operational log of both binaries.
 *
 * `deckadmin` performs every write and `serve` every read plus the token
 * exchange, so a `Sink` writes to a file as well as the console: the file under
 * `data/` is the record both processes share.
 *
 * An `Event` is pure data (level, message, structured fields) built without I/O,
 * so tests assert what is recorded rather than what reached a file.
 * `log.Logger` carries one sink, so a `Sink` holds two and fans out.
 *
 * No builder takes a credential (bearer token, refresh token, device code,
 * client secret), so none can be logged. Account ids and logins are recorded.
 * @module audit
 * @example
 * import "./audit.j" as audit;
 * def sink as audit.Sink init audit.open("info", "text", "data/registry.log", true);
 * audit.write($sink, audit.deckPublished("@acme/tool", "1.2.0", "git", "9f2c1d4e...", false));
 */

use fs;
use io;
use maps;
use strings;
use convert;
use encoding;
import "log.j" as log;

# The levels, in the order log.j ranks them. Constants, so a typo is a lookup
# error rather than a demoted level.
export def const DEBUG as string init "debug";
export def const INFO as string init "info";
export def const WARN as string init "warn";
export def const ERROR as string init "error";

# The default file, relative to the working directory. `data/` is bind-mounted in
# the container and gitignored, so the log survives a restart and is never
# committed or baked into an image.
export def const DEFAULT_PATH as string init "data/registry.log";

/**
 * One thing that happened, as pure data. `level` is `""` for the null event,
 * which `write` drops.
 * @field level {string} "debug", "info", "warn", "error", or "" for nothing
 * @field message {string} the human-readable summary
 * @field fields {map of string to string} the structured detail
 */
export def struct Event {
    level as string,
    message as string,
    fields as map of string to string
};

/**
 * Where events go. Either half may be absent: `deckadmin` leaves the console off
 * by default, and no configured path means no file.
 * @field console {log.Logger} the console logger (only when hasConsole)
 * @field hasConsole {bool} whether events are written to the console
 * @field file {log.Logger} the file logger (only when hasFile)
 * @field hasFile {bool} whether events are written to a file
 * @field path {string} the configured file path, for reporting ("" when none)
 * @field fileError {string} why the file sink is off despite a path being set
 */
export def struct Sink {
    console as log.Logger,
    hasConsole as bool,
    file as log.Logger,
    hasFile as bool,
    path as string,
    fileError as string
};

/**
 * A sink that writes nothing, for defaults and tests.
 * @return {Sink} a sink with neither half enabled
 */
export func silent() {
    return Sink{
        console: log.new(INFO, "text"),
        hasConsole: false,
        file: log.new(INFO, "text"),
        hasFile: false,
        path: "",
        fileError: ""
    };
}

/**
 * Normalise a configured level; an empty or unrecognised one becomes `info`.
 * Pure.
 * @param level {string} the configured level
 * @return {string} one of "debug", "info", "warn", "error"
 */
export func levelOf(level as string) {
    def want as string init strings.lower(strings.trim($level));
    if ($want == DEBUG or $want == INFO or $want == WARN or $want == ERROR) {
        return $want;
    }
    return INFO;
}

/**
 * Normalise a configured format: `text` for a console, `logfmt` or `json` for a
 * file another tool parses. Pure.
 * @param format {string} the configured format
 * @return {string} one of "text", "logfmt", "json"
 */
export func formatOf(format as string) {
    def want as string init strings.lower(strings.trim($format));
    if ($want == "logfmt" or $want == "json") {
        return $want;
    }
    return "text";
}

/**
 * Build a sink, opening the file if one is configured.
 *
 * The file is probed here so an unwritable path shows in the boot output. A
 * failed probe leaves the file half off with the reason in `fileError`; the
 * registry still serves.
 * @param level {string} the minimum level ("" defaults to info)
 * @param format {string} the record format ("" defaults to text)
 * @param path {string} the log file ("" for none)
 * @param console {bool} whether to also write to standard output
 * @return {Sink} the sink, with `fileError` set when the path could not be opened
 */
export func open(level as string, format as string, path as string, console as bool) {
    def lvl as string init levelOf($level);
    def fmt as string init formatOf($format);
    def out as Sink init Sink{
        console: log.new($lvl, "text"),
        hasConsole: $console,
        file: log.toFile($lvl, $fmt, $path),
        hasFile: false,
        path: strings.trim($path),
        fileError: ""
    };
    if ($out.path == "") {
        return $out;
    }
    try {
        fs.appendString($out.path, "");
        $out.hasFile = true;
    } catch (err) {
        $out.fileError = $err.message;
    }
    return $out;
}

/**
 * A one-line description of where events are going, for the boot output.
 * @param sink {Sink} the sink to describe
 * @return {string} e.g. "console and data/registry.log", or "nowhere"
 */
export func describe(sink as Sink) {
    def parts as list of string init [];
    if ($sink.hasConsole) {
        $parts[] = "console";
    }
    if ($sink.hasFile) {
        $parts[] = $sink.path;
    }
    if (len($parts) == 0) {
        return "nowhere";
    }
    return strings.join($parts, " and ");
}

/**
 * Write an event to every enabled half. A null event (level `""`) is dropped.
 *
 * Never throws: a full disk must not turn a successful publish into a failure or
 * a served request into a 500. `open` catches a path that was never writable.
 * @param sink {Sink} where to write
 * @param ev {Event} the event
 * @return {bool} true when the event was written somewhere
 */
export func write(sink as Sink, ev as Event) {
    if ($ev.level == "") {
        return false;
    }
    $ev = cleaned($ev);
    def wrote as bool init false;
    def lost as string init "";
    if ($sink.hasConsole) {
        try {
            log.at($sink.console, $ev.level, $ev.message, $ev.fields);
            $wrote = true;
        } catch (err) {
            $lost = $err.message;
        }
    }
    if ($sink.hasFile) {
        try {
            log.at($sink.file, $ev.level, $ev.message, $ev.fields);
            $wrote = true;
        } catch (err) {
            $lost = $err.message;
        }
    }
    if (not $wrote and not ($lost == "")) {
        # Every configured half failed; stderr cannot be misconfigured here.
        io.eprintf("audit: dropped %s (%s)\n", $ev.message, $lost);
    }
    return $wrote;
}

# cleaned returns the event with every control character in its message and
# field values written out as `\xNN`. Fields carry request input, and a raw ESC
# or right-to-left override would reach a terminal (`docker logs`, `tail -f`)
# as a command or make one line read as another.
func cleaned(ev as Event) {
    def out as Event init $ev;
    $out.message = printable($ev.message);
    for (def k in $ev.fields) {
        $out.fields[$k] = printable($ev.fields[$k]);
    }
    return $out;
}

# The characters `printable` escapes besides C0 and DEL: the bidirectional
# embeddings, overrides and isolates, which reorder how a line displays.
def const BIDI as string init "\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069";

/**
 * Text with its control characters escaped as `\xNN` per UTF-8 byte, and
 * anything else unchanged. Pure.
 * @param s {string} the text
 * @return {string} the text, safe to print on a terminal
 */
export func printable(s as string) {
    def parts as list of string init [];
    def changed as bool init false;
    for (def ch in strings.chars($s)) {
        if ($ch < " " or $ch == "\u007f" or strings.contains(BIDI, $ch)) {
            def hex as string init encoding.toText(convert.bytesFromString($ch, "utf-8"), "hex");
            for (def at in 0..convert.toInt(len($hex) / 2)) {
                $parts[] = "\\x" + strings.substring($hex, $at * 2, $at * 2 + 2);
            }
            $changed = true;
        } else {
            $parts[] = $ch;
        }
    }
    if (not $changed) {
        return $s;
    }
    return strings.join($parts, "");
}

# --- event builders (pure) ---------------------------------------------------

/**
 * The null event: nothing to record. Dropped by `write`.
 * @return {Event} an event with no level
 */
export func none() {
    def empty as map of string to string init {};
    return Event{level: "", message: "", fields: $empty};
}

/**
 * A general event, for a caller with no purpose-built builder.
 * @param level {string} the level
 * @param message {string} the summary
 * @param fields {map of string to string} the structured detail
 * @return {Event} the event
 */
export func event(level as string, message as string, fields as map of string to string) {
    return Event{level: levelOf($level), message: $message, fields: $fields};
}

/**
 * A version was published. `pin` is the commit for a git version and the
 * checksum for a tar.gz one.
 * @param name {string} the deck name
 * @param version {string} the version
 * @param kind {string} "git" or "tar.gz"
 * @param pin {string} the commit or the checksum
 * @param replaced {bool} whether this overwrote an existing version
 * @return {Event} the event
 */
export func deckPublished(
    name as string,
    version as string,
    kind as string,
    pin as string,
    replaced as bool) {
    def f as map of string to string init {
        "deck": $name,
        "version": $version,
        "kind": $kind,
        "pin": $pin
    };
    if ($replaced) {
        # Replacing a version changes what an existing lockfile resolves to,
        # so it logs at warn.
        return Event{level: WARN, message: "deck version replaced", fields: $f};
    }
    return Event{level: INFO, message: "deck version published", fields: $f};
}

/**
 * A version, or a whole deck, was removed. An empty `version` means the deck.
 * @param name {string} the deck name
 * @param version {string} the version removed, or "" for the whole deck
 * @return {Event} the event
 */
export func deckRemoved(name as string, version as string) {
    def f as map of string to string init {"deck": $name};
    if ($version == "") {
        return Event{level: WARN, message: "deck removed", fields: $f};
    }
    $f["version"] = $version;
    return Event{level: WARN, message: "deck version removed", fields: $f};
}

/**
 * A scope was bound to a principal, or reserved. An empty `subject` is a
 * reservation: registered so nobody may claim it, bound to nobody so nobody may
 * write under it.
 * @param scope {string} the folded scope
 * @param provider {string} the identity provider that issued the subject
 * @param subject {string} the principal, or "" for a reservation
 * @param login {string} the owner's username, a display label
 * @param reassigned {bool} whether this replaced an existing owner
 * @return {Event} the event
 */
export func scopeRegistered(
    scope as string,
    provider as string,
    subject as string,
    login as string,
    reassigned as bool) {
    def f as map of string to string init {"scope": $scope};
    if ($subject == "") {
        return Event{level: INFO, message: "scope reserved", fields: $f};
    }
    $f["provider"] = $provider;
    $f["subject"] = $subject;
    $f["login"] = $login;
    if ($reassigned) {
        # The only way a scope changes hands.
        return Event{level: WARN, message: "scope reassigned", fields: $f};
    }
    return Event{level: INFO, message: "scope granted", fields: $f};
}

/**
 * An identity's refresh tokens were revoked.
 * @param subject {string} the subject whose tokens were dropped
 * @param count {int} how many were dropped
 * @return {Event} the event
 */
export func tokensRevoked(subject as string, count as int) {
    def f as map of string to string init {"subject": $subject, "tokens": convert.toString($count)};
    return Event{level: WARN, message: "refresh tokens revoked", fields: $f};
}

/**
 * A command failed. Recorded so the log shows attempts as well as edits.
 * @param command {string} the command that failed
 * @param reason {string} the operator-facing message
 * @return {Event} the event
 */
export func commandFailed(command as string, reason as string) {
    def f as map of string to string init {"command": $command, "reason": $reason};
    return Event{level: WARN, message: "command failed", fields: $f};
}

/**
 * Fill in the `command` field of an event that carries it blank.
 *
 * A failure is built where it is detected, which does not know the command
 * name; the entry point does, and fills it in here.
 * @param ev {Event} the event to attribute
 * @param command {string} the command name
 * @return {Event} the event, with `command` filled in when it was blank
 */
export func attribute(ev as Event, command as string) {
    if ($ev.level == "" or not maps.has($ev.fields, "command")) {
        return $ev;
    }
    if (not ($ev.fields["command"] == "")) {
        return $ev;
    }
    def out as Event init $ev;
    $out.fields["command"] = $command;
    return $out;
}

/**
 * The address to record for a request: the one a trusted proxy reported, or
 * the connection's peer.
 *
 * The header is consulted only when a deployment names one, since any client
 * can send `X-Forwarded-For`. Naming it asserts that a proxy in front sets it.
 *
 * The last entry of a comma-separated list is taken: the address the nearest
 * proxy saw, the one entry a client cannot write. An appending proxy (nginx's
 * `$proxy_add_x_forwarded_for`) leaves a forged first entry in place. Behind a
 * chain of proxies the last entry is the next proxy out; a header one proxy
 * overwrites, such as Cloudflare's `CF-Connecting-IP`, records the client.
 * @param headerValue {string} the value of the configured header ("" when unset
 *     or absent)
 * @param peer {string} the address of the connection itself
 * @return {string} the address to record
 */
export func clientOf(headerValue as string, peer as string) {
    def raw as string init strings.trim($headerValue);
    if ($raw == "") {
        return $peer;
    }
    def found as string init $peer;
    for (def part in strings.split($raw, ",")) {
        def one as string init strings.trim($part);
        if (not ($one == "")) {
            $found = $one;
        }
    }
    return $found;
}

/**
 * A request arrived. Emitted before the handler runs, so it carries no status;
 * `web` has no after-handler hook.
 * @param method {string} the HTTP method
 * @param path {string} the request path
 * @param client {string} the remote address
 * @return {Event} the event
 */
export func requestSeen(method as string, path as string, client as string) {
    def f as map of string to string init {"method": $method, "path": $path, "client": $client};
    return Event{level: DEBUG, message: "request", fields: $f};
}

/**
 * The server started, with the configuration it runs under.
 * @param addr {string} the listen address
 * @param dbPath {string} the store
 * @param identity {string} the configured identity provider
 * @param authOn {bool} whether the token exchange is served
 * @return {Event} the event
 */
export func serverStarted(addr as string, dbPath as string, identity as string, authOn as bool) {
    def f as map of string to string init {"addr": $addr, "db": $dbPath, "auth": "off"};
    if ($authOn) {
        $f["auth"] = "on";
        $f["identity"] = $identity;
    }
    return Event{level: INFO, message: "registry started", fields: $f};
}

/**
 * A login began: a device authorization was started against the provider.
 * Carries no device code, which is a credential while it lives.
 * @param provider {string} the identity provider
 * @return {Event} the event
 */
export func loginStarted(provider as string) {
    def f as map of string to string init {"identity": $provider};
    return Event{level: INFO, message: "login started", fields: $f};
}

/**
 * A token was issued or refreshed, with the account, login and organisations it
 * carries. The tokens themselves are not arguments.
 *
 * Organisations are recorded because they can come back incomplete without
 * failing: GitHub omits those that have not approved this registry. The log
 * then explains a later refusal to claim an org scope.
 * @param kind {string} "issued" or "refreshed"
 * @param subject {string} the subject the token was minted for
 * @param login {string} the display label
 * @param orgs {string} the organisation logins, comma-separated; "" for none
 * @return {Event} the event
 */
export func tokenIssued(kind as string, subject as string, login as string, orgs as string) {
    def f as map of string to string init {"subject": $subject, "login": $login, "orgs": $orgs};
    return Event{level: INFO, message: "token " + $kind, fields: $f};
}

/**
 * A token exchange was refused. A `202` (still waiting for the user) logs at
 * debug, anything else at warn.
 * @param stage {string} which exchange: "device", "issued", or "refreshed"
 * @param status {int} the HTTP status returned
 * @param reason {string} the error the client was given
 * @return {Event} the event
 */
export func loginRefused(stage as string, status as int, reason as string) {
    def f as map of string to string init {
        "stage": $stage,
        "status": convert.toString($status),
        "reason": $reason
    };
    if ($status == 202) {
        # Polling before the user finished: one line per poll interval.
        return Event{level: DEBUG, message: "login pending", fields: $f};
    }
    return Event{level: WARN, message: "login refused", fields: $f};
}

/**
 * A CI workflow was trusted to publish a deck (specification 8.9). A standing
 * write grant, so it logs at warn.
 * @param deck {string} the deck the workflow may publish
 * @param provider {string} the CI provider
 * @param repositoryId {string} the repository id bound
 * @param repository {string} the repository path, a display label
 * @param pending {bool} whether the deck has no versions yet
 * @return {Event} the event
 */
export func publisherTrusted(
    deck as string,
    provider as string,
    repositoryId as string,
    repository as string,
    pending as bool) {
    def f as map of string to string init {
        "deck": $deck,
        "provider": $provider,
        "repositoryId": $repositoryId,
        "repository": $repository
    };
    if ($pending) {
        $f["pending"] = "true";
    }
    return Event{level: WARN, message: "publisher trusted", fields: $f};
}

/**
 * A deck's trusted publisher was removed.
 * @param deck {string} the deck cut off
 * @param repositoryId {string} the repository that lost the grant
 * @return {Event} the event
 */
export func publisherUntrusted(deck as string, repositoryId as string) {
    def f as map of string to string init {"deck": $deck, "repositoryId": $repositoryId};
    return Event{level: WARN, message: "publisher untrusted", fields: $f};
}

/**
 * A version was withdrawn from new resolutions, or restored. Logs at `warn`
 * because it changes what every fresh resolution produces.
 * @param deck {string} the deck name
 * @param version {string} the version
 * @param yanked {bool} true when withdrawn, false when restored
 * @return {Event} the event
 */
export func versionYanked(deck as string, version as string, yanked as bool) {
    def f as map of string to string init {"deck": $deck, "version": $version};
    if ($yanked) {
        return Event{level: WARN, message: "version yanked", fields: $f};
    }
    return Event{level: WARN, message: "version restored", fields: $f};
}

/**
 * A version was published through the write API. `how` separates a person with
 * a token from a CI token and a trusted CI workload.
 * @param deck {string} the deck name
 * @param version {string} the version
 * @param commit {string} the commit the tag resolved to (the pin)
 * @param repository {string} the repository published from
 * @param how {string} "token", "ci-token" or "trusted-publisher"
 * @return {Event} the event
 */
export func deckPublishedFrom(
    deck as string,
    version as string,
    commit as string,
    repository as string,
    how as string) {
    def f as map of string to string init {
        "deck": $deck,
        "version": $version,
        "pin": $commit,
        "repository": $repository,
        "via": $how
    };
    return Event{level: INFO, message: "deck version published", fields: $f};
}

/**
 * A publish was refused, which is how a misconfigured pipeline shows up.
 * @param reason {string} what the caller was told
 * @param status {int} the HTTP status returned
 * @return {Event} the event
 */
export func publishRefused(reason as string, status as int) {
    def f as map of string to string init {"status": convert.toString($status), "reason": $reason};
    return Event{level: WARN, message: "publish refused", fields: $f};
}

/**
 * A CI token was minted. A standing credential, so it logs at warn. The token
 * itself is not a parameter.
 * @param fingerprint {string} the token's SHA-256
 * @param name {string} the operator's label for it
 * @param covers {string} the scope or deck it may write
 * @param expiresAt {string} when it stops working ("" means never)
 * @return {Event} the event
 */
export func ciTokenMinted(
    fingerprint as string,
    name as string,
    covers as string,
    expiresAt as string) {
    def f as map of string to string init {
        "fingerprint": $fingerprint,
        "name": $name,
        "covers": $covers,
        "expires": "never"
    };
    if (not ($expiresAt == "")) {
        $f["expires"] = $expiresAt;
    }
    return Event{level: WARN, message: "ci token minted", fields: $f};
}

/**
 * A CI token was revoked.
 * @param fingerprint {string} the token's SHA-256
 * @param name {string} the operator's label for it
 * @return {Event} the event
 */
export func ciTokenRevoked(fingerprint as string, name as string) {
    def f as map of string to string init {"fingerprint": $fingerprint, "name": $name};
    return Event{level: WARN, message: "ci token revoked", fields: $f};
}

/**
 * A write was authorised by a CI token. Required by section 8.10: with a
 * standing secret, detection is the remaining control.
 * @param fingerprint {string} the token that authorised it
 * @param name {string} the operator's label for it
 * @param deck {string} what it wrote
 * @return {Event} the event
 */
export func ciTokenUsed(fingerprint as string, name as string, deck as string) {
    def f as map of string to string init {
        "fingerprint": $fingerprint,
        "name": $name,
        "deck": $deck
    };
    return Event{level: INFO, message: "write authorised by ci token", fields: $f};
}

/**
 * The reserved scopes were registered in bulk. `conflicts` counts listed names
 * somebody already owns: an earlier legitimate owner, or a name that should not
 * have been claimable.
 * @param reservedCount {int} how many scopes were newly held
 * @param conflicts {int} how many were left alone because somebody owns them
 * @return {Event} the event
 */
export func scopesReserved(reservedCount as int, conflicts as int) {
    def f as map of string to string init {
        "reserved": convert.toString($reservedCount),
        "conflicts": convert.toString($conflicts)
    };
    return Event{level: WARN, message: "reserved scopes registered", fields: $f};
}

/**
 * A co-owner was added to a scope. It changes who may write, so it logs at warn.
 * @param scope {string} the scope
 * @param provider {string} the identity provider the subject belongs to
 * @param subject {string} the principal added
 * @return {Event} the event
 */
export func coOwnerAdded(scope as string, provider as string, subject as string) {
    def f as map of string to string init {
        "scope": $scope,
        "provider": $provider,
        "subject": $subject
    };
    return Event{level: WARN, message: "co-owner added", fields: $f};
}

/**
 * A co-owner was removed from a scope.
 * @param scope {string} the scope
 * @param provider {string} the identity provider the subject belongs to
 * @param subject {string} the principal removed
 * @return {Event} the event
 */
export func coOwnerRemoved(scope as string, provider as string, subject as string) {
    def f as map of string to string init {
        "scope": $scope,
        "provider": $provider,
        "subject": $subject
    };
    return Event{level: WARN, message: "co-owner removed", fields: $f};
}

/**
 * A TLS certificate is in place. `issuedAt` is what renewal is decided from.
 * @param domains {string} the names the certificate covers
 * @param issuedAt {int} when it was obtained (Unix seconds)
 * @return {Event} the event
 */
export func certificateReady(domains as string, issuedAt as int) {
    def f as map of string to string init {
        "domains": $domains,
        "issuedAt": convert.toString($issuedAt)
    };
    return Event{level: INFO, message: "certificate ready", fields: $f};
}

/**
 * A certificate could not be obtained. Logs at `error`: the registry now serves
 * less than it was configured to.
 * @param domains {string} the names that were requested
 * @param reason {string} what went wrong
 * @return {Event} the event
 */
export func certificateFailed(domains as string, reason as string) {
    def f as map of string to string init {"domains": $domains, "reason": $reason};
    return Event{level: ERROR, message: "certificate unavailable", fields: $f};
}
