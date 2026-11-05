#!/usr/bin/env python3
"""Sign mod/ and zip it as an HMG-API package, on the Mac (the key never goes to the car).

    ./build.py keygen <key>   new author key: <key> (base64 PKCS#8) and <key>.pub (base64 X.509)
    ./build.py <key> <hmg-api checkout>
                              writes dist/<id>-v<major.minor>.hmgapi.zip and, for a flash drive,
                              dist/<id>-v<major.minor>-hmgapi-usb.zip (HMGAPI/updates/<id>-v<major.minor>.zip inside)
                              and dist/<id>-v<major.minor>-nemesis-usb.zip (made by the checkout's
                              tools/mknemesismod.sh, needs unzip and zip)

Same files and manifest as `hmgapi.engine.Signing sign`: SHA256withECDSA over
META-HMGAPI/manifest.json, the uuid derived from the public key, so keys made by
either tool work with both. Needs openssl.
"""
import base64, hashlib, json, os, shutil, subprocess, sys, tempfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "mod")
DIST = os.path.join(HERE, "dist")
META = "META-HMGAPI"


def openssl(*args, data=None):
    return subprocess.run(["openssl", *args], input=data, capture_output=True, check=True).stdout


def der_of(path):
    with open(path) as f:
        return base64.b64decode(f.read().strip())


def uuid_of(pub_der):
    d = bytearray(hashlib.sha256(pub_der).digest())
    d[6] = (d[6] & 15) | 128
    d[8] = (d[8] & 63) | 128
    h = d[:16].hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def keygen(key):
    for p in (key, key + ".pub"):
        if os.path.exists(p):
            sys.exit(f"{p} exists; not overwriting a key")
    pem = openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256")
    priv = openssl("pkcs8", "-topk8", "-nocrypt", "-outform", "DER", data=pem)
    pub = openssl("pkey", "-pubout", "-outform", "DER", data=pem)
    fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(base64.b64encode(priv).decode() + "\n")
    with open(key + ".pub", "w") as f:
        f.write(base64.b64encode(pub).decode() + "\n")
    print(f"wrote {key} and {key}.pub, uuid: {uuid_of(pub)}")


def files_of(root):
    out = []
    for dirpath, dirs, names in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        dirs[:] = [d for d in dirs if not (rel == "." and d == META)]
        for n in names:
            if n == ".DS_Store" or (rel == "." and n == ".disabled"):
                continue
            out.append(n if rel == "." else f"{rel}/{n}")
    return sorted(out)


def nemesis_usb(signed, mod, major_minor, hmgapi):
    """HMG-API's own tool wraps the signed zip; it names the result <id>-<version>-nemesis.zip."""
    tool = os.path.join(os.path.abspath(hmgapi), "tools", "mknemesismod.sh")
    with tempfile.TemporaryDirectory() as t:
        subprocess.run(["sh", tool, os.path.abspath(signed), t], check=True, capture_output=True)
        out = os.path.join(DIST, f"{mod['id']}-v{major_minor}-nemesis-usb.zip")
        shutil.move(os.path.join(t, f"{mod['id']}-{mod['version']}-nemesis.zip"), out)
    return out


def build(key, hmgapi):
    pub_path = key + ".pub"
    if not os.path.isfile(pub_path):
        sys.exit(f"no {pub_path}")
    pub = der_of(pub_path)
    mod = json.load(open(os.path.join(MOD, "mod.json")))
    files = {n: hashlib.sha256(open(os.path.join(MOD, n), "rb").read()).hexdigest() for n in files_of(MOD)}
    manifest = json.dumps({
        "format": 1, "id": mod["id"], "version": mod["version"],
        "uuid": uuid_of(pub), "key": base64.b64encode(pub).decode(), "files": files,
    }, indent=2).encode() + b"\n"

    with tempfile.TemporaryDirectory() as tmp:
        kpem = os.path.join(tmp, "k.pem")
        fd = os.open(kpem, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(openssl("pkey", "-inform", "DER", data=der_of(key)))
        sig = openssl("dgst", "-sha256", "-sign", kpem, data=manifest)
        # check against the public key the manifest carries, as the engine will
        ppem = os.path.join(tmp, "p.pem")
        sigf = os.path.join(tmp, "sig")
        open(ppem, "wb").write(openssl("pkey", "-pubin", "-inform", "DER", data=pub))
        open(sigf, "wb").write(sig)
        openssl("dgst", "-sha256", "-verify", ppem, "-signature", sigf, data=manifest)

    major_minor = ".".join(mod["version"].split(".")[:2])
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, f"{mod['id']}-v{major_minor}.hmgapi.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"{META}/manifest.json", manifest)
        z.writestr(f"{META}/signature", base64.b64encode(sig).decode() + "\n")
        for n in files:
            info = zipfile.ZipInfo.from_file(os.path.join(MOD, n), n)
            if n.endswith(".sh"):
                info.external_attr = 0o755 << 16
            z.writestr(info, open(os.path.join(MOD, n), "rb").read(), zipfile.ZIP_DEFLATED)
    usb = os.path.join(DIST, f"{mod['id']}-v{major_minor}-hmgapi-usb.zip")
    with zipfile.ZipFile(usb, "w", zipfile.ZIP_STORED) as z:
        z.write(out, f"HMGAPI/updates/{mod['id']}-v{major_minor}.zip")
    print(f"signed {mod['id']} {mod['version']}: {len(files)} files, uuid {uuid_of(pub)}")
    print(out)
    print(usb)
    print(nemesis_usb(out, mod, major_minor, hmgapi))


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "keygen":
        keygen(a[1])
    elif len(a) == 2:
        build(a[0], a[1])
    else:
        sys.exit(__doc__)
