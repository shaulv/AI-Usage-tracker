#!/usr/bin/env bash
# Re-checks the countable claims in README.md against the actual tree.
# Run it after any change to Sources/ or Tests/. A README that drifts from the
# code is worse than no README, because the next developer trusts it.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok    %-34s %s\n' "$1" "$3"
  else
    printf 'FAIL  %-34s README says %s, tree has %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

echo "== counts =="
# .build/ and build/ are build output, never source: prune it everywhere or a stale
# derived file makes every count a lie.
check "swift files"        43 "$(find . \( -path './.build' -o -path './build' \) -prune -o -name '*.swift' -print | wc -l | tr -d ' ')"
check "test functions"     159 "$(grep -rhoE 'func test_' Tests | wc -l | tr -d ' ')"
check "provider tests"     17 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/ChatGPTUsageProviderTests.swift | tr -d ' ')"
check "credentials tests"  15 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/CodexCredentialsTests.swift | tr -d ' ')"
check "store tests"        12 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/UsageStoreTests.swift | tr -d ' ')"
check "claude tests"       25 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/ClaudeUsageProviderTests.swift | tr -d ' ')"
check "header tests"       16 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/HeaderFormatterTests.swift | tr -d ' ')"
check "antigravity provider tests" 16 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/AntigravityUsageProviderTests.swift | tr -d ' ')"
check "antigravity session tests"   6 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/AntigravitySessionTests.swift | tr -d ' ')"
check "cursor credentials tests"    6 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/CursorCredentialsTests.swift | tr -d ' ')"
check "cursor provider tests"      14 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/CursorUsageProviderTests.swift | tr -d ' ')"
check "grok provider tests"        12 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/GrokUsageProviderTests.swift | tr -d ' ')"
check "grok credentials tests"      7 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/GrokCredentialsTests.swift | tr -d ' ')"
check "status engine tests"        13 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/UsageStatusEngineTests.swift | tr -d ' ')"
check "json fixtures"      25 "$(ls Tests/ChatGPTUsageCoreTests/Fixtures/*.json | wc -l | tr -d ' ')"
check "html fixtures"       2 "$(ls Tests/ChatGPTUsageCoreTests/Fixtures/*.html | wc -l | tr -d ' ')"

echo
echo "== every user-facing message in Sources/ must appear in README.md =="
python3 - <<'PY'
import re, pathlib, sys
src = " ".join(p.read_text() for p in pathlib.Path("Sources").rglob("*.swift"))
flat = re.sub(r"\s+", " ", src)
readme = pathlib.Path("README.md").read_text()
found = set()
for m in re.finditer(r'UsageProviderError\.(?:notConnected|fetchFailed)\(\s*"([^"$]*)"', flat):
    # A Swift interpolation renders as an angle-bracket placeholder in the docs,
    # so normalize before comparing or the check can never pass.
    found.add(re.sub(r"\\\([^)]*\)", "<...>", m.group(1)))
bad = 0
for msg in sorted(found):
    if "<...>" in msg:
        probe = msg.split("<...>")[0]
        ok = probe in readme
        how = f"prefix {probe!r}"
    else:
        ok = msg in readme
        how = "exact"
    if ok:
        print(f"ok    {msg}   [{how}]")
    else:
        print(f"FAIL  not documented in README: {msg}")
        bad = 1
print(f"({len(found)} distinct literal messages)")
sys.exit(bad)
PY
[ $? -ne 0 ] && fail=1

echo
echo "== banned placeholder patterns in Swift =="
if grep -rn -E 'TODO|FIXME|implement here|rest of (the )?code|similar to above|continue pattern|for brevity' --include='*.swift' --exclude-dir='.build' . ; then
  echo "FAIL  placeholders found"; fail=1
else
  echo "ok    none"
fi

echo
echo "== brace balance, strings and comments stripped =="
python3 - <<'PY'
import pathlib, sys
def strip(src):
    out=[]; i=0; n=len(src)
    while i<n:
        c=src[i]
        if c=='/' and i+1<n and src[i+1]=='/':
            j=src.find('\n', i); i = n if j<0 else j; continue
        if c=='/' and i+1<n and src[i+1]=='*':
            j=src.find('*/', i+2); i = n if j<0 else j+2; continue
        if src.startswith('"""', i):
            j=src.find('"""', i+3); i = n if j<0 else j+3; continue
        if c=='"':
            i+=1
            while i<n:
                if src[i]=='\\': i+=2; continue
                if src[i]=='"': i+=1; break
                i+=1
            continue
        out.append(c); i+=1
    return ''.join(out)
bad=0
for f in sorted(p for p in pathlib.Path('.').rglob('*.swift') if '.build' not in p.parts):
    s=strip(f.read_text())
    s=strip(f.read_text())
    if s.count('{') != s.count('}'):
        print(f"FAIL  {f}: {s.count('{')} open vs {s.count('}')} close"); bad=1
print("ok    all balanced" if not bad else "")
sys.exit(bad)
PY
[ $? -ne 0 ] && fail=1

echo
echo

echo "== no writes to the credential file, one network site =="
# Allowed: CursorCredentials.swift deletes ONLY its own /tmp snapshot copy
# (removeItem(at: tempURL)) plus the temp sidecars (-wal/-shm/-journal) that
# it copied alongside the snapshot. Any other write/remove/FileHandle fails.
if grep -rn 'write(to:' Sources/ ; then
  echo "FAIL  Sources/ writes to disk"; fail=1
elif grep -rn 'FileHandle' Sources/ ; then
  echo "FAIL  Sources/ writes to disk"; fail=1
elif grep -rn 'removeItem' Sources/ | grep -v 'tempURL' ; then
  echo "FAIL  Sources/ writes to disk"; fail=1
else
  echo "ok    Sources/ never writes (except its own /tmp snapshot cleanup)"
fi
check "URLSession call sites" 1 "$(grep -o 'URLSession(' Sources/ChatGPTUsageCore/ChatGPTUsageProvider.swift | wc -l | tr -d ' ')"

echo
echo "== fixtures parse =="
fixture_fail=0
for f in Tests/ChatGPTUsageCoreTests/Fixtures/*.json; do
  jq -e . "$f" >/dev/null 2>&1 || { echo "FAIL  $f"; fixture_fail=1; }
done
if [ $fixture_fail -eq 0 ]; then echo "ok    all fixtures parse"; else fail=1; fi

echo
if [ $fail -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit $fail
