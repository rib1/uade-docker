#!/bin/sh

set -eu

failures=0

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# The web image must not run its application or native converter as root.
if [ "$(id -u)" -ne 0 ]; then
  pass "runtime process is non-root"
else
  fail "runtime process is root"
fi

# A runtime image must not expose the host Docker control socket.
if [ ! -e /var/run/docker.sock ]; then
  pass "Docker socket is not present"
else
  fail "Docker socket is present"
fi

# A setuid converter can regain root even when the container starts non-root.
uade_permissions="$(stat -c '%A' /usr/local/bin/uade123 2>/dev/null || true)"
uade_mode="$(stat -c '%a' /usr/local/bin/uade123 2>/dev/null || true)"
case "$uade_permissions" in
  ???s*|???S*)
    fail "uade123 has a setuid bit (mode $uade_mode)"
    ;;
  *)
    pass "uade123 is not setuid (mode ${uade_mode:-unknown})"
    ;;
esac

# Conversion storage is writable; application and system paths are not.
for writable_dir in /tmp/modules /tmp/converted /tmp/cache; do
  mkdir -p "$writable_dir"
  marker="$writable_dir/.runtime-hardening-check"
  if touch "$marker" 2>/dev/null; then
    rm -f "$marker"
    pass "$writable_dir is writable for managed artifacts"
  else
    fail "$writable_dir is not writable for managed artifacts"
  fi
done

for protected_dir in /app /usr/local/bin; do
  marker="$protected_dir/.runtime-hardening-check"
  if touch "$marker" 2>/dev/null; then
    rm -f "$marker"
    fail "$protected_dir is writable by the runtime user"
  else
    pass "$protected_dir is protected from runtime writes"
  fi
done

# Module smoke tests run with no-new-privileges, so the inherited SUID bit
# cannot elevate UADE. This catches format-specific conversion regressions.
if command -v setpriv >/dev/null 2>&1 && [ -d /fixtures/modules ]; then
  for module in space_debris.mod stormlord.ahx mdat.turrican_2_level_0-intro; do
    module_path="/fixtures/modules/$module"
    output_path="/tmp/runtime-hardening-${module}.wav"
    if [ ! -f "$module_path" ]; then
      fail "fixture is missing: $module"
      continue
    fi
    if setpriv --no-new-privs /usr/local/bin/uade123 -t 1 -f "$output_path" "$module_path" \
      >/dev/null 2>&1; then
      pass "${module} converts without privilege elevation"
      rm -f "$output_path"
    else
      fail "${module} requires privilege elevation or does not convert"
    fi
  done
else
  fail "setpriv and module fixtures are required for non-SUID conversion checks"
fi

if [ "$failures" -ne 0 ]; then
  echo "Runtime hardening checks failed: $failures" >&2
  exit 1
fi

echo "Runtime hardening checks passed"
