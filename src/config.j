# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The deployment's configuration, from a TOML file and the environment.
 *
 * **The environment wins.** A file is the readable, reviewable, version-
 * controllable statement of how a deployment is meant to run; the environment is
 * how one instance is varied or a secret is injected without editing a file into
 * an image. That ordering is the only one that lets both be true at once, and it
 * is what every container runtime assumes.
 *
 * A field is overridden only when the environment **sets it to something**. An
 * unset variable and an empty one both mean "not specified", so a stray empty
 * value in a compose file cannot silently blank a configured setting. The one
 * exception is a boolean, where an explicit `0` has to be able to turn something
 * off; those parse the value rather than testing for emptiness.
 *
 * Everything here is pure: `applyToml` takes the file's text and `applyEnv` takes
 * a map, so the precedence rules have tests rather than requiring a process with
 * a particular environment. `bin/serve` does the reading.
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
use convert;
use maps;

# Where the configuration file is looked for when nothing says otherwise, and the
# variable that moves it.
export def const DEFAULT_PATH as string init "config.toml";
export def const PATH_ENV as string init "REGISTRY_CONFIG";

# The prefix every variable carries, and the one this project used before the
# registry was split out of the jvc repository. `jvc` is the *client*; naming the
# server's variables after it meant a host running both had one `JVC_DB` meaning
# two different databases.
export def const PREFIX as string init "REGISTRY_";
export def const LEGACY_PREFIX as string init "JVC_";

# Let's Encrypt's production and staging directories. Staging issues untrusted
# certificates with far higher rate limits, which is what a first run should use:
# the production limits are per registered domain per week, and a misconfigured
# deployment can exhaust them long before anybody notices.
export def const LE_PRODUCTION as string init
    "https://acme-v02.api.letsencrypt.org/directory";
export def const LE_STAGING as string init
    "https://acme-staging-v02.api.letsencrypt.org/directory";

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
    trustpubAudience as string,
    trustpubProvider as string,
    trustpubIssuer as string,
    tls as Tls
};

/**
 * The configuration of a registry nobody has configured: a read-only,
 * plain-HTTP, console-logging instance. Every default is the *narrow* choice -
 * no TLS, no logins, no trusted publishing - so an unconfigured deployment
 * cannot accidentally serve more than its operator asked for.
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

# trimSlash drops a trailing slash, so a URL configured either way advertises one
# form. A client records this string to identify where a deck came from, and two
# spellings of one registry would read as two registries.
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
        def one as string init strings.trim(toml.asString($doc, $pointer + "/" +
            convert.toString($i)));
        if (not ($one == "")) {
            $out[] = $one;
        }
        $i = $i + 1;
    }
    return $out;
}

/**
 * Overlay a TOML document onto a configuration.
 *
 * An unparseable file throws rather than being ignored. A deployment whose
 * configuration silently failed to load is worse than one that refuses to start:
 * the first serves the wrong thing, the second tells somebody.
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
    $out.tokenKey = str($doc, "/tokenKey", $out.tokenKey);
    $out.policy = str($doc, "/policy", $out.policy);
    $out.forge = str($doc, "/forge/provider", $out.forge);
    $out.forgeBaseUrl = str($doc, "/forge/baseUrl", $out.forgeBaseUrl);
    $out.forgeToken = str($doc, "/forge/token", $out.forgeToken);
    $out.forgeHost = str($doc, "/forge/host", $out.forgeHost);
    $out.trustpubAudience = str($doc, "/trustedPublishing/audience",
        $out.trustpubAudience);
    $out.trustpubProvider = str($doc, "/trustedPublishing/provider",
        $out.trustpubProvider);
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

# envStr overrides only when the variable is set to something. An unset variable
# and an empty one both mean "not specified", so an empty value left in a compose
# file cannot blank a setting the file configured.
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
 * anything in `0 false no off` is false, and anything else leaves the fallback.
 *
 * A boolean cannot use the empty-means-unset rule, because `0` has to be able to
 * turn something off that the file turned on. So it parses, and an unrecognised
 * value is treated as not specified rather than as false - misreading "maybe" as
 * "no" would quietly disable TLS.
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
    $out.clientIpHeader = envStr($env, "REGISTRY_CLIENT_IP_HEADER",
        $out.clientIpHeader);
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
    if (maps.has($env, "REGISTRY_TLS_RENEW_BEFORE_DAYS")) {
        def raw as string init strings.trim($env["REGISTRY_TLS_RENEW_BEFORE_DAYS"]);
        if (not ($raw == "")) {
            try {
                $out.tls.renewBeforeDays = convert.toInt($raw);
            } catch (err) { # lint-disable: L103
                # a non-numeric value leaves the configured one in place
            }
        }
    }
    return $out;
}

/**
 * The pre-rename name of a variable, or "" when there is none.
 *
 * Kept because a rename that merely stops reading the old name is worse than no
 * rename: an unset variable falls back to a *default*, so an already-configured
 * deployment would silently start serving a different database rather than
 * failing loudly. The old name still works and says it is deprecated.
 * @param name {string} the current variable name
 * @return {string} the deprecated equivalent, or "" if the name is not ours
 */
export func legacyNameOf(name as string) {
    if (not strings.startsWith($name, PREFIX)) {
        return "";
    }
    return LEGACY_PREFIX + strings.substring($name, len(PREFIX), len($name));
}

/**
 * Why this configuration cannot be served, or "" when it can.
 *
 * Checked once at boot rather than discovered at the first request. A registry
 * that starts and then fails every HTTPS connection because nobody named a
 * domain is worse than one that refuses to start and says which key is missing.
 * @param cfg {Config} the resolved configuration
 * @return {string} the complaint, or "" when the configuration is usable
 */
export func problem(cfg as Config) {
    if (not $cfg.tls.enabled) {
        return "";
    }
    if (len($cfg.tls.domains) == 0) {
        return "tls.enabled is set but no tls.domains are configured";
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
 * Is this directory URL the CA's staging endpoint? Used to say so at boot,
 * because a staging certificate is untrusted and the resulting browser warning
 * is otherwise a confusing way to find out.
 * @param directory {string} the configured directory URL
 * @return {bool} true when it looks like a staging endpoint
 */
export func isStaging(directory as string) {
    return strings.contains(strings.lower($directory), "staging");
}

/**
 * The address rendered as a URL for the boot banner.
 *
 * A listen address is a host and a port, and the host half is routinely empty:
 * `:8080` means every interface. Only in that case does a name have to be
 * invented to make a clickable URL, and `localhost` is the right invention,
 * because the person reading the banner is at the machine. When the address
 * already carries a host, prefixing one produces `localhost127.0.0.1:8080` -
 * not a URL, and misleading about what the server is bound to.
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
# variable or an unreadable file yields "", which reads as "not configured"
# rather than as an empty secret - a registry that silently signed tokens with an
# empty key would accept forged ones.
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
 * @field deprecated {list of string} names found only under the old prefix, for
 *     the caller to warn about
 */
export def struct EnvRead {
    values as map of string to string,
    deprecated as list of string
};

/**
 * Read the named variables, falling back to their pre-rename names.
 *
 * The one impure function here. It is in this module rather than in each entry
 * point so the fallback exists in exactly one place: three programs quietly
 * disagreeing about whether the old names still work is how a deployment ends up
 * half-migrated.
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
        # `NAME_FILE` names a file to read the value out of, which is how an
        # orchestrator hands over a secret: Docker Swarm and Kubernetes both
        # mount secrets as files, and neither can put one into the environment
        # without it also appearing in `docker inspect` and every child process.
        # A secret in a file is readable by this process and nothing else.
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
    return EnvRead{ values: $values, deprecated: $deprecated };
}
