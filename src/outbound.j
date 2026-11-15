# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * Outbound requests to a forge or an identity provider, made through one
 * function so each is counted and a failed one is logged with why.
 *
 * A `Trace` rides along in `forge.Config` and `identity.Config`. The server
 * hands a copy carrying the request's id and its log sink to each request; the
 * boot-time copy, and every test, carry `none()`, which logs nothing.
 *
 * A call that fails (no reply, or any status but 2xx, 3xx and 404) is one
 * `warn` event; the rest are `debug`. A 404 is how the adapters ask whether
 * something exists, so it is an answer, not a failure. The event never holds a
 * header the registry sent, a query string or a body: only the forge's own
 * error `message`, cut short, and the rate-limit and request-id headers it
 * answered with.
 * @module outbound
 */

use kv;
use maps;
use json;
use time;
use strings;
use convert;
import "http.j" as http;
import "./audit.j" as audit;

# How much of a forge's error message the event keeps.
def const MESSAGE_MAX as int init 200;
# A counter outlives its request by this much at most; the summary deletes it.
def const COUNTER_TTL_SECONDS as int init 600;

/**
 * Where a request's outbound calls are logged and counted.
 * @field requestId {string} the id of the request that makes the calls ("" for none)
 * @field sink {audit.Sink} where the call events go
 * @field counter {kv.Store} the shared counter store, keyed by request id
 * @field on {bool} false for `none()`: no event, no count
 */
export def struct Trace {
    requestId as string,
    sink as audit.Sink,
    counter as kv.Store,
    on as bool
};

/**
 * A trace that records nothing, for the boot-time configuration and tests.
 * @return {Trace} a disabled trace
 */
export func none() {
    return Trace{requestId: "", sink: audit.silent(), counter: kv.open(), on: false};
}

/**
 * A trace for one request.
 * @param sink {audit.Sink} the log sink, already carrying the request id
 * @param requestId {string} the request's id, the key its calls are counted under
 * @param counter {kv.Store} the process-wide counter store
 * @return {Trace} an enabled trace
 */
export func traced(sink as audit.Sink, requestId as string, counter as kv.Store) {
    return Trace{requestId: $requestId, sink: $sink, counter: $counter, on: true};
}

/**
 * How many outbound calls a request has made so far.
 * @param t {Trace} the request's trace
 * @return {int} the count, 0 when there were none or the trace is off
 */
export func calls(t as Trace) {
    if (not $t.on or not kv.has($t.counter, counterKey($t.requestId))) {
        return 0;
    }
    return convert.toInt(kv.get($t.counter, counterKey($t.requestId)));
}

/**
 * Forget a request's count, once its summary is written.
 * @param t {Trace} the request's trace
 */
export func forget(t as Trace) {
    if ($t.on) {
        kv.delete($t.counter, counterKey($t.requestId));
    }
}

func counterKey(requestId as string) {
    return "outbound " + $requestId;
}

# count adds one call; `kv.incr` does not create a key, hence add-then-retry.
func count(t as Trace) {
    if (not $t.on) {
        return;
    }
    def key as string init counterKey($t.requestId);
    if (kv.incr($t.counter, $key, 1) == -1) {
        if (not kv.add($t.counter, $key, "1", COUNTER_TTL_SECONDS)) {
            kv.incr($t.counter, $key, 1);
        }
    }
}

/**
 * Send one request through `http.requestWith`, counting it and logging it.
 * Returns or throws exactly what `http.requestWith` does.
 * @param t {Trace} the request's trace
 * @param service {string} who is asked: the forge's name, or "identity"
 * @param method {string} the HTTP method
 * @param url {string} the absolute URL
 * @param headers {map of string to string} the request headers (never logged)
 * @param body {string} the request body (never logged)
 * @param timeoutMs {int} the idle timeout
 * @param maxBytes {int} the response-body cap
 * @return {http.Response} the response
 */
export func request(
    t as Trace,
    service as string,
    method as string,
    url as string,
    headers as map of string to string,
    body as string,
    timeoutMs as int,
    maxBytes as int) {
    def started as int init time.unixMillis(time.now());
    def res as http.Response;
    try {
        $res = http.requestWith($method, $url, $headers, $body, $timeoutMs, $maxBytes);
    } catch (err) {
        count($t);
        if ($t.on) {
            def detail as map of string to string init {};
            if ($err.kind == "net") {
                # Always a net.NetError (jennifer M28.65).
                $detail["reason"] = $err.reason;
                $detail["sent"] = convert.toString($err.sent);
                $detail["replied"] = convert.toString($err.replied);
            }
            audit.write(
                $t.sink,
                callFailed($service, $method, pathOf($url), elapsed($started), $err.kind, $detail));
        }
        throw $err;
    }
    count($t);
    if ($t.on) {
        audit.write(
            $t.sink,
            callAnswered(
                $service,
                $method,
                pathOf($url),
                $res.status,
                elapsed($started),
                $res.headers,
                $res.body));
    }
    return $res;
}

func elapsed(started as int) {
    return time.unixMillis(time.now()) - $started;
}

/**
 * The path of a URL without its scheme, host or query, which could carry a
 * token. Pure.
 * @param url {string} the absolute URL
 * @return {string} the path, "/" when there is none
 */
export func pathOf(url as string) {
    def rest as string init $url;
    def scheme as int init strings.indexOf($rest, "://");
    if ($scheme >= 0) {
        $rest = strings.substring($rest, $scheme + 3, len($rest));
        def slash as int init strings.indexOf($rest, "/");
        if ($slash < 0) {
            return "/";
        }
        $rest = strings.substring($rest, $slash, len($rest));
    }
    for (def cut in ["?", "#"]) {
        def at as int init strings.indexOf($rest, $cut);
        if ($at >= 0) {
            $rest = strings.substring($rest, 0, $at);
        }
    }
    return $rest;
}

# The response headers an event keeps: who answered and what rate limit it
# applied. GitHub's, then GitLab's.
def const KEPT_HEADERS as list of string init [
    "x-github-request-id",
    "x-ratelimit-remaining",
    "x-ratelimit-reset",
    "retry-after",
    "ratelimit-remaining",
    "ratelimit-reset",
    "x-request-id"
];

/**
 * The event for a call that got a reply. Pure. `warn` unless the status is
 * 2xx, 3xx or 404, then `debug`.
 * @param service {string} who was asked
 * @param method {string} the HTTP method
 * @param path {string} the path, from `pathOf`
 * @param status {int} the status
 * @param ms {int} how long the call took
 * @param headers {map of string to string} the response headers, keys lowercased
 * @param body {string} the response body; only its `message` is read, and only
 *     on a failure
 * @return {audit.Event} the event
 */
export func callAnswered(
    service as string,
    method as string,
    path as string,
    status as int,
    ms as int,
    headers as map of string to string,
    body as string) {
    def failed as bool init not (($status >= 200 and $status < 400) or $status == 404);
    def f as map of string to string init baseFields($service, $method, $path, $status, $ms);
    for (def name in KEPT_HEADERS) {
        if (maps.has($headers, $name)) {
            $f[$name] = cut($headers[$name], 64);
        }
    }
    if (not $failed) {
        return audit.Event{level: audit.DEBUG, message: "outbound call", fields: $f};
    }
    $f["kind"] = "status";
    def said as string init messageOf($body);
    if (not ($said == "")) {
        $f["message"] = $said;
    }
    return audit.Event{level: audit.WARN, message: "outbound call failed", fields: $f};
}

/**
 * The event for a call that got no reply. Pure.
 * @param service {string} who was asked
 * @param method {string} the HTTP method
 * @param path {string} the path, from `pathOf`
 * @param ms {int} how long the call took
 * @param kind {string} the error kind (`net`, `timeout`, `closed`, `limit`, `http`)
 * @param detail {map of string to string} a NetError's `reason`, `sent` and `replied`
 * @return {audit.Event} the event, at `warn`
 */
export func callFailed(
    service as string,
    method as string,
    path as string,
    ms as int,
    kind as string,
    detail as map of string to string) {
    def f as map of string to string init baseFields($service, $method, $path, 0, $ms);
    $f["kind"] = $kind;
    for (def k in ["reason", "sent", "replied"]) {
        if (maps.has($detail, $k)) {
            $f[$k] = $detail[$k];
        }
    }
    return audit.Event{level: audit.WARN, message: "outbound call failed", fields: $f};
}

func baseFields(service as string, method as string, path as string, status as int, ms as int) {
    return {
        "service": $service,
        "method": $method,
        "path": cut($path, 256),
        "status": convert.toString($status),
        "ms": convert.toString($ms)
    };
}

/**
 * The error text a forge or provider put in a JSON error body: `message`
 * (GitHub, Gitea, GitLab), else OAuth's `error_description` or `error`. Cut to
 * 200 characters; "" when the body is not such a JSON object. Pure.
 * @param body {string} the response body
 * @return {string} the message, or ""
 */
export func messageOf(body as string) {
    def doc as json.Value;
    try {
        $doc = json.decode($body);
    } catch (err) {
        return "";
    }
    if (not (json.typeOf($doc, "") == "map")) {
        return "";
    }
    for (def field in ["/message", "/error_description", "/error"]) {
        if (json.typeOf($doc, $field) == "string") {
            return cut(json.asString($doc, $field), MESSAGE_MAX);
        }
    }
    return "";
}

func cut(s as string, max as int) {
    if (len($s) <= $max) {
        return $s;
    }
    return strings.substring($s, 0, $max) + "...";
}
