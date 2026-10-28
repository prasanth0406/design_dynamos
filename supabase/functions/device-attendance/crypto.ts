// Signature and Android Key Attestation helpers for device-attendance.
import * as x509 from "npm:@peculiar/x509@1.14.3";
import {
  id_ce_keyDescription,
  NonStandardKeyDescription,
} from "npm:@peculiar/asn1-android@2.11.1";
import { AsnConvert } from "npm:@peculiar/asn1-schema@2.11.1";

const MAX_SPKI_BYTES = 200;
const MAX_SIGNATURE_BYTES = 80;
const MAX_CERT_BYTES = 8192;
const MAX_CHAIN_LENGTH = 10;

export function base64ToBytes(value: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) {
    throw new Error("invalid base64");
  }
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function bytesToHex(bytes: ArrayBuffer | Uint8Array): string {
  return Array.from(new Uint8Array(bytes))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  return bytesToHex(await crypto.subtle.digest("SHA-256", bytes));
}

/**
 * Android's SHA256withECDSA produces an ASN.1 DER `SEQUENCE { r INTEGER,
 * s INTEGER }`; WebCrypto expects the 64-byte IEEE P1363 `r || s` form.
 */
export function derToP1363(der: Uint8Array, size = 32): Uint8Array<ArrayBuffer> {
  let offset = 0;
  const readLength = (): number => {
    const first = der[offset++];
    if (first === undefined) throw new Error("truncated DER");
    if (first < 0x80) return first;
    if (first !== 0x81) throw new Error("unsupported DER length");
    const len = der[offset++];
    if (len === undefined || len < 0x80) throw new Error("non-minimal DER length");
    return len;
  };
  const readInteger = (): Uint8Array => {
    if (der[offset++] !== 0x02) throw new Error("expected INTEGER");
    const len = readLength();
    if (len === 0 || offset + len > der.length) throw new Error("bad INTEGER length");
    let value = der.subarray(offset, offset + len);
    offset += len;
    if (value[0] & 0x80) throw new Error("negative INTEGER");
    if (value.length > 1 && value[0] === 0 && !(value[1] & 0x80)) {
      throw new Error("non-minimal INTEGER");
    }
    if (value[0] === 0) value = value.subarray(1);
    if (value.length > size) throw new Error("INTEGER too large");
    const out = new Uint8Array(size);
    out.set(value, size - value.length);
    return out;
  };

  if (der[offset++] !== 0x30) throw new Error("expected SEQUENCE");
  const seqLen = readLength();
  if (offset + seqLen !== der.length) throw new Error("trailing DER bytes");
  const r = readInteger();
  const s = readInteger();
  if (offset !== der.length) throw new Error("trailing DER bytes");
  const raw = new Uint8Array(size * 2);
  raw.set(r, 0);
  raw.set(s, size);
  return raw;
}

export async function importP256PublicKey(spkiBase64: string): Promise<CryptoKey> {
  const spki = base64ToBytes(spkiBase64);
  if (spki.length > MAX_SPKI_BYTES) throw new Error("public key too large");
  return await crypto.subtle.importKey(
    "spki",
    spki,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
}

/** Verifies an Android Keystore SHA256withECDSA (DER) signature. */
export async function verifyDeviceSignature(
  spkiBase64: string,
  signatureBase64: string,
  payload: string,
): Promise<{ valid: boolean; detail?: string }> {
  try {
    const key = await importP256PublicKey(spkiBase64);
    const der = base64ToBytes(signatureBase64);
    if (der.length > MAX_SIGNATURE_BYTES) return { valid: false, detail: "signature too large" };
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      derToP1363(der),
      new TextEncoder().encode(payload),
    );
    return valid ? { valid } : { valid, detail: "signature mismatch" };
  } catch (error) {
    return { valid: false, detail: error instanceof Error ? error.message : "verify failed" };
  }
}

export interface AttestationSummary {
  present: boolean;
  chain_length: number;
  leaf_key_matches: boolean;
  chain_signatures_valid: boolean;
  challenge_matches: boolean;
  attestation_security_level: string | null;
  keymaster_security_level: string | null;
  root_spki_sha256: string | null;
  root_trusted: boolean;
  hardware_backed: boolean;
  trusted: boolean;
  errors: string[];
}

const securityLevelName = (value: unknown): string | null => {
  switch (Number(value)) {
    case 0: return "software";
    case 1: return "trusted_environment";
    case 2: return "strongbox";
    default: return value === undefined ? null : String(value);
  }
};

/**
 * Checks an Android Key Attestation certificate chain: the leaf certifies the
 * submitted public key, every certificate is signed by the next, the
 * attestation challenge equals the server nonce, and the key lives in a TEE or
 * StrongBox. `trustedRootSpkiSha256` holds SHA-256 fingerprints (hex) of the
 * Google hardware attestation root public keys you trust.
 *
 * Revocation status (https://android.googleapis.com/attestation/status) is not
 * checked here.
 */
export async function summarizeAttestation(
  chainBase64: unknown,
  spkiBase64: string,
  nonceBase64: string,
  trustedRootSpkiSha256: string[],
): Promise<AttestationSummary> {
  const summary: AttestationSummary = {
    present: false,
    chain_length: 0,
    leaf_key_matches: false,
    chain_signatures_valid: false,
    challenge_matches: false,
    attestation_security_level: null,
    keymaster_security_level: null,
    root_spki_sha256: null,
    root_trusted: false,
    hardware_backed: false,
    trusted: false,
    errors: [],
  };
  if (!Array.isArray(chainBase64) || chainBase64.length === 0) {
    summary.errors.push("no attestation chain");
    return summary;
  }
  if (chainBase64.length > MAX_CHAIN_LENGTH) {
    summary.errors.push("attestation chain too long");
    return summary;
  }
  summary.present = true;
  summary.chain_length = chainBase64.length;

  try {
    const certs = chainBase64.map((entry) => {
      if (typeof entry !== "string") throw new Error("certificate is not a string");
      const der = base64ToBytes(entry);
      if (der.length > MAX_CERT_BYTES) throw new Error("certificate too large");
      return new x509.X509Certificate(der);
    });

    const leafSpki = new Uint8Array(certs[0].publicKey.rawData);
    summary.leaf_key_matches = bytesToHex(leafSpki) === bytesToHex(base64ToBytes(spkiBase64));

    let chainValid = true;
    for (let i = 0; i < certs.length; i++) {
      const issuer = certs[Math.min(i + 1, certs.length - 1)];
      const ok = await certs[i].verify({ publicKey: issuer.publicKey, signatureOnly: true });
      if (!ok) chainValid = false;
    }
    summary.chain_signatures_valid = chainValid;

    const root = certs[certs.length - 1];
    summary.root_spki_sha256 = await sha256Hex(new Uint8Array(root.publicKey.rawData));
    summary.root_trusted = trustedRootSpkiSha256
      .map((v) => v.trim().toLowerCase())
      .includes(summary.root_spki_sha256);

    const extension = certs[0].getExtension(id_ce_keyDescription);
    if (!extension) {
      summary.errors.push("leaf has no key description extension");
    } else {
      const description = AsnConvert.parse(extension.value, NonStandardKeyDescription);
      summary.attestation_security_level = securityLevelName(description.attestationSecurityLevel);
      summary.keymaster_security_level = securityLevelName(description.keymasterSecurityLevel);
      const challenge = new Uint8Array(description.attestationChallenge.buffer);
      summary.challenge_matches = bytesToHex(challenge) === bytesToHex(base64ToBytes(nonceBase64));
      summary.hardware_backed = summary.keymaster_security_level === "trusted_environment" ||
        summary.keymaster_security_level === "strongbox";
    }
  } catch (error) {
    summary.errors.push(error instanceof Error ? error.message : "attestation parse failed");
  }

  summary.trusted = summary.leaf_key_matches && summary.chain_signatures_valid &&
    summary.challenge_matches && summary.root_trusted && summary.hardware_backed;
  return summary;
}
