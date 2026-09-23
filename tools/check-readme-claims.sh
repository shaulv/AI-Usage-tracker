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
check "swift files"        14 "$(find . -name '*.swift' | wc -l | tr -d ' ')"
check "test functions"     37 "$(grep -rhoE 'func test_' Tests | wc -l | tr -d ' ')"
check "provider tests"     16 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/ChatGPTUsageProviderTests.swift | tr -d ' ')"
check "credentials tests"  14 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/CodexCredentialsTests.swift | tr -d ' ')"
check "store tests"         7 "$(grep -cE 'func test_' Tests/ChatGPTUsageCoreTests/UsageStoreTests.swift | tr -d ' ')"
check "json fixtures"      11 "$(ls Tests/ChatGPTUsageCoreTests/Fixtures/*.json | wc -l | tr -d ' ')"
check "html fixtures"       1 "$(ls Tests/ChatGPTUsageCoreTests/Fixtures/*.html | wc -l | tr -d ' ')"

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
if grep -rn -E 'TODO|FIXME|implement here|rest of (the )?code|similar to above|continue pattern|for brevity' --include='*.swift' . ; then
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
for f in sorted(pathlib.Path('.').rglob('*.swift')):
    s=strip(f.read_text())
    if s.count('{') != s.count('}'):
        print(f"FAIL  {f}: {s.count('{')} open vs {s.count('}')} close"); bad=1
print("ok    all balanced" if not bad else "")
sys.exit(bad)
PY
[ $? -ne 0 ] && fail=1

echo
echo "== no writes to the credential file, one network site =="
if grep -rn 'write(to:\|removeItem\|FileHandle' Sources/ ; then
  echo "FAIL  Sources/ writes to disk"; fail=1
else
  echo "ok    Sources/ never writes"
fi
check "URLSession call sites" 1 "$(grep -rc 'URLSession(' Sources/ChatGPTUsageCore/ChatGPTUsageProvider.swift | tr -d ' ')"

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
