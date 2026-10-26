# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The deployment's configuration, from a TOML file and the environment.
 *
 * The environment wins over the file, so one instance can be varied or given a
 * secret without editing a file baked into an image.
 *
 * A field is overridden only when the environment sets it to something: an
 * unset variable and an empty one both mean "not specified", so a stray empty
 * value in a compose file cannot blank a configured setting. Booleans are the
 * exception and parse the value, so an explicit `0` can turn something off.
 *
 * Everything here is pure except `readEnv`: `applyToml` takes the file's text and
 * `applyEnv` takes a map, so the precedence rules are testable. `bin/serve` does
 * the reading.
 * @module config
 * @example
 * import "./config.j" as config;
 * def cfg as config.Config init config.applyEnv(
 *     config.applyToml(config.defaults(), $tomlText), $env);
 */

use toml;
use os;
use fs;
use io;
use strings;
use lists;
use convert;
use maps;

# Where the configuration file is looked for when nothing says otherwise, and the
# variable that moves it.
export def const DEFAULT_PATH as string init "config.toml";
export def const PATH_ENV as string init "REGISTRY_CONFIG";

# The prefix every variable carries, and the legacy one. `JVC_` is the client's
# prefix, so a host running both had one `JVC_DB` naming two databases.
export def const PREFIX as string init "REGISTRY_";
export def const LEGACY_PREFIX as string init "JVC_";

# Let's Encrypt's production and staging directories. Staging issues untrusted
# certificates with far higher rate limits, which suits a first run: production
# limits are per registered domain per week and a misconfigured deployment can
# exhaust them.
export def const LE_PRODUCTION as string init "https://acme-v02.api.letsencrypt.org/directory";
export def const LE_STAGING as string init "https://acme-staging-v02.api.letsencrypt.org/directory";

/**
 * The TLS half of the configuration.
 * @field enabled {bool} whether to serve HTTPS and obtain a certificate
 * @field addr {string} the HTTPS listen address
 * @field domains {list of string} the names the certificate is for
 * @field email {string} the account contact the CA requires
 * @field directory {string} the ACME directory URL
 * @field certDir {string} where the certificate and key are stored
 * @field challengeDir {string} where HTTP-01 challenge responses are written
 * @field renewBeforeDays {int} how early to renew before expiry
 * @field agreeTos {bool} whether the operator accepted the CA's terms
 */
export def struct Tls {
    enabled as bool,
    addr as string,
    domains as list of string,
    email as string,
    directory as string,
    certDir as string,
    challengeDir as string,
    renewBeforeDays as int,
    agreeTos as bool
};

/**
 * Everything a deployment can set.
 * @field canonicalUrl {string} the registry's own public base URL, advertised in
 *     the discovery document ("" when the deployment has not declared one)
 * @field clientIpHeader {string} the header a trusted proxy puts the real client
 *     address in ("" to record the connection's own peer, which cannot be forged)
 * @field addr {string} the plain HTTP listen address
 * @field dbPath {string} the flatdb document
 * @field logFile {string} the operational log ("" for console only)
 * @field logLevel {string} debug / info / warn / error
 * @field logFormat {string} the file format: text / logfmt / json
 * @field logRequests {bool} record one line per request
 * @field identity {string} the identity module
 * @field identityBaseUrl {string} the provider's base URL, self-hosted
 * @field identityClientId {string} the OAuth application id
 * @field identitySecret {string} the client secret, where one is needed
 * @field identityScopes {string} override the requested scopes
 * @field tokenKey {string} the HMAC key the registry signs its own tokens with
 * @field policy {string} the claim policy: operator / derived / firstcome
 * @field forge {string} the forge module
 * @field forgeBaseUrl {string} the forge API root, self-hosted
 * @field forgeToken {string} a service token, where the forge needs one
 * @field forgeHost {string} the hostname whose URLs this forge claims
 * @field maxInFlight {int} how many requests are worked on at once; reads share
 *     one parsed copy, but each large page is built per request, so this bounds memory
 * @field orgMaxAgeHours {int} how old a login's organisation memberships may be
 *     before a refresh is refused (8.7); 0 turns the check off
 * @field authRateLimit {int} requests per minute one client address may make to
 *     the `/auth` routes together; 0 turns the limit off
 * @field writeRateLimit {int} writes per minute per authenticated subject (per
 *     client address for trusted publishing); 0 turns the limit off
 * @field readRateLimit {int} `/resolve-graph` and full `/search` listings per
 *     minute per client address; 0 turns the limit off
 * @field respondTimeoutSeconds {int} how long a request may take before the
 *     engine answers `503` itself; above the slowest publish (forge calls)
 * @field sourceAuthority {string} how a publish proves push access to its
 *     repository (7.1 route A): `login`, `service`, or "" to choose by whether
 *     identity and forge are the same service (see `sourceAuthorityOf`)
 * @field trustpubAudience {string} the `aud` a CI token must carry (8.9)
 * @field trustpubProvider {string} which CI issuer is accepted
 * @field trustpubIssuer {string} the OIDC issuer, for anything self-hosted
 * @field tls {Tls} the TLS and ACME settings
 */
export def struct Config {
    canonicalUrl as string,
    clientIpHeader as string,
    addr as string,
    dbPath as string,
    logFile as string,
    logLevel as string,
    logFormat as string,
    logRequests as bool,
    identity as string,
    identityBaseUrl as string,
    identityClientId as string,
    identitySecret as string,
    identityScopes as string,
    tokenKey as string,
    policy as string,
    forge as string,
    forgeBaseUrl as string,
    forgeToken as string,
    forgeHost as string,
    sourceAuthority as string,
    maxInFlight as int,
    respondTimeoutSeconds as int,
    orgMaxAgeHours as int,
    authRateLimit as int,
    writeRateLimit as int,
    readRateLimit as int,
    trustpubAudience as string,
    trustpubProvider as string,
    trustpubIssuer as string,
    tls as Tls
};

/**
 * The unconfigured registry: read-only, plain HTTP, console logging. Every
 * default is the narrow choice (no TLS, no logins, no trusted publishing).
 * @return {Config} the defaults
 */
export func defaults() {
    def noDomains as list of string init [];
    return Config{
        canonicalUrl: "",
        clientIpHeader: "",
        addr: ":8080",
        dbPath: "data/decks.json",
        logFile: "",
        logLevel: "info",
        logFormat: "logfmt",
        logRequests: false,
        identity: "github",
        identityBaseUrl: "",
        identityClientId: "",
        identitySecret: "",
        identityScopes: "",
        tokenKey: "",
        policy: "derived",
        forge: "github",
        forgeBaseUrl: "",
        forgeToken: "",
        forgeHost: "",
        sourceAuthority: "",
        maxInFlight: 32,
        respondTimeoutSeconds: 120,
        orgMaxAgeHours: 168,
        authRateLimit: 30,
        writeRateLimit: 60,
        readRateLimit: 120,
        trustpubAudience: "",
        trustpubProvider: "github-actions",
        trustpubIssuer: "",
        tls: Tls{
            enabled: false,
            addr: ":8443",
            domains: $noDomains,
            email: "",
            directory: LE_PRODUCTION,
            certDir: "data/tls",
            challengeDir: "data/acme-challenge",
            renewBeforeDays: 30,
            agreeTos: false
        }
    };
}

# trimSlash drops trailing slashes. A client records this URL as a deck's origin,
# so two spellings of one registry would read as two registries.
func trimSlash(url as string) {
    def out as string init strings.trim($url);
    while (strings.endsWith($out, "/")) {
        $out = strings.substring($out, 0, len($out) - 1);
    }
    return $out;
}

# str reads a TOML string, returning the fallback when the key is absent or blank.
func str(doc as toml.Value, pointer as string, fallback as string) {
    if (not toml.has($doc, $pointer)) {
        return $fallback;
    }
    def value as string init strings.trim(toml.asString($doc, $pointer));
    if ($value == "") {
        return $fallback;
    }
    return $value;
}

# flag reads a TOML boolean, returning the fallback when the key is absent.
func flag(doc as toml.Value, pointer as string, fallback as bool) {
    if (not toml.has($doc, $pointer)) {
        return $fallback;
    }
    return toml.asBool($doc, $pointer);
}

# count reads a TOML integer, returning the fallback when the key is absent.
func count(doc as toml.Value, pointer as string, fallback as int) {
    if (not toml.has($doc, $pointer)) {
        return $fallback;
    }
    return toml.asInt($doc, $pointer);
}

# names reads a TOML array of strings.
func names(doc as toml.Value, pointer as string, fallback as list of string) {
    if (not toml.has($doc, $pointer)) {
        return $fallback;
    }
    def out as list of string init [];
    def n as int init toml.length($doc, $pointer);
    def i as int init 0;
    while ($i < $n) {
        def one as string init strings.trim(toml.asString(
            $doc,
            $pointer + "/" +
                convert.toString($i)));
        if (not ($one == "")) {
            $out[] = $one;
        }
        $i = $i + 1;
    }
    return $out;
}

/**
 * Overlay a TOML document onto a configuration. An unparseable file throws, so a
 * deployment refuses to start instead of serving with the wrong settings.
 * @param base {Config} what to overlay onto, usually `defaults()`
 * @param text {string} the file's contents ("" leaves the base untouched)
 * @return {Config} the merged configuration
 * @throws {Error} when the text is not valid TOML
 */
export func applyToml(base as Config, text as string) {
    if (strings.trim($text) == "") {
        return $base;
    }
    def doc as toml.Value init toml.decode($text);
    def out as Config init $base;
    $out.canonicalUrl = trimSlash(str($doc, "/url", $out.canonicalUrl));
    $out.clientIpHeader = str($doc, "/clientIpHeader", $out.clientIpHeader);
    $out.addr = str($doc, "/addr", $out.addr);
    $out.maxInFlight = count($doc, "/maxInFlight", $out.maxInFlight);
    $out.writeRateLimit = count($doc, "/writeRateLimit", $out.writeRateLimit);
    $out.readRateLimit = count($doc, "/readRateLimit", $out.readRateLimit);
    $out.respondTimeoutSeconds = count($doc, "/respondTimeout", $out.respondTimeoutSeconds);
    $out.dbPath = str($doc, "/db", $out.dbPath);
    $out.logFile = str($doc, "/log/file", $out.logFile);
    $out.logLevel = str($doc, "/log/level", $out.logLevel);
    $out.logFormat = str($doc, "/log/format", $out.logFormat);
    $out.logRequests = flag($doc, "/log/requests", $out.logRequests);
    $out.identity = str($doc, "/identity/provider", $out.identity);
    $out.identityBaseUrl = str($doc, "/identity/baseUrl", $out.identityBaseUrl);
    $out.identityClientId = str($doc, "/identity/clientId", $out.identityClientId);
    $out.identitySecret = str($doc, "/identity/secret", $out.identitySecret);
    $out.identityScopes = str($doc, "/identity/scopes", $out.identityScopes);
    $out.orgMaxAgeHours = count($doc, "/identity/orgMaxAge", $out.orgMaxAgeHours);
    $out.authRateLimit = count($doc, "/identity/rateLimit", $out.authRateLimit);
    $out.tokenKey = str($doc, "/tokenKey", $out.tokenKey);
    $out.policy = str($doc, "/policy", $out.policy);
    $out.forge = str($doc, "/forge/provider", $out.forge);
    $out.forgeBaseUrl = str($doc, "/forge/baseUrl", $out.forgeBaseUrl);
    $out.forgeToken = str($doc, "/forge/token", $out.forgeToken);
    $out.forgeHost = str($doc, "/forge/host", $out.forgeHost);
    $out.sourceAuthority = str($doc, "/forge/sourceAuthority", $out.sourceAuthority);
    $out.trustpubAudience = str($doc, "/trustedPublishing/audience", $out.trustpubAudience);
    $out.trustpubProvider = str($doc, "/trustedPublishing/provider", $out.trustpubProvider);
    $out.trustpubIssuer = str($doc, "/trustedPublishing/issuer", $out.trustpubIssuer);
    $out.tls = Tls{
        enabled: flag($doc, "/tls/enabled", $out.tls.enabled),
        addr: str($doc, "/tls/addr", $out.tls.addr),
        domains: names($doc, "/tls/domains", $out.tls.domains),
        email: str($doc, "/tls/email", $out.tls.email),
        directory: str($doc, "/tls/directory", $out.tls.directory),
        certDir: str($doc, "/tls/certDir", $out.tls.certDir),
        challengeDir: str($doc, "/tls/challengeDir", $out.tls.challengeDir),
        renewBeforeDays: count($doc, "/tls/renewBeforeDays", $out.tls.renewBeforeDays),
        agreeTos: flag($doc, "/tls/agreeTos", $out.tls.agreeTos)
    };
    return $out;
}

# envStr overrides only when the variable is set to something non-empty.
func envStr(env as map of string to string, key as string, fallback as string) {
    if (not maps.has($env, $key)) {
        return $fallback;
    }
    def value as string init strings.trim($env[$key]);
    if ($value == "") {
        return $fallback;
    }
    return $value;
}

/**
 * Read a boolean from an environment value. Anything in `1 true yes on` is true,
 * anything in `0 false no off` is false, and anything else leaves the fallback,
 * since reading "maybe" as "no" would disable TLS.
 * @param env {map of string to string} the environment
 * @param key {string} the variable
 * @param fallback {bool} what to keep when it is unset or unrecognised
 * @return {bool} the resolved value
 */
export func envFlag(env as map of string to string, key as string, fallback as bool) {
    if (not maps.has($env, $key)) {
        return $fallback;
    }
    def value as string init strings.lower(strings.trim($env[$key]));
    if ($value == "1" or $value == "true" or $value == "yes" or $value == "on") {
        return true;
    }
    if ($value == "0" or $value == "false" or $value == "no" or $value == "off") {
        return false;
    }
    return $fallback;
}

# envList reads a comma-separated or space-separated list.
func envList(env as map of string to string, key as string, fallback as list of string) {
    if (not maps.has($env, $key)) {
        return $fallback;
    }
    def raw as string init strings.trim($env[$key]);
    if ($raw == "") {
        return $fallback;
    }
    def out as list of string init [];
    for (def part in strings.split(strings.replace($raw, " ", ","), ",")) {
        def one as string init strings.trim($part);
        if (not ($one == "")) {
            $out[] = $one;
        }
    }
    return $out;
}

/**
 * Overlay the environment onto a configuration. This runs last, so it wins.
 * @param base {Config} the configuration so far
 * @param env {map of string to string} the environment
 * @return {Config} the merged configuration
 */
export func applyEnv(base as Config, env as map of string to string) {
    def out as Config init $base;
    $out.canonicalUrl = trimSlash(envStr($env, "REGISTRY_URL", $out.canonicalUrl));
    $out.clientIpHeader = envStr($env, "REGISTRY_CLIENT_IP_HEADER", $out.clientIpHeader);
    $out.addr = envStr($env, "REGISTRY_ADDR", $out.addr);
    $out.dbPath = envStr($env, "REGISTRY_DB", $out.dbPath);
    $out.logFile = envStr($env, "REGISTRY_LOG", $out.logFile);
    $out.logLevel = envStr($env, "REGISTRY_LOG_LEVEL", $out.logLevel);
    $out.logFormat = envStr($env, "REGISTRY_LOG_FORMAT", $out.logFormat);
    $out.logRequests = envFlag($env, "REGISTRY_LOG_REQUESTS", $out.logRequests);
    $out.identity = envStr($env, "REGISTRY_IDENTITY", $out.identity);
    $out.identityBaseUrl = envStr($env, "REGISTRY_IDENTITY_BASEURL", $out.identityBaseUrl);
    $out.identityClientId = envStr($env, "REGISTRY_IDENTITY_CLIENTID", $out.identityClientId);
    $out.identitySecret = envStr($env, "REGISTRY_IDENTITY_SECRET", $out.identitySecret);
    $out.identityScopes = envStr($env, "REGISTRY_IDENTITY_SCOPES", $out.identityScopes);
    $out.tokenKey = envStr($env, "REGISTRY_TOKEN_KEY", $out.tokenKey);
    $out.policy = envStr($env, "REGISTRY_POLICY", $out.policy);
    $out.forge = envStr($env, "REGISTRY_FORGE", $out.forge);
    $out.forgeBaseUrl = envStr($env, "REGISTRY_FORGE_BASEURL", $out.forgeBaseUrl);
    $out.forgeToken = envStr($env, "REGISTRY_FORGE_TOKEN", $out.forgeToken);
    $out.forgeHost = envStr($env, "REGISTRY_FORGE_HOST", $out.forgeHost);
    $out.sourceAuthority = envStr($env, "REGISTRY_SOURCE_AUTHORITY", $out.sourceAuthority);
    $out.trustpubAudience = envStr($env, "REGISTRY_TRUSTPUB_AUDIENCE", $out.trustpubAudience);
    $out.trustpubProvider = envStr($env, "REGISTRY_TRUSTPUB_PROVIDER", $out.trustpubProvider);
    $out.trustpubIssuer = envStr($env, "REGISTRY_TRUSTPUB_ISSUER", $out.trustpubIssuer);
    $out.tls = Tls{
        enabled: envFlag($env, "REGISTRY_TLS", $out.tls.enabled),
        addr: envStr($env, "REGISTRY_TLS_ADDR", $out.tls.addr),
        domains: envList($env, "REGISTRY_TLS_DOMAINS", $out.tls.domains),
        email: envStr($env, "REGISTRY_TLS_EMAIL", $out.tls.email),
        directory: envStr($env, "REGISTRY_ACME_DIRECTORY", $out.tls.directory),
        certDir: envStr($env, "REGISTRY_TLS_CERTDIR", $out.tls.certDir),
        challengeDir: envStr($env, "REGISTRY_ACME_CHALLENGEDIR", $out.tls.challengeDir),
        renewBeforeDays: $out.tls.renewBeforeDays,
        agreeTos: envFlag($env, "REGISTRY_ACME_AGREE_TOS", $out.tls.agreeTos)
    };
    $out.tls.renewBeforeDays = envInt(
        $env,
        "REGISTRY_TLS_RENEW_BEFORE_DAYS",
        $out.tls.renewBeforeDays);
    $out.maxInFlight = envInt($env, "REGISTRY_MAX_IN_FLIGHT", $out.maxInFlight);
    $out.writeRateLimit = envInt($env, "REGISTRY_WRITE_RATE_LIMIT", $out.writeRateLimit);
    $out.readRateLimit = envInt($env, "REGISTRY_READ_RATE_LIMIT", $out.readRateLimit);
    $out.orgMaxAgeHours = envInt($env, "REGISTRY_ORG_MAX_AGE", $out.orgMaxAgeHours);
    $out.authRateLimit = envInt($env, "REGISTRY_AUTH_RATE_LIMIT", $out.authRateLimit);
    $out.respondTimeoutSeconds = envInt(
        $env,
        "REGISTRY_RESPOND_TIMEOUT",
        $out.respondTimeoutSeconds);
    return $out;
}

# envInt reads a whole number from the environment. Unset, empty, or not a number
# leaves the configured value in place.
func envInt(env as map of string to string, name as string, fallback as int) {
    if (not maps.has($env, $name)) {
        return $fallback;
    }
    def raw as string init strings.trim($env[$name]);
    if ($raw == "") {
        return $fallback;
    }
    try {
        return convert.toInt($raw);
    } catch (err) {
        return $fallback;
    }
}

/**
 * The pre-rename name of a variable, or "" when there is none. The old names
 * are still read, with a warning, because an unset variable falls back to a
 * default and a configured deployment would start serving a different database.
 * @param name {string} the current variable name
 * @return {string} the deprecated equivalent, or "" if the name is not ours
 */
export func legacyNameOf(name as string) {
    if (not strings.startsWith($name, PREFIX)) {
        return "";
    }
    return LEGACY_PREFIX + strings.substring($name, len(PREFIX), len($name));
}

# The provider, forge and policy names `bin/serve` can wire. An unknown name is
# refused at boot rather than served as the default.
def const IDENTITIES as list of string init ["github", "gitlab", "gitea", "forgejo", "oidc"];
def const FORGES as list of string init ["github", "gitlab", "gitea", "forgejo"];
def const POLICIES as list of string init ["derived", "operator", "firstcome"];

/**
 * The shortest `tokenKey` accepted, in characters.
 */
export def const MIN_TOKEN_KEY as int init 32;

/**
 * Why this configuration cannot be served, or "" when it can. Checked once at
 * boot, so a missing setting stops the server instead of failing requests.
 * @param cfg {Config} the resolved configuration
 * @return {string} the complaint, or "" when the configuration is usable
 */
export func problem(cfg as Config) {
    if (not lists.contains(IDENTITIES, $cfg.identity)) {
        return "unknown identity provider \"" + $cfg.identity + "\"; expected one of " +
            strings.join(IDENTITIES, ", ");
    }
    if (not lists.contains(FORGES, $cfg.forge)) {
        return "unknown forge \"" + $cfg.forge + "\"; expected one of " +
            strings.join(FORGES, ", ");
    }
    if (not lists.contains(POLICIES, $cfg.policy)) {
        return "unknown policy \"" + $cfg.policy + "\"; expected one of " +
            strings.join(POLICIES, ", ");
    }
    if ($cfg.maxInFlight < 1) {
        return "maxInFlight must be at least 1";
    }
    if ($cfg.orgMaxAgeHours < 0) {
        return "identity.orgMaxAge must be 0 (off) or a number of hours";
    }
    if ($cfg.authRateLimit < 0) {
        return "identity.rateLimit must be 0 (off) or requests per minute";
    }
    if ($cfg.writeRateLimit < 0) {
        return "writeRateLimit must be 0 (off) or requests per minute";
    }
    if ($cfg.readRateLimit < 0) {
        return "readRateLimit must be 0 (off) or requests per minute";
    }
    if ($cfg.respondTimeoutSeconds < 1) {
        return "respondTimeout must be at least 1 second";
    }
    # The key signs every bearer token and seals every stored forge credential,
    # so a short one is guessable. The documented `openssl rand -hex 32` gives 64.
    if (not ($cfg.tokenKey == "") and len($cfg.tokenKey) < MIN_TOKEN_KEY) {
        return "tokenKey must be at least " + convert.toString(MIN_TOKEN_KEY) +
            " characters; generate one with: openssl rand -hex 32";
    }
    def authority as string init authorityProblem($cfg);
    if (not ($authority == "")) {
        return $authority;
    }
    def base as string init baseUrlProblem($cfg);
    if (not ($base == "")) {
        return $base;
    }
    if (not $cfg.tls.enabled) {
        return "";
    }
    if (len($cfg.tls.domains) == 0) {
        return "tls.enabled is set but no tls.domains are configured";
    }
    # Below 1 the renewal would follow the expiry; from 89 up every boot after
    # the first day re-issues, into the CA's duplicate-certificate limit.
    if ($cfg.tls.renewBeforeDays < MIN_RENEW_DAYS or $cfg.tls.renewBeforeDays > MAX_RENEW_DAYS) {
        return "tls.renewBeforeDays must be between " + convert.toString(MIN_RENEW_DAYS) +
            " and " + convert.toString(MAX_RENEW_DAYS);
    }
    if (strings.trim($cfg.tls.email) == "") {
        return "tls.enabled is set but tls.email is empty; a CA requires a contact";
    }
    if (not $cfg.tls.agreeTos) {
        return "tls.enabled is set but tls.agreeTos is false; the CA's terms " +
            "must be accepted deliberately, not by default";
    }
    return "";
}

/**
 * How a publish proves the caller may push to the repository it names
 * (specification 7.1, route A), resolved from the configuration.
 *
 * - `login`: the identity provider's token, kept from the caller's own login,
 *   asks the forge. Only possible when identity and forge are one service,
 *   since otherwise the forge would not accept that token (12.5).
 * - `service`: the registry's own forge token asks the forge about the caller,
 *   by username. For identity and forge as different services sharing one user
 *   directory; that a username is the same account on both is the operator's
 *   assertion and is not checked.
 *
 * Unset, it is `login` when identity and forge are the same service and
 * `service` otherwise.
 * @param cfg {Config} the merged configuration
 * @return {string} `login` or `service`, or the unrecognised value as given
 */
export func sourceAuthorityOf(cfg as Config) {
    def explicit as string init strings.lower(strings.trim($cfg.sourceAuthority));
    if (not ($explicit == "")) {
        return $explicit;
    }
    if (sameService($cfg)) {
        return "login";
    }
    return "service";
}

# The bounds on `tls.renewBeforeDays`, against a 90-day certificate lifetime.
def const MIN_RENEW_DAYS as int init 1;
def const MAX_RENEW_DAYS as int init 88;

# baseUrlProblem refuses a provider or forge base URL that would carry tokens
# in clear: anything but `https`, unless the host is the machine itself.
func baseUrlProblem(cfg as Config) {
    if (not secureBase($cfg.identityBaseUrl)) {
        return "identity.baseUrl must be an https URL (http is allowed for a loopback host only)";
    }
    if (not secureBase($cfg.forgeBaseUrl)) {
        return "forge.baseUrl must be an https URL (http is allowed for a loopback host only)";
    }
    return "";
}

# secureBase accepts "" (the module default), any `https://` URL, and an
# `http://` URL whose host is loopback (a provider on the same machine, tests).
func secureBase(url as string) {
    def u as string init strings.lower(strings.trim($url));
    if ($u == "" or strings.startsWith($u, "https://")) {
        return true;
    }
    if (not strings.startsWith($u, "http://")) {
        return false;
    }
    return lists.contains(["localhost", "127.0.0.1", "[::1]"], hostOf($u));
}

# hostOf is the host of a lowercased URL: between `//` and the first `/`, with
# a port removed (a bracketed IPv6 host keeps its brackets).
func hostOf(url as string) {
    def rest as string init strings.substring($url, strings.indexOf($url, "//") + 2, len($url));
    def slash as int init strings.indexOf($rest, "/");
    if ($slash >= 0) {
        $rest = strings.substring($rest, 0, $slash);
    }
    if (strings.startsWith($rest, "[")) {
        def close as int init strings.indexOf($rest, "]");
        if ($close >= 0) {
            return strings.substring($rest, 0, $close + 1);
        }
        return $rest;
    }
    def colon as int init strings.indexOf($rest, ":");
    if ($colon >= 0) {
        return strings.substring($rest, 0, $colon);
    }
    return $rest;
}

# sameService reports whether the identity provider and the forge are one
# service, so the forge accepts a login token. Forgejo logs in through the gitea
# identity module, so the two names are one family; self-hosted instances must
# also share a base URL.
func sameService(cfg as Config) {
    def forgeFamily as string init strings.lower($cfg.forge);
    if ($forgeFamily == "forgejo") {
        $forgeFamily = "gitea";
    }
    if (not (strings.lower($cfg.identity) == $forgeFamily)) {
        return false;
    }
    return rootOf($cfg.identityBaseUrl) == rootOf($cfg.forgeBaseUrl);
}

# rootOf is a base URL compared loosely: case and trailing slashes aside.
func rootOf(url as string) {
    def out as string init strings.lower(strings.trim($url));
    while (strings.endsWith($out, "/")) {
        $out = strings.substring($out, 0, len($out) - 1);
    }
    return $out;
}

# authorityProblem refuses a source-authority setting that cannot work, once
# logins are on.
func authorityProblem(cfg as Config) {
    def mode as string init sourceAuthorityOf($cfg);
    if (not ($mode == "login" or $mode == "service")) {
        return "forge.sourceAuthority must be `login` or `service`, not `" + $mode + "`";
    }
    if (strings.trim($cfg.identityClientId) == "" or strings.trim($cfg.tokenKey) == "") {
        return "";
    }
    if ($mode == "login" and not sameService($cfg)) {
        return "forge.sourceAuthority is `login`, but the identity provider and the " +
            "forge are different services, so the forge would not accept a login " +
            "token; use `service` with a forge token";
    }
    if ($mode == "service" and strings.trim($cfg.forgeToken) == "") {
        return "forge.sourceAuthority is `service`, which needs forge.token " +
            "(REGISTRY_FORGE_TOKEN) to ask the forge who may push";
    }
    return "";
}

/**
 * Whether this directory URL is the CA's staging endpoint, so boot can warn that
 * its certificates are untrusted.
 * @param directory {string} the configured directory URL
 * @return {bool} true when it looks like a staging endpoint
 */
export func isStaging(directory as string) {
    return strings.contains(strings.lower($directory), "staging");
}

/**
 * The address rendered as a URL for the boot banner. An address with no host
 * (`:8080`, every interface) is shown as `localhost`; one with a host is shown
 * as is.
 * @param scheme {string} "http" or "https"
 * @param addr {string} the listen address
 * @return {string} a URL to print
 */
export func displayUrl(scheme as string, addr as string) {
    if (strings.startsWith($addr, ":")) {
        return $scheme + "://localhost" + $addr;
    }
    return $scheme + "://" + $addr;
}

# secretFile reads the file a `*_FILE` variable points at, trimmed of the
# trailing newline an editor or `docker secret create` leaves behind. An unset
# variable or an unreadable file yields "", meaning "not configured", since an
# empty signing key would accept forged tokens.
func secretFile(name as string) {
    def path as string init strings.trim(os.getEnv($name));
    if ($path == "") {
        return "";
    }
    try {
        return strings.trim(fs.readString($path));
    } catch (err) {
        io.eprintf("warning: cannot read %s from %s\n", $name, $path);
        return "";
    }
}

/**
 * What reading the environment produced.
 * @field values {map of string to string} the variables that were set
 * @field deprecated {list of string} one `OLD (use NEW)` entry per variable found
 *     only under its old name, for the caller to warn about
 */
export def struct EnvRead {
    values as map of string to string,
    deprecated as list of string
};

/**
 * Read the named variables, falling back to their pre-rename names. Impure. It
 * lives here so every entry point applies the same fallback.
 * @param names {list of string} the current variable names to read
 * @return {EnvRead} the values, and which of them came from a deprecated name
 */
export func readEnv(names as list of string) {
    def values as map of string to string init {};
    def deprecated as list of string init [];
    for (def name in $names) {
        def value as string init os.getEnv($name);
        if (not ($value == "")) {
            $values[$name] = $value;
            continue;
        }
        # `NAME_FILE` names a file holding the value. Docker Swarm and Kubernetes
        # mount secrets as files; in the environment a secret would also appear
        # in `docker inspect` and every child process.
        def fromFile as string init secretFile($name + "_FILE");
        if (not ($fromFile == "")) {
            $values[$name] = $fromFile;
            continue;
        }
        def old as string init legacyNameOf($name);
        if ($old == "") {
            continue;
        }
        def legacy as string init os.getEnv($old);
        if (not ($legacy == "")) {
            $values[$name] = $legacy;
            $deprecated[] = $old + " (use " + $name + ")";
        }
    }
    return EnvRead{values: $values, deprecated: $deprecated};
}
