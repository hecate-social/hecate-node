# Apprentice Responses

*Write here when you need Hecate's attention.*

---

Types: `COMPLETE`, `QUESTION`, `BLOCKED`, `DECISION`, `UPDATE`

---

## Messages

*(Write below this line)*

---

## 2026-02-03 COMPLETE: Install Script Hardened (No jq Dependency)

### Summary

The `install.sh` script has been hardened to work on systems without `jq`:

1. **Removed ALL jq usages**
   - All JSON parsing now uses `grep -o` and `sed`
   - Works on minimal systems (Alpine, base Ubuntu, etc.)

2. **Auto-PATH configuration**
   - Detects user's shell profile (`.zshrc` > `.bashrc` > `.profile`)
   - Adds PATH export if not present
   - Exports for current session immediately

3. **Bash strict mode fix**
   - `${ZSH_VERSION:-}` instead of `$ZSH_VERSION` for `set -u` compatibility

### Test Results (beam00.lab)

```
[OK] Identity created: mri:agent:io.macula/anonymous/hecate-635a

  Confirmation code:  949477
  Open this URL to confirm:
  https://macula.io/pair/019c231e-faea-7c45-a46c-e9295ff5bf84

[OK] Paired successfully!
```

**Full end-to-end flow works without jq installed.**

### Related Work (macula-realm)

Fixed two bugs in `macula-io/macula-realm` that were blocking the pairing flow:

**1. LiveView form input bug** (`apps/macula_realm_web/lib/macula_realm_web/live/pair_device_live.ex`)
- Was using `phx-keyup` with `phx-value-code={@code_input}` (sends stale value from assigns)
- Fixed to use `phx-change` on form with `name="code"` input (sends actual input value)

**2. Auth redirect bug** (`apps/macula_realm_web/lib/macula_realm_web/plugs/auth.ex`)
- `require_authenticated_user` was redirecting to `/` instead of `/sign-in`
- Fixed to redirect to `/sign-in` with `return_to` URL stored in session
- `auth_controller.ex` updated to check session for `return_to` after OAuth callback

**Both deployed to macula.io and verified working.**

### Commits

**hecate-node:**
- `fix: Remove jq dependency, auto-configure PATH`
- `fix: Handle unset ZSH_VERSION in bash strict mode`

**macula-realm:**
- `fix: Use phx-change on form for pairing code input`
- `fix: Redirect unauthenticated users to /sign-in with return_to`

---

*Ready for next tasks.* 🗝️

---

## 2026-02-03 COMPLETE: Install Script Review & SKILLS.md Audit

### Task Reference
- 🟡 MEDIUM: Review Install Script
- 🟢 LOW: SKILLS.md Review

---

### Install Script Review (`install.sh`)

**Overall Assessment: Script is solid.**

The install.sh is well-written with:
- `set -euo pipefail` strict mode
- Graceful error handling throughout
- Good hardware detection (RAM, CPU, GPU, AVX2, storage)
- Clear sudo explanations before elevation
- Flexible role selection (workstation, services, ai, or combinations)
- Pairing timeout (10 minutes, line 1168)

**Cross-Platform Support:**

| Platform | Status |
|----------|--------|
| Linux x86_64 | ✅ |
| Linux arm64 | ✅ |
| macOS arm64 (Apple Silicon) | ✅ |
| macOS x86_64 (Intel) | ✅ |

**Not Supported (by design):**
- ARM32 (armv7l) - `detect_arch()` line 104 calls `fatal`
- FreeBSD - `detect_os()` line 96 calls `fatal`

These fail fast with clear error messages, which is correct behavior.

**No issues found.** Script handles edge cases well.

---

### Uninstall Script Review (`uninstall.sh`)

**Gap Found: PATH entries not cleaned up**

The installer adds PATH to shell profiles (lines 1229-1234):
```bash
echo "# Hecate CLI" >> "$shell_profile"
echo "$path_line" >> "$shell_profile"
```

The uninstaller does NOT remove these lines. Confirmed via grep - no matches for PATH, bashrc, zshrc, or profile in uninstall.sh.

**Recommendation:** Add to uninstall.sh:
```bash
section "Cleaning Shell Profiles"
for profile in ~/.bashrc ~/.zshrc ~/.profile; do
    if [ -f "$profile" ] && grep -q "Hecate CLI" "$profile"; then
        sed -i '/# Hecate CLI/d' "$profile"
        sed -i '/\.local\/bin/d' "$profile"
        ok "Cleaned $profile"
    fi
done
```

---

### SKILLS.md Review

**Missing Documentation:**

1. **LLM endpoints** - The CLI wrapper (lines 990-1027) has LLM commands but SKILLS.md doesn't document the REST API:
   - `GET /api/llm/models`
   - `POST /api/llm/chat`
   - `GET /api/llm/health`

2. **Pairing endpoints** - CLI has `hecate pair` but REST API not documented:
   - `POST /api/pairing/start`
   - `GET /api/pairing/status`

3. **Identity init** - CLI has `hecate init` but REST API not documented:
   - `POST /identity/init`

**Documented features are correct** - Capabilities, RPC, PubSub, Social, UCAN all look good.

---

### Summary

| Finding | Severity | Action |
|---------|----------|--------|
| Install script | ✅ Good | None needed |
| Uninstall PATH cleanup | 🟡 Medium | Add shell profile cleanup |
| SKILLS.md LLM docs | 🟢 Low | Add LLM section |
| SKILLS.md pairing docs | 🟢 Low | Add pairing section |

*Review complete.* 🗝️
