// ════════════════════════════════════════════════════════════════════
//  Apple App Attest verification
//
//  Proves a request came from a genuine, unmodified build of the app on real
//  Apple hardware. The device's private key is generated inside the Secure
//  Enclave and never leaves it, so unlike a shared key compiled into the binary
//  there is nothing an attacker can extract and reuse.
//
//  Two steps, mirroring AppAttestService.swift:
//    · attestation — once per install. Apple vouches for a new key with a
//      certificate chain that must terminate at Apple's App Attest root.
//    · assertion — every later request, signed by that key over the exact
//      parameters being sent.
//
//  Reference: Apple, "Validating Apps That Connect to Your Server".
// ════════════════════════════════════════════════════════════════════

/// Apple's App Attest root CA public key (SPKI, P-384), taken from
/// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
/// Pinned rather than fetched, so the trust anchor cannot be swapped at runtime.
const APPLE_ROOT_SPKI_B64 =
  "MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+" +
  "d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9auYen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41";

/// OID 1.2.840.113635.100.8.2 — the credCert extension carrying the nonce.
const NONCE_EXTENSION_OID = [1, 2, 840, 113635, 100, 8, 2];

// ─── Encoding helpers ───────────────────────────────────────────────
export function b64ToBytes(b64) {
  const bin = atob(String(b64).replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToB64(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)));
}

function bytesEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function sha256(...parts) {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const joined = new Uint8Array(total);
  let offset = 0;
  for (const p of parts) { joined.set(p, offset); offset += p.length; }
  return new Uint8Array(await crypto.subtle.digest("SHA-256", joined));
}

// ─── Minimal CBOR ───────────────────────────────────────────────────
// Only the subset Apple emits: unsigned ints, byte strings, text strings,
// arrays and maps. Anything else is a malformed attestation.
function decodeCBOR(bytes) {
  let pos = 0;

  function readLength(info) {
    if (info < 24) return info;
    if (info === 24) return bytes[pos++];
    if (info === 25) { const v = (bytes[pos] << 8) | bytes[pos + 1]; pos += 2; return v; }
    if (info === 26) {
      const v = ((bytes[pos] << 24) >>> 0) + (bytes[pos + 1] << 16) + (bytes[pos + 2] << 8) + bytes[pos + 3];
      pos += 4;
      return v;
    }
    throw new Error("cbor: unsupported length");
  }

  function readValue() {
    if (pos >= bytes.length) throw new Error("cbor: truncated");
    const byte = bytes[pos++];
    const major = byte >> 5;
    const info = byte & 0x1f;

    switch (major) {
      case 0: return readLength(info);
      case 2: { const n = readLength(info); const v = bytes.subarray(pos, pos + n); pos += n; return v; }
      case 3: { const n = readLength(info); const v = new TextDecoder().decode(bytes.subarray(pos, pos + n)); pos += n; return v; }
      case 4: { const n = readLength(info); const arr = []; for (let i = 0; i < n; i++) arr.push(readValue()); return arr; }
      case 5: {
        const n = readLength(info);
        const map = {};
        for (let i = 0; i < n; i++) { const k = readValue(); map[k] = readValue(); }
        return map;
      }
      default: throw new Error(`cbor: unsupported major type ${major}`);
    }
  }

  return readValue();
}

// ─── Minimal DER / ASN.1 ────────────────────────────────────────────
/// Reads one TLV, returning its tag, the raw content, and the full element
/// including header — the header matters because signatures cover it.
function readTLV(bytes, start) {
  const tag = bytes[start];
  let pos = start + 1;
  let length = bytes[pos++];

  if (length & 0x80) {
    const count = length & 0x7f;
    length = 0;
    for (let i = 0; i < count; i++) length = (length << 8) | bytes[pos++];
  }

  return {
    tag,
    headerLength: pos - start,
    length,
    content: bytes.subarray(pos, pos + length),
    element: bytes.subarray(start, pos + length),
    end: pos + length,
  };
}

function readChildren(content) {
  const items = [];
  let pos = 0;
  while (pos < content.length) {
    const tlv = readTLV(content, pos);
    items.push(tlv);
    pos = tlv.end;
  }
  return items;
}

function decodeOID(content) {
  const parts = [Math.floor(content[0] / 40), content[0] % 40];
  let value = 0;
  for (let i = 1; i < content.length; i++) {
    value = (value << 7) | (content[i] & 0x7f);
    if (!(content[i] & 0x80)) { parts.push(value); value = 0; }
  }
  return parts;
}

/// Pulls out the pieces of an X.509 certificate needed to verify it and to
/// verify the next certificate down the chain.
function parseCertificate(der) {
  const cert = readTLV(der, 0);
  const [tbs, sigAlg, sigBits] = readChildren(cert.content);
  const tbsItems = readChildren(tbs.content);

  // An explicit [0] version tag is optional; when present it shifts everything.
  let index = tbsItems[0].tag === 0xa0 ? 1 : 0;
  index += 1; // serialNumber
  index += 1; // signature algorithm
  index += 1; // issuer
  index += 1; // validity
  index += 1; // subject
  const spki = tbsItems[index];

  // Extensions live in the optional [3] tag at the end.
  let extensions = [];
  for (const item of tbsItems) {
    if (item.tag === 0xa3) {
      const seq = readTLV(item.content, 0);
      extensions = readChildren(seq.content).map(ext => {
        const parts = readChildren(ext.content);
        const oid = decodeOID(parts[0].content);
        const value = parts[parts.length - 1].content;
        return { oid, value };
      });
    }
  }

  return {
    tbsBytes: tbs.element,
    spkiBytes: spki.element,
    // BIT STRING content starts with an "unused bits" byte.
    signature: sigBits.content.subarray(1),
    signatureAlgorithm: decodeOID(readChildren(sigAlg.content)[0].content),
    extensions,
  };
}

/// WebCrypto wants r‖s; DER wraps them in a SEQUENCE of two INTEGERs.
function derSignatureToRaw(der, size) {
  const seq = readTLV(der, 0);
  const [r, s] = readChildren(seq.content);
  const out = new Uint8Array(size * 2);

  const place = (value, offset) => {
    // Strip the leading zero DER adds to keep INTEGERs positive, then right-align.
    let bytes = value.content;
    while (bytes.length > size && bytes[0] === 0) bytes = bytes.subarray(1);
    out.set(bytes, offset + size - bytes.length);
  };

  place(r, 0);
  place(s, size);
  return out;
}

const P256_OID = [1, 2, 840, 10045, 3, 1, 7];

/// Which curve an SPKI describes, so the right hash and signature size are used.
function curveOfSPKI(spkiBytes) {
  const spki = readTLV(spkiBytes, 0);
  const algorithm = readChildren(spki.content)[0];
  const params = readChildren(algorithm.content)[1];
  const oid = decodeOID(params.content);
  return oid.join(".") === P256_OID.join(".") ? "P-256" : "P-384";
}

/// ecdsa-with-SHA256 / SHA384 / SHA512
const SIGNATURE_HASHES = {
  "1.2.840.10045.4.3.2": "SHA-256",
  "1.2.840.10045.4.3.3": "SHA-384",
  "1.2.840.10045.4.3.4": "SHA-512",
};

async function verifySignedBy(child, parentSpkiBytes) {
  // The digest comes from the child's own signatureAlgorithm, not from the parent
  // key's curve: Apple signs the leaf with SHA-256 using a P-384 intermediate, so
  // inferring the hash from the curve rejects a perfectly valid chain.
  const hash = SIGNATURE_HASHES[child.signatureAlgorithm.join(".")];
  if (!hash) throw new Error("unsupported_signature_algorithm");

  // r and s are sized by the signing key's curve.
  const curve = curveOfSPKI(parentSpkiBytes);
  const size = curve === "P-256" ? 32 : 48;

  const key = await crypto.subtle.importKey(
    "spki", parentSpkiBytes, { name: "ECDSA", namedCurve: curve }, false, ["verify"]
  );

  return await crypto.subtle.verify(
    { name: "ECDSA", hash },
    key,
    derSignatureToRaw(child.signature, size),
    child.tbsBytes
  );
}

// ─── Attestation ────────────────────────────────────────────────────
/// Verifies a fresh attestation and returns the device public key to store.
/// Throws with a specific reason on any failure — the caller turns that into
/// a 401 rather than trusting a partially-checked attestation.
export async function verifyAttestation({ attestation, keyId, challenge, appId }) {
  const decoded = decodeCBOR(b64ToBytes(attestation));

  if (decoded.fmt !== "apple-appattest") throw new Error("bad_format");
  const x5c = decoded.attStmt?.x5c;
  if (!Array.isArray(x5c) || x5c.length < 2) throw new Error("missing_chain");

  const authData = decoded.authData;
  if (!authData || authData.length < 37) throw new Error("bad_auth_data");

  // 1. The chain must terminate at Apple's root.
  const leaf = parseCertificate(x5c[0]);
  const intermediate = parseCertificate(x5c[1]);
  const rootSpki = b64ToBytes(APPLE_ROOT_SPKI_B64);

  if (!await verifySignedBy(intermediate, rootSpki)) throw new Error("intermediate_not_trusted");
  if (!await verifySignedBy(leaf, intermediate.spkiBytes)) throw new Error("leaf_not_trusted");

  // 2. The nonce binds this attestation to our one-time challenge.
  const clientDataHash = await sha256(new TextEncoder().encode(challenge));
  const expectedNonce = await sha256(authData, clientDataHash);

  const nonceExt = leaf.extensions.find(
    e => e.oid.join(".") === NONCE_EXTENSION_OID.join(".")
  );
  if (!nonceExt) throw new Error("missing_nonce_extension");

  // The extension wraps the digest in SEQUENCE { [1] { OCTET STRING } }.
  const outer = readTLV(nonceExt.value, 0);
  const tagged = readTLV(outer.content, 0);
  const octets = readTLV(tagged.content, 0);
  if (!bytesEqual(octets.content, expectedNonce)) throw new Error("nonce_mismatch");

  // 3. authData must describe our app, a fresh key, and a real device.
  const rpIdHash = authData.subarray(0, 32);
  const expectedRpId = await sha256(new TextEncoder().encode(appId));
  if (!bytesEqual(rpIdHash, expectedRpId)) throw new Error("app_id_mismatch");

  const counter = new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0);
  if (counter !== 0) throw new Error("counter_not_zero");

  const aaguid = new TextDecoder().decode(authData.subarray(37, 53)).replace(/\0+$/, "");
  if (aaguid !== "appattest" && aaguid !== "appattestdevelop") throw new Error("bad_aaguid");

  const credIdLength = new DataView(authData.buffer, authData.byteOffset + 53, 2).getUint16(0);
  const credId = authData.subarray(55, 55 + credIdLength);
  if (!bytesEqual(credId, b64ToBytes(keyId))) throw new Error("key_id_mismatch");

  // 4. The leaf's public key is what future assertions are checked against.
  return { publicKey: bytesToB64(leaf.spkiBytes), signCount: counter };
}

// ─── Assertion ──────────────────────────────────────────────────────
/// Verifies a per-request assertion against the stored device public key.
export async function verifyAssertion({ assertion, publicKey, clientData, appId, lastCount }) {
  const decoded = decodeCBOR(b64ToBytes(assertion));
  const authData = decoded.authenticatorData;
  const signature = decoded.signature;
  if (!authData || !signature) throw new Error("bad_assertion");

  const rpIdHash = authData.subarray(0, 32);
  const expectedRpId = await sha256(new TextEncoder().encode(appId));
  if (!bytesEqual(rpIdHash, expectedRpId)) throw new Error("app_id_mismatch");

  // The counter only ever moves forward; a replayed assertion cannot.
  const counter = new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0);
  if (counter <= Number(lastCount || 0)) throw new Error("replayed");

  const clientDataHash = await sha256(new TextEncoder().encode(clientData));
  const digest = await sha256(authData, clientDataHash);

  const key = await crypto.subtle.importKey(
    "spki", b64ToBytes(publicKey), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]
  );

  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    derSignatureToRaw(signature, 32),
    digest
  );

  if (!ok) throw new Error("bad_signature");
  return { signCount: counter };
}
