#!/usr/bin/env python3
"""Read-only probe for Claude's web usage endpoint.

Reads Claude Desktop's cookie store the same way the app does (Keychain key
"Claude Safe Storage" -> PBKDF2-SHA1(saltysalt, 1003, 16) -> AES-128-CBC with a
16-space IV, stripping the v10 prefix and the 32-byte block) and then makes ONE
GET. Nothing is written back to the cookie store and no cookie or key is ever
printed: only lengths, the account id, and the HTTP status.

This exists to answer "is it us or is it Cloudflare" without guessing. As of
23/09/2026 the answer is Cloudflare.

Usage:  python3 tools/probe-claude-cookies.py
Exit:   0 if the endpoint returned 200, 1 otherwise (403 challenge included).
"""
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import urllib.request

COOKIES_DB = os.path.expanduser("~/Library/Application Support/Claude/Cookies")
KEYCHAIN_SERVICE = "Claude Safe Storage"
UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)


def keychain_password():
    result = subprocess.run(
        ["security", "find-generic-password", "-w", "-s", KEYCHAIN_SERVICE],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.rstrip("\n")


def derive_key(password):
    # Same recipe the app uses, proven by a live probe before the Swift was written.
    return hashlib.pbkdf2_hmac("sha1", password.encode(), b"saltysalt", 1003, 16)


def decrypt(ciphertext, key):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    body = ciphertext[3:] if ciphertext[:3] in (b"v10", b"v11") else ciphertext
    body = body[32:]  # Chromium stores a 32-byte domain salt prefix
    decryptor = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).decryptor()
    padded = decryptor.update(body) + decryptor.finalize()
    pad = padded[-1]
    return padded[:-pad].decode("utf-8", errors="replace")


def read_cookies():
    if not os.path.exists(COOKIES_DB):
        sys.exit(f"no cookie store at {COOKIES_DB} (is Claude Desktop installed and signed in?)")
    key = derive_key(keychain_password())
    connection = sqlite3.connect(f"file:{COOKIES_DB}?mode=ro", uri=True)
    rows = connection.execute(
        "SELECT name, encrypted_value FROM cookies WHERE host_key LIKE '%claude.ai%'"
    ).fetchall()
    connection.close()
    return {name: decrypt(value, key) for name, value in rows if value}


def main():
    cookies = read_cookies()
    session_key = cookies.get("sessionKey")
    org = cookies.get("lastActiveOrg")
    print(f"sessionKey: {'present, %d chars' % len(session_key) if session_key else 'MISSING'}")
    print(f"lastActiveOrg: {org or 'MISSING'}")
    print(f"cf_clearance: {'present, %d chars' % len(cookies['cf_clearance']) if cookies.get('cf_clearance') else 'absent'}")
    if not session_key or not org:
        return 1

    cookie_header = "; ".join(
        f"{name}={cookies[name]}" for name in ("sessionKey", "cf_clearance", "lastActiveOrg") if cookies.get(name)
    )
    url = f"https://claude.ai/api/organizations/{org}/usage"
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": UA, "Cookie": cookie_header},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = json.load(response)
            print(f"HTTP {response.status}")
            print(json.dumps(body, indent=2)[:1200])
            return 0
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        print(f"HTTP {error.code}")
        print(f"cf-mitigated: {error.headers.get('cf-mitigated')}")
        marker = "Just a moment" in body or "cf_chl_" in body
        print(f"cloudflare challenge marker in body: {marker}")
        print(f"body prefix: {re.sub(chr(10), ' ', body[:200])}")
        return 1
    except Exception as error:  # noqa: BLE001 - the probe reports, it does not handle
        print(f"request failed: {type(error).__name__}: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
