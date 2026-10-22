# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * A caller's forge credential, sealed for storage.
 *
 * Where identity and forge are one service, the token a login yields is the only
 * credential that can ask the forge whether that person may push to a
 * repository, which is how a publish establishes source authority
 * (specification 7.1, route A). So it is kept - but never in the clear. It is
 * sealed with AES-256-GCM under a key derived from the registry's signing key,
 * so a copied database alone is a list of ciphertexts, and tampering with one
 * fails authentication instead of producing a different token.
 *
 * The key is derived rather than reused: HKDF with a purpose label gives this
 * use its own key, so a weakness in how one is used cannot carry over to the
 * other. Rotating the signing key makes every sealed credential unreadable,
 * which is the right failure: those accounts are asked to log in again.
 * @module forgecred
 * @example
 * import "./forgecred.j" as forgecred;
 * def sealed as string init forgecred.seal($signingKey, $accessToken);
 * def token as string init forgecred.unseal($signingKey, $sealed);
 */

use crypto;
use convert;
use encoding;

# Names this key's purpose. Changing it makes every stored credential unreadable,
# which is how a future change of format would retire the old ones.
def const KEY_LABEL as string init "jvc-registry forge-credential v1";

# sealingKey derives the AES-256 key for this purpose from the signing key.
func sealingKey(signingKey as bytes) {
    def salt as bytes init convert.bytesFromString("", "utf-8");
    return crypto.hkdf(
        $signingKey,
        $salt,
        convert.bytesFromString(KEY_LABEL, "utf-8"),
        32,
        "sha256");
}

/**
 * Seal a credential for storage.
 * @param signingKey {bytes} the registry's signing key
 * @param credential {string} the credential, in the clear
 * @return {string} the sealed form, base64 text safe to store in JSON
 */
export func seal(signingKey as bytes, credential as string) {
    def sealed as bytes init crypto.encrypt(
        sealingKey($signingKey),
        convert.bytesFromString($credential, "utf-8"));
    return encoding.toText($sealed, "base64");
}

/**
 * Recover a sealed credential.
 * @param signingKey {bytes} the registry's signing key
 * @param sealed {string} what `seal` returned
 * @return {string} the credential
 * @throws {Error} when the text is not a sealed credential, was sealed under
 *     another key, or was altered
 */
export func unseal(signingKey as bytes, sealed as string) {
    def raw as bytes init encoding.fromText($sealed, "base64");
    return convert.stringFromBytes(crypto.decrypt(sealingKey($signingKey), $raw), "utf-8");
}
