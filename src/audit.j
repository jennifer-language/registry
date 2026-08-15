# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The operational log: what the registry did, in one place, from both binaries.
 *
 * The events worth recording are split across two programs. `deckadmin` performs
 * every write - publishing a version, registering a scope, revoking tokens - and
 * `serve` performs every read plus the token exchange. Neither sees the other,
 * so an operator asking "what happened to this registry" has to read both. That
 * is why a `Sink` writes to a **file as well as the console**: the file is the
 * shared record, and `data/` is where both processes can reach it.
 *
 * An `Event` is **pure data** - a level, a message, and structured fields - built
 * by a function that does no I/O, exactly as `apiview.Reply` and `webview.Page`
 * are. That is what makes the interesting half testable: the assertion is that
 * publishing records the commit it pinned, not that a line reached a file.
 *
 * `log.Logger` carries one sink, so a `Sink` here holds two and fans out.
 *
 * **Nothing secret is ever a field.** A bearer token, a refresh token, a device
 * code, and a client secret are all absent by construction: the builders below
 * take no such argument, so there is no call site that could pass one by
 * accident. An account id and a login are recorded, because that is the point of
 * an audit record.
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
import "log.j" as log;

# The levels, in the order log.j ranks them. Exported as constants so a caller
# names a level rather than spelling a string that a typo would silently demote.
export def const DEBUG as string init "debug";
export def const INFO as string init "info";
export def const WARN as string init "warn";
export def const ERROR as string init "error";

# The default file, relative to the working directory. `data/` is bind-mounted in
# the container and gitignored, so a log written here survives a restart without
# ever being committed or baked into an image.
export def const DEFAULT_PATH as string init "data/registry.log";

/**
 * One thing that happened, as pure data. `level` is `""` for the null event,
 * which `write` drops - that is how a command with nothing to record says so
 * without the caller testing for it.
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
 * Where events go. Either half may be absent: `deckadmin` prints its own human
 * output and so leaves the console off by default, and a deployment that has not
 * configured a path gets no file.
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
 * A sink that writes nothing. Useful as a default, and in tests.
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
 * Normalise a configured level, defaulting an empty or unrecognised one to
 * `info` rather than dropping every record. Pure.
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
 * Normalise a configured format. `text` reads well on a console, `logfmt` and
 * `json` are for a file something else will parse. Pure.
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
 * The file is **probed here, at startup**, rather than on the first event: an
 * unwritable path is a configuration mistake an operator should hear about while
 * reading the boot output, not a surprise hours later when the first publish
 * happens. A failed probe leaves the file half off and records why, so the
 * caller can report it and carry on. A registry that cannot write its log still
 * serves decks.
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
 * **A logging failure never propagates.** A full disk must not turn a successful
 * publish into a failed one, nor a served request into a 500, so a sink error is
 * swallowed here. The startup probe in `open` is what catches the mistake that
 * actually matters, which is a path that was never writable at all.
 * @param sink {Sink} where to write
 * @param ev {Event} the event
 * @return {bool} true when the event was written somewhere
 */
export func write(sink as Sink, ev as Event) {
    if ($ev.level == "") {
        return false;
    }
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
        # Every configured half failed. Say so on stderr rather than lose the
        # record silently: this is the only place a caller could learn of it,
        # and stderr is the one sink that cannot itself be misconfigured here.
        io.eprintf("audit: dropped %s (%s)\n", $ev.message, $lost);
    }
    return $wrote;
}

# --- event builders (pure) ---------------------------------------------------

/**
 * The null event: nothing to record. Dropped by `write`.
 * @return {Event} an event with no level
 */
export func none() {
    def empty as map of string to string init {};
    return Event{ level: "", message: "", fields: $empty };
}

/**
 * A general event, for a caller with no purpose-built builder.
 * @param level {string} the level
 * @param message {string} the summary
 * @param fields {map of string to string} the structured detail
 * @return {Event} the event
 */
export func event(level as string, message as string, fields as map of string to string) {
    return Event{ level: levelOf($level), message: $message, fields: $fields };
}

/**
 * A version was published. `pin` is the commit for a git version and the
 * checksum for a tar.gz one - the field is named for what it *is* rather than
 * for which column it came from, because the pin is the thing an audit reader
 * needs to compare against what was actually installed.
 * @param name {string} the deck name
 * @param version {string} the version
 * @param kind {string} "git" or "tar.gz"
 * @param pin {string} the commit or the checksum
 * @param replaced {bool} whether this overwrote an existing version
 * @return {Event} the event
 */
export func deckPublished(name as string, version as string, kind as string,
        pin as string, replaced as bool) {
    def f as map of string to string init {
        "deck": $name,
        "version": $version,
        "kind": $kind,
        "pin": $pin
    };
    if ($replaced) {
        # Republishing a version that already existed changes what an existing
        # lockfile resolves to, which is the one edit here that can break an
        # install that used to work. It is louder than an ordinary publish.
        return Event{ level: WARN, message: "deck version replaced", fields: $f };
    }
    return Event{ level: INFO, message: "deck version published", fields: $f };
}

/**
 * A version, or a whole deck, was removed. An empty `version` means the deck.
 * @param name {string} the deck name
 * @param version {string} the version removed, or "" for the whole deck
 * @return {Event} the event
 */
export func deckRemoved(name as string, version as string) {
    def f as map of string to string init { "deck": $name };
    if ($version == "") {
        return Event{ level: WARN, message: "deck removed", fields: $f };
    }
    $f["version"] = $version;
    return Event{ level: WARN, message: "deck version removed", fields: $f };
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
export func scopeRegistered(scope as string, provider as string, subject as string,
        login as string, reassigned as bool) {
    def f as map of string to string init { "scope": $scope };
    if ($subject == "") {
        return Event{ level: INFO, message: "scope reserved", fields: $f };
    }
    $f["provider"] = $provider;
    $f["subject"] = $subject;
    $f["login"] = $login;
    if ($reassigned) {
        # The only way a scope changes hands. Worth finding in a log later.
        return Event{ level: WARN, message: "scope reassigned", fields: $f };
    }
    return Event{ level: INFO, message: "scope granted", fields: $f };
}

/**
 * An identity's refresh tokens were revoked.
 * @param accountId {string} the subject whose tokens were dropped
 * @param count {int} how many were dropped
 * @return {Event} the event
 */
export func tokensRevoked(accountId as string, count as int) {
    def f as map of string to string init {
        "subject": $accountId,
        "tokens": convert.toString($count)
    };
    return Event{ level: WARN, message: "refresh tokens revoked", fields: $f };
}

/**
 * A command failed. Recorded so a log shows the attempts as well as the edits:
 * a refused publish is how a misconfigured client looks from the server side.
 * @param command {string} the command that failed
 * @param reason {string} the operator-facing message
 * @return {Event} the event
 */
export func commandFailed(command as string, reason as string) {
    def f as map of string to string init {
        "command": $command,
        "reason": $reason
    };
    return Event{ level: WARN, message: "command failed", fields: $f };
}

/**
 * Name the command an event came from, if it does not already carry one.
 *
 * A failure is built where it is detected, deep in the command's own logic,
 * which knows what went wrong but not what the operator typed to get there. The
 * entry point knows the reverse. This is what joins the two without threading
 * the command name through every validation.
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
 * A request arrived. Emitted before the handler runs, so it carries no status:
 * `web` has no after-handler hook, and inventing one by wrapping every handler
 * would put the access log in the way of the thing it observes.
 * @param method {string} the HTTP method
 * @param path {string} the request path
 * @param client {string} the remote address
 * @return {Event} the event
 */
export func requestSeen(method as string, path as string, client as string) {
    def f as map of string to string init {
        "method": $method,
        "path": $path,
        "client": $client
    };
    return Event{ level: DEBUG, message: "request", fields: $f };
}

/**
 * The server started. The one record that says what this process is configured
 * to be, which is the first thing worth knowing when reading a log.
 * @param addr {string} the listen address
 * @param dbPath {string} the store
 * @param identity {string} the configured identity provider
 * @param authOn {bool} whether the token exchange is served
 * @return {Event} the event
 */
export func serverStarted(addr as string, dbPath as string, identity as string,
        authOn as bool) {
    def f as map of string to string init {
        "addr": $addr,
        "db": $dbPath,
        "auth": "off"
    };
    if ($authOn) {
        $f["auth"] = "on";
        $f["identity"] = $identity;
    }
    return Event{ level: INFO, message: "registry started", fields: $f };
}

/**
 * A login began: a device authorization was started against the provider.
 * Carries no code - a device code is a credential for the few minutes it lives.
 * @param provider {string} the identity provider
 * @return {Event} the event
 */
export func loginStarted(provider as string) {
    def f as map of string to string init { "identity": $provider };
    return Event{ level: INFO, message: "login started", fields: $f };
}

/**
 * A token was issued or refreshed. Takes the account and login only; the tokens
 * themselves are never arguments, so they cannot be logged.
 * @param kind {string} "issued" or "refreshed"
 * @param accountId {string} the subject the token was minted for
 * @param login {string} the display label
 * @return {Event} the event
 */
export func tokenIssued(kind as string, accountId as string, login as string) {
    def f as map of string to string init {
        "subject": $accountId,
        "login": $login
    };
    return Event{ level: INFO, message: "token " + $kind, fields: $f };
}

/**
 * A token exchange was refused. The status separates "still waiting for the
 * user" from a genuine failure, which is what makes a polled endpoint readable
 * in a log at all.
 * @param stage {string} which exchange: "device", "token", or "refresh"
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
        # The client is polling and the user has not finished yet. Expected, and
        # frequent: one line per poll interval per login. Not a warning.
        return Event{ level: DEBUG, message: "login pending", fields: $f };
    }
    return Event{ level: WARN, message: "login refused", fields: $f };
}

/**
 * A CI workflow was trusted to publish a deck (specification 8.9). A standing
 * grant to write under a scope, so it is recorded as loudly as a scope grant.
 * @param deck {string} the deck the workflow may publish
 * @param provider {string} the CI provider
 * @param repositoryId {string} the repository id bound
 * @param repository {string} the repository path, a display label
 * @param pending {bool} whether the deck has no versions yet
 * @return {Event} the event
 */
export func publisherTrusted(deck as string, provider as string, repositoryId as string,
        repository as string, pending as bool) {
    def f as map of string to string init {
        "deck": $deck,
        "provider": $provider,
        "repositoryId": $repositoryId,
        "repository": $repository
    };
    if ($pending) {
        $f["pending"] = "true";
    }
    return Event{ level: WARN, message: "publisher trusted", fields: $f };
}

/**
 * A deck's trusted publisher was removed.
 * @param deck {string} the deck cut off
 * @param repositoryId {string} the repository that lost the grant
 * @return {Event} the event
 */
export func publisherUntrusted(deck as string, repositoryId as string) {
    def f as map of string to string init {
        "deck": $deck,
        "repositoryId": $repositoryId
    };
    return Event{ level: WARN, message: "publisher untrusted", fields: $f };
}

/**
 * A version was withdrawn from new resolutions, or restored. Recorded at `warn`
 * because it changes what a fresh resolution produces for everybody, which is
 * the kind of thing an operator looks for after "why did this stop upgrading".
 * @param deck {string} the deck name
 * @param version {string} the version
 * @param yanked {bool} true when withdrawn, false when restored
 * @return {Event} the event
 */
export func versionYanked(deck as string, version as string, yanked as bool) {
    def f as map of string to string init { "deck": $deck, "version": $version };
    if ($yanked) {
        return Event{ level: WARN, message: "version yanked", fields: $f };
    }
    return Event{ level: WARN, message: "version restored", fields: $f };
}

/**
 * A version was published through the write API, and how it was authorised.
 * `how` separates a person with a token from a CI workload, which is the
 * distinction an operator reading the log actually cares about.
 * @param deck {string} the deck name
 * @param version {string} the version
 * @param commit {string} the commit the tag resolved to - the pin
 * @param repository {string} the repository published from
 * @param how {string} "token" or "trusted-publisher"
 * @return {Event} the event
 */
export func deckPublishedFrom(deck as string, version as string, commit as string,
        repository as string, how as string) {
    def f as map of string to string init {
        "deck": $deck,
        "version": $version,
        "pin": $commit,
        "repository": $repository,
        "via": $how
    };
    return Event{ level: INFO, message: "deck version published", fields: $f };
}

/**
 * A publish was refused. Recorded because a rejected publish is how a
 * misconfigured pipeline looks from the server side, and is usually what an
 * operator is looking for when a release did not appear.
 * @param reason {string} what the caller was told
 * @param status {int} the HTTP status returned
 * @return {Event} the event
 */
export func publishRefused(reason as string, status as int) {
    def f as map of string to string init {
        "status": convert.toString($status),
        "reason": $reason
    };
    return Event{ level: WARN, message: "publish refused", fields: $f };
}

/**
 * A CI token was minted. A standing credential now exists, which is a thing an
 * operator should be able to find in the log later, so it is recorded as loudly
 * as a scope grant. The token itself is not a parameter and cannot be logged.
 * @param fingerprint {string} the token's SHA-256
 * @param name {string} the operator's label for it
 * @param covers {string} the scope or deck it may write
 * @param expiresAt {string} when it stops working ("" means never)
 * @return {Event} the event
 */
export func ciTokenMinted(fingerprint as string, name as string, covers as string,
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
    return Event{ level: WARN, message: "ci token minted", fields: $f };
}

/**
 * A CI token was revoked.
 * @param fingerprint {string} the token's SHA-256
 * @param name {string} the operator's label for it
 * @return {Event} the event
 */
export func ciTokenRevoked(fingerprint as string, name as string) {
    def f as map of string to string init {
        "fingerprint": $fingerprint,
        "name": $name
    };
    return Event{ level: WARN, message: "ci token revoked", fields: $f };
}

/**
 * A write was authorised by a CI token. Section 8.10 requires this: once a
 * standing secret exists, detection is the only control left.
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
    return Event{ level: INFO, message: "write authorised by ci token", fields: $f };
}
