#!/usr/bin/env python3
# Minimal App Store Connect API client: python3 asc.py METHOD PATH [json-body]
import json, sys, time, base64, urllib.request, urllib.error, os
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
# Reads ASC_KEY_ID, ASC_ISSUER and ASC_KEY_PATH from the environment (see config.example.env).
KID = os.environ["ASC_KEY_ID"]; ISS = os.environ["ASC_ISSUER"]
key = serialization.load_pem_private_key(open(os.path.expanduser(os.environ["ASC_KEY_PATH"]), "rb").read(), None)
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def token():
    h = b64(json.dumps({"alg": "ES256", "kid": KID, "typ": "JWT"}).encode())
    p = b64(json.dumps({"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 900, "aud": "appstoreconnect-v1"}).encode())
    r, s = decode_dss_signature(key.sign(f"{h}.{p}".encode(), ec.ECDSA(hashes.SHA256())))
    return f"{h}.{p}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"
method, path = sys.argv[1], sys.argv[2]
body = sys.argv[3].encode() if len(sys.argv) > 3 else None
req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, data=body, method=method,
                             headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req) as r:
        print(r.read().decode() or "{}")
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode(), file=sys.stderr); sys.exit(1)
