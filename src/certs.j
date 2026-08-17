# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * TLS certificates from Let's Encrypt, stored under the data directory.
 *
 * The registry already runs an HTTP listener and already owns a writable
 * directory, which is everything the **HTTP-01** challenge needs: the CA asks for
 * a token at `/.well-known/acme-challenge/<token>`, and the answer is a file. So
 * the flow here writes challenge responses to a directory that `bin/serve` serves
 * statically, rather than standing up a second listener or reaching for DNS.
 *
 * **Renewal is decided from a recorded issue time, not from the certificate.**
 * There is no certificate parser in the standard library, and reaching into the
 * DER through `asn1` to read `notAfter` would be a lot of fragile code to learn
 * something we already know: we issued it, so we wrote down when. `issued` sits
 * beside the pair and holds Unix seconds.
 *
 * Everything that *decides* is pure and tested - which paths, whether it is time
 * to renew, whether a token is safe to write. The ACME conversation itself is one
 * impure function, because it needs a network and a CA.
 * @module certs
 * @example
 * import "./certs.j" as certs;
 * if (certs.dueForRenewal($cfg.tls, certs.issuedAt($cfg.tls, $domain), $now)) {
 *     certs.obtain($cfg.tls, $now);
 * }
 */

use fs;
use strings;
use convert;
use crypto;
import "acme.j" as acme;
import "./config.j" as config;

# How long a Let's Encrypt certificate lives. Used only to decide when to renew;
# nothing here depends on the CA honouring it exactly, because `renewBeforeDays`
# is subtracted from it and the result is compared against our own record.
def const LIFETIME_DAYS as int init 90;
def const SECONDS_PER_DAY as int init 86400;

# How patiently to wait on the CA. A challenge is usually settled in seconds; a
# busy CA can take longer, and giving up early means a failed boot rather than a
# slow one.
def const POLL_INTERVAL_MS as int init 2000;
def const POLL_TRIES as int init 30;

/**
 * A certificate and its key, as PEM.
 * @field cert {string} the PEM chain, leaf first
 * @field key {string} the PEM private key
 * @field issuedAt {int} when it was obtained (Unix seconds), 0 when unknown
 */
export def struct Bundle {
    cert as string,
    key as string,
    issuedAt as int
};

# safeName reduces a domain to something safe to use as a directory name. A
# configured domain is operator input that becomes a filesystem path, so anything
# outside the allowed set is replaced rather than trusted: a domain containing
# `/` or `..` would otherwise write outside the certificate directory.
func safeName(domain as string) {
    def allowed as string init "abcdefghijklmnopqrstuvwxyz0123456789.-";
    def out as string init "";
    for (def ch in strings.chars(strings.lower(strings.trim($domain)))) {
        if (strings.indexOf($allowed, $ch) < 0) {
            $out = $out + "_";
        } else {
            $out = $out + $ch;
        }
    }
    # A dot is legal in a domain, so the character filter alone still admits
    # `..`, and a name of exactly `..` would resolve to the parent directory.
    # Collapse the pair, repeatedly, since replacing "..." once leaves "..".
    while (strings.contains($out, "..")) {
        $out = strings.replace($out, "..", "__");
    }
    # A name that filtered down to nothing, or to dots alone, addresses the
    # directory itself rather than something inside it.
    if (strings.trim($out) == "" or $out == "." ) {
        return "_";
    }
    return $out;
}

/**
 * The directory a domain's certificate lives in.
 * @param tls {config.Tls} the TLS configuration
 * @param domain {string} the certificate's primary domain
 * @return {string} the directory path
 */
export func dirFor(tls as config.Tls, domain as string) {
    return $tls.certDir + "/" + safeName($domain);
}

/**
 * The three files that make up a stored certificate.
 * @param tls {config.Tls} the TLS configuration
 * @param domain {string} the primary domain
 * @return {list of string} the cert, key, and issue-time paths, in that order
 */
export func pathsFor(tls as config.Tls, domain as string) {
    def base as string init dirFor($tls, $domain);
    return [$base + "/cert.pem", $base + "/key.pem", $base + "/issued"];
}

/**
 * The account key's path. One key per deployment, not per domain: an ACME
 * account is the deployment's identity to the CA, and regenerating it on every
 * renewal would register a new account each time.
 * @param tls {config.Tls} the TLS configuration
 * @return {string} the account key path
 */
export func accountKeyPath(tls as config.Tls) {
    return $tls.certDir + "/account.key";
}

# safeToken filters a challenge token for use as a filename, **preserving case**.
# An ACME token is base64url, where case is significant: folding it would let two
# distinct tokens collide on one file, and the second challenge would be answered
# with the first one's response.
func safeToken(token as string) {
    def allowed as string init
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    def out as string init "";
    for (def ch in strings.chars(strings.trim($token))) {
        if (strings.indexOf($allowed, $ch) < 0) {
            $out = $out + "_";
        } else {
            $out = $out + $ch;
        }
    }
    if (strings.trim($out) == "") {
        return "_";
    }
    return $out;
}

/**
 * Where an HTTP-01 challenge response for a token is written.
 *
 * The token comes from the CA and lands in a filesystem path, so it is filtered
 * the same way a domain is. A CA would not send a hostile token, but "the remote
 * party would not do that" is not a property worth depending on when the cost of
 * checking is one function.
 * @param tls {config.Tls} the TLS configuration
 * @param token {string} the challenge token
 * @return {string} the file to write the key authorization into
 */
export func challengePath(tls as config.Tls, token as string) {
    return $tls.challengeDir + "/" + safeToken($token);
}

/**
 * When a stored certificate was issued, or 0 when there is none.
 * @param tls {config.Tls} the TLS configuration
 * @param domain {string} the primary domain
 * @return {int} Unix seconds, or 0
 */
export func issuedAt(tls as config.Tls, domain as string) {
    def paths as list of string init pathsFor($tls, $domain);
    if (not fs.exists($paths[2])) {
        return 0;
    }
    try {
        return convert.toInt(strings.trim(fs.readString($paths[2])));
    } catch (err) {
        return 0;
    }
}

/**
 * Is it time to obtain or renew?
 *
 * Pure, so the arithmetic has tests rather than a comment. An `issued` of 0 means
 * there is nothing stored, which is always due. A certificate from the future -
 * a clock that moved backwards, a restored backup - is treated as due too, since
 * the alternative is trusting a timestamp we can prove wrong.
 * @param tls {config.Tls} the TLS configuration
 * @param issued {int} when the stored certificate was obtained (0 for none)
 * @param now {int} the current time (Unix seconds)
 * @return {bool} true when a certificate should be obtained
 */
export func dueForRenewal(tls as config.Tls, issued as int, now as int) {
    if ($issued <= 0) {
        return true;
    }
    if ($issued > $now) {
        return true;
    }
    def renewAfter as int init (LIFETIME_DAYS - $tls.renewBeforeDays) * SECONDS_PER_DAY;
    if ($renewAfter < SECONDS_PER_DAY) {
        # A renewBeforeDays at or past the lifetime would renew on every boot,
        # which is the fastest way to meet a rate limit. Keep a day of slack.
        $renewAfter = SECONDS_PER_DAY;
    }
    return ($now - $issued) >= $renewAfter;
}

/**
 * Read a stored certificate. Check `hasBundle` first; a missing one throws.
 * @param tls {config.Tls} the TLS configuration
 * @param domain {string} the primary domain
 * @return {Bundle} the stored certificate and key
 * @throws {Error} when the files are not there
 */
export func load(tls as config.Tls, domain as string) {
    def paths as list of string init pathsFor($tls, $domain);
    return Bundle{
        cert: fs.readString($paths[0]),
        key: fs.readString($paths[1]),
        issuedAt: issuedAt($tls, $domain)
    };
}

/**
 * Is a usable certificate stored for this domain?
 * @param tls {config.Tls} the TLS configuration
 * @param domain {string} the primary domain
 * @return {bool} true when both the certificate and the key are present
 */
export func hasBundle(tls as config.Tls, domain as string) {
    def paths as list of string init pathsFor($tls, $domain);
    return fs.exists($paths[0]) and fs.exists($paths[1]);
}

/**
 * Write a certificate, its key, and the issue time.
 *
 * The key is written `0600`. It is the one file here that is a secret, and the
 * data directory is bind-mounted in the container, so it would otherwise inherit
 * whatever the process umask happens to be.
 * @param tls {config.Tls} the TLS configuration
 * @param domain {string} the primary domain
 * @param cert {string} the PEM chain
 * @param key {string} the PEM private key
 * @param now {int} the issue time (Unix seconds)
 */
export func save(tls as config.Tls, domain as string, cert as string, key as string,
        now as int) {
    def paths as list of string init pathsFor($tls, $domain);
    fs.mkdirAll(dirFor($tls, $domain));
    fs.writeString($paths[0], $cert);
    fs.writeString($paths[1], $key);
    fs.chmod($paths[1], 0o600);
    fs.writeString($paths[2], convert.toString($now));
    return null;
}

# accountKey loads the deployment's ACME account key, generating and storing one
# on first use. Kept out of `obtain` so that first run and every later run take
# the same path through the code.
func accountKey(tls as config.Tls) {
    def path as string init accountKeyPath($tls);
    if (fs.exists($path)) {
        return convert.bytesFromString(fs.readString($path), "utf-8");
    }
    fs.mkdirAll($tls.certDir);
    def key as bytes init crypto.ecGenerateKey("p256");
    fs.writeString($path, convert.stringFromBytes($key, "utf-8"));
    fs.chmod($path, 0o600);
    return $key;
}

# settle proves control of one domain over HTTP-01: write the key authorization
# where `bin/serve` will serve it, tell the CA to look, and wait for the verdict.
func settle(client as acme.Client, tls as config.Tls, authzUrl as string) {
    def authz as acme.Authorization init acme.authorization($client, $authzUrl);
    if ($authz.status == "valid") {
        # Already proven, and authorizations are reusable for a while. Skipping
        # saves a round trip and, more usefully, avoids re-writing a challenge
        # file for a domain the CA has stopped asking about.
        return null;
    }
    def ch as acme.Challenge init acme.challenge($authz, "http-01");
    def answer as string init acme.keyAuthorization($client, $ch.token);
    fs.mkdirAll($tls.challengeDir);
    fs.writeString(challengePath($tls, $ch.token), $answer);
    acme.accept($client, $ch.url);
    def settled as acme.Authorization init acme.pollAuthorization($client, $authzUrl,
        POLL_INTERVAL_MS, POLL_TRIES);
    try {
        fs.remove(challengePath($tls, $ch.token));
    } catch (err) { # lint-disable: L103
        # the response has served its purpose; a leftover file is harmless
    }
    if (not ($settled.status == "valid")) {
        throw Error{
            kind: "certs",
            message: "the CA could not verify " + $settled.domain + " (" +
                $settled.status + "); check that port 80 reaches this registry " +
                "and that the domain resolves to it",
            file: "", line: 0, col: 0
        };
    }
    return null;
}

/**
 * Obtain a certificate for the configured domains and store it.
 *
 * The whole ACME conversation: register the account, open an order, prove each
 * domain over HTTP-01, finalize with a CSR, download the chain. The first domain
 * in the list names the stored bundle; the rest ride along on the same
 * certificate as additional names.
 *
 * **This is the only function here that touches the network**, which is why the
 * decisions - paths, renewal timing, token safety - live in the pure functions
 * above and are tested there.
 * @param tls {config.Tls} the TLS configuration
 * @param now {int} the current time (Unix seconds)
 * @return {Bundle} the certificate that was obtained and stored
 * @throws {Error} when the CA refuses, a domain cannot be verified, or a file
 *     cannot be written
 */
export func obtain(tls as config.Tls, now as int) {
    def client as acme.Client init acme.connect($tls.directory, accountKey($tls));
    $client = acme.register($client, $tls.email);
    def order as acme.Order init acme.order($client, $tls.domains);
    for (def authzUrl in $order.authorizations) {
        settle($client, $tls, $authzUrl);
    }
    def certKey as bytes init crypto.ecGenerateKey("p256");
    def csr as bytes init crypto.csr($certKey, $tls.domains);
    def finished as acme.Order init acme.finalize($client, $order, $csr,
        POLL_INTERVAL_MS, POLL_TRIES);
    def chain as string init acme.downloadCertificate($client, $finished);
    def keyPem as string init convert.stringFromBytes($certKey, "utf-8");
    save($tls, $tls.domains[0], $chain, $keyPem, $now);
    return Bundle{ cert: $chain, key: $keyPem, issuedAt: $now };
}

/**
 * Return a usable certificate, obtaining one only if the stored one is missing
 * or due for renewal.
 *
 * A renewal that fails while a **still-valid** certificate is on disk is not
 * fatal: the old one is returned and the failure is the caller's to report. Being
 * unreachable for a renewal is a temporary problem, and refusing to start over it
 * would turn a warning into an outage, at exactly the moment when the CA is
 * having trouble.
 * @param tls {config.Tls} the TLS configuration
 * @param now {int} the current time (Unix seconds)
 * @return {Bundle} the certificate to serve
 * @throws {Error} when there is no usable certificate and one cannot be obtained
 */
export func ensure(tls as config.Tls, now as int) {
    def domain as string init $tls.domains[0];
    def have as bool init hasBundle($tls, $domain);
    if ($have and not dueForRenewal($tls, issuedAt($tls, $domain), $now)) {
        return load($tls, $domain);
    }
    if (not $have) {
        return obtain($tls, $now);
    }
    try {
        return obtain($tls, $now);
    } catch (err) {
        return load($tls, $domain);
    }
}
