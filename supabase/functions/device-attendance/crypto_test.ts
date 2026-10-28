import {
  assert,
  assertEquals,
  assertFalse,
} from "jsr:@std/assert@1";
import { derToP1363, summarizeAttestation, verifyDeviceSignature } from "./crypto.ts";

const toB64 = (bytes: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes)));

// Builds a DER ECDSA signature from a raw WebCrypto signature, mirroring what
// Android's SHA256withECDSA returns.
function p1363ToDer(raw: Uint8Array): Uint8Array {
  const int = (v: Uint8Array) => {
    let i = 0;
    while (i < v.length - 1 && v[i] === 0) i++;
    let out = v.subarray(i);
    if (out[0] & 0x80) out = new Uint8Array([0, ...out]);
    return [0x02, out.length, ...out];
  };
  const body = [...int(raw.subarray(0, 32)), ...int(raw.subarray(32))];
  return new Uint8Array([0x30, body.length, ...body]);
}

async function keyAndSign(payload: string) {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const spki = toB64(await crypto.subtle.exportKey("spki", pair.publicKey));
  const raw = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(payload)));
  return { spki, der: p1363ToDer(raw), raw };
}

Deno.test("valid DER signature verifies", async () => {
  const { spki, der } = await keyAndSign("hello");
  assert((await verifyDeviceSignature(spki, toB64(der), "hello")).valid);
});

Deno.test("modified payload is rejected", async () => {
  const { spki, der } = await keyAndSign("purpose=mark_attendance");
  assertFalse((await verifyDeviceSignature(spki, toB64(der), "purpose=app_unlock")).valid);
});

Deno.test("tampered signature is rejected", async () => {
  const { spki, der } = await keyAndSign("hello");
  der[der.length - 1] ^= 0x01;
  assertFalse((await verifyDeviceSignature(spki, toB64(der), "hello")).valid);
});

Deno.test("signature from a different key is rejected", async () => {
  const a = await keyAndSign("hello");
  const b = await keyAndSign("hello");
  assertFalse((await verifyDeviceSignature(a.spki, toB64(b.der), "hello")).valid);
});

Deno.test("raw P1363 signature and garbage are rejected", async () => {
  const { spki, raw } = await keyAndSign("hello");
  assertFalse((await verifyDeviceSignature(spki, toB64(raw), "hello")).valid);
  assertFalse((await verifyDeviceSignature(spki, "!!!", "hello")).valid);
  assertFalse((await verifyDeviceSignature("AAAA", toB64(raw), "hello")).valid);
});

Deno.test("openssl-produced DER signature verifies", async () => {
  const dir = await Deno.makeTempDir();
  const run = async (args: string[]) => {
    const out = await new Deno.Command("openssl", { args, cwd: dir }).output();
    if (!out.success) throw new Error(new TextDecoder().decode(out.stderr));
  };
  await Deno.writeTextFile(`${dir}/msg`, "sdtt-device-auth-v1\npurpose=app_unlock");
  await run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "k.pem"]);
  await run(["ec", "-in", "k.pem", "-pubout", "-outform", "DER", "-out", "pub.der"]);
  await run(["dgst", "-sha256", "-sign", "k.pem", "-out", "sig.der", "msg"]);
  const spki = toB64(await Deno.readFile(`${dir}/pub.der`));
  const sig = toB64(await Deno.readFile(`${dir}/sig.der`));
  assert((await verifyDeviceSignature(spki, sig, "sdtt-device-auth-v1\npurpose=app_unlock")).valid);
});

Deno.test("derToP1363 rejects trailing bytes", () => {
  let threw = false;
  try {
    derToP1363(new Uint8Array([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01, 0x00]));
  } catch {
    threw = true;
  }
  assert(threw);
});

Deno.test("missing attestation chain is reported as untrusted", async () => {
  const summary = await summarizeAttestation([], "AAAA", "AAAA", []);
  assertFalse(summary.trusted);
  assertEquals(summary.present, false);
});

Deno.test("self-signed certificate without key description is untrusted", async () => {
  const dir = await Deno.makeTempDir();
  const run = async (args: string[]) => {
    const out = await new Deno.Command("openssl", { args, cwd: dir }).output();
    if (!out.success) throw new Error(new TextDecoder().decode(out.stderr));
  };
  await run(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
    "-nodes", "-keyout", "k.pem", "-outform", "DER", "-out", "c.der", "-subj", "/CN=t", "-days", "1"]);
  await run(["ec", "-in", "k.pem", "-pubout", "-outform", "DER", "-out", "pub.der"]);
  const cert = toB64(await Deno.readFile(`${dir}/c.der`));
  const spki = toB64(await Deno.readFile(`${dir}/pub.der`));
  const summary = await summarizeAttestation([cert], spki, "AAAA", []);
  assert(summary.leaf_key_matches);
  assert(summary.chain_signatures_valid);
  assertFalse(summary.challenge_matches);
  assertFalse(summary.trusted);
});
