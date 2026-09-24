#!/usr/bin/env python3
"""Read-only probe for ChatGPT's usage endpoint.

Exists so a live check never has to be an ad-hoc fragment: it prints exactly what
the app's provider receives, using the same credential file and the same headers.
Prints no token: only its length and the decoded expiry are shown.

Usage:  python3 tools/probe-chatgpt-payload.py
Exit:   0 on HTTP 200 with a parsed payload, 1 otherwise.
"""
import json
import os
import sys
import time
import urllib.request

AUTH = os.path.expanduser("~/.codex/auth.json")
USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"


def load_credentials():
    with open(AUTH) as handle:
        payload = json.load(handle)
    tokens = payload.get("tokens") or {}
    token = tokens.get("access_token")
    if not token:
        sys.exit("no tokens.access_token in auth.json (sign in with: codex login)")
    return token, tokens.get("account_id")


def describe_windows(rate_limit):
    for key in ("primary_window", "secondary_window"):
        window = (rate_limit or {}).get(key)
        if not window:
            print(f"  {key}: absent")
            continue
        seconds = window.get("limit_window_seconds")
        print(
            f"  {key}: used_percent={window.get('used_percent')} "
            f"window={seconds}s reset_after={window.get('reset_after_seconds')}s"
        )


def main():
    token, account_id = load_credentials()
    print(f"token: {len(token)} chars (not printed), account_id: {'set' if account_id else 'absent'}")

    request = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": "Bearer " + token,
            "ChatGPT-Account-Id": account_id or "",
            "Accept": "application/json",
            "originator": "codex_cli_rs",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = json.load(response)
            print(f"HTTP {response.status}")
    except Exception as error:  # noqa: BLE001 - the probe reports, it does not handle
        print(f"request failed: {type(error).__name__}: {error}")
        return 1

    print(f"plan_type: {body.get('plan_type')}")
    describe_windows(body.get("rate_limit"))
    print(f"code_review_rate_limit: {body.get('code_review_rate_limit')}")
    print(f"additional_rate_limits: {body.get('additional_rate_limits')}")
    print(f"probed at: {time.strftime('%H:%M:%S')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
