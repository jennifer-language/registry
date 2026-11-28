# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.28.0

/**
 * A caller's forge credential, sealed for storage.
 *
 * Where identity and forge are one service, the login token is the credential
 * that asks the forge whether a person may push (specification 7.1, route A).
 * It is stored sealed with AES-256-GCM, so a copied database alone yields only
 * ciphertexts and a tampered record fails authentication. The stored form is
 * `nonce (12 bytes) || ciphertext || tag (16 bytes)` with no additional data,
 * the layout the two-argument `crypto.encrypt` of jennifer 0.25 wrote, so
 * credentials sealed before the 0.26 `crypto` API stay readable.
 *
 * The key is derived from the signing key with HKDF and a purpose label, so the
 * two uses do not share a key. Rotating the signing key makes every sealed
 * credential unreadable, and those accounts must log in again.
 * @module forgecred
 * @example
 * import "./forgecred.j" as forgecred;
 * def sealed as string init forgecred.seal($signingKey, $accessToken);
 * def token as string init forgecred.unseal($signingKey, $sealed);
 */

use crypto;
use binary;
use encoding;

# Names this key's purpose. Changing it makes every stored credential unreadable.
def const KEY_LABEL as string init "jvc-registry forge-credential v1";
# The AES-GCM nonce and tag lengths: a sealed record is at least both.
def const NONCE_LEN as int init 12;
def const TAG_LEN as int init 16;

# sealingKey derives the AES-256 key for this purpose from the signing key.
func sealingKey(signingKey as bytes) {
    def salt as bytes init encoding.encode("utf-8", "");
    return crypto.deriveKey(
        "hkdf-sha256",
        $signingKey,
        $salt,
        32,
        crypto.KdfParams{info: encoding.encode("utf-8", KEY_LABEL)});
}

/**
 * Seal a credential for storage.
 * @param signingKey {bytes} the registry's signing key
 * @param credential {string} the credential, in the clear
 * @return {string} the sealed form, base64 text safe to store in JSON
 */
export func seal(signingKey as bytes, credential as string) {
    # A fresh random nonce per record, stored in front of the box: one key
    # seals many records, and a nonce must never repeat under one key.
    def nonce as bytes init crypto.randBytes(NONCE_LEN);
    def noAad as bytes;
    def box as bytes init crypto.encrypt(
        "aes-gcm",
        encoding.encode("utf-8", $credential),
        sealingKey($signingKey),
        $nonce,
        $noAad);
    return encoding.toText("base64", binary.concat($nonce, $box));
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
    def raw as bytes init encoding.fromText("base64", $sealed);
    if (len($raw) < NONCE_LEN + TAG_LEN) {
        throw Error{kind: "runtime", message: "forgecred.unseal: not a sealed credential"};
    }
    def noAad as bytes;
    def plain as bytes init crypto.decrypt(
        "aes-gcm",
        $raw[NONCE_LEN..],
        sealingKey($signingKey),
        $raw[0..NONCE_LEN],
        $noAad);
    return encoding.decode("utf-8", $plain);
}
