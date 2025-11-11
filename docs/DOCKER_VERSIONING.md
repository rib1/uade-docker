# Docker Base Image Versioning Schema

## Overview

This document defines a versioning strategy for the UADE CLI Docker base image (`Dockerfile`) to maintain stability, enable controlled updates, and allow predictable rolling out of UADE upstream changes to dependent services (e.g., `Dockerfile.web`).

**Goal:** Decouple UADE upstream versions from application versions, enabling:
- ✅ Stable base image that's tested and verified
- ✅ Controlled updates to `Dockerfile.web` with explicit pinning
- ✅ Regression detection via comprehensive E2E tests
- ✅ Quick rollback to stable versions if breaking changes occur
- ✅ Upstream UADE changes don't automatically cascade to production

**Current Version:** UADE 3.05 (binary version inside container)

---

## Versioning Scheme

### Format

```
uade-cli:<UADE_VERSION>-<VARIANT>.<BUILD_NUMBER>
```

**Examples:**
- `uade-cli:3.05-base.1` — UADE 3.05, base variant, build 1
- `uade-cli:3.05-base.5` — UADE 3.05, base variant, build 5 (patch for this UADE version)
- `uade-cli:3.06-base.1` — New UADE version, base variant, build 1

### Components

#### UADE_VERSION
- Extracted from upstream UADE project releases (e.g., tags like `uade-3.05`)
- Format: `<MAJOR>.<MINOR>` (e.g., `3.05`)
- Source: Latest stable UADE release from [UADE GitLab](https://gitlab.com/uade-music-player/uade/-/releases)

#### VARIANT
- Indicates the base configuration/feature set
- **`base`** — Default variant: minimal UADE CLI with core dependencies
- Future variants: `full` (with extra tools), `minimal` (stripped down), etc.

#### BUILD_NUMBER
- Increments when rebuilding the same UADE version without upstream changes
- Use for: Dependency updates, bug fixes, security patches
- Resets to 1 when UADE_VERSION changes
- Examples:
  - `3.05-base.1` → rebuild with security patch → `3.05-base.2`
  - `3.05-base.5` → bump to UADE 3.06 → `3.06-base.1`

---

## Image Registry Structure

### Image Naming

```
gcr.io/<GCP_PROJECT_ID>/uade-cli:<tag>
```

### Tag Strategy

| Tag Pattern | Purpose | Lifecycle |
|---|---|---|
| `3.05-base.5` | Release/production | Stable, pinned in Dockerfile.web |
| `3.05-base.latest` | Latest patch for this UADE version | Updates when new build published |
| `latest` | Global latest | Always points to newest UADE version |
| `3.05-base` | Latest build for UADE 3.05, any variant | Updates when 3.05 rebuild occurs |

### Initial Release Tag Timeline

```
2025-11-11: UADE 3.05 first release
  → 3.05-base.1       (initial production, pinned in Dockerfile.web)
  → 3.05-base
  → 3.05-base.latest
  → latest            (global latest)

Future (when UADE 3.06 released):
  → 3.06-base.1       (new version, build 1)
  → 3.06-base
  → 3.06-base.latest
  → latest

Future (if security patch needed for 3.05):
  → 3.05-base.2       (rebuild same UADE, fix patch)
  → Updates 3.05-base, 3.05-base.latest tags
  → Optionally update Dockerfile.web if critical
```

---

## Version Pinning in Downstream Images

### Dockerfile.web Pinning

Once the base image is tagged and tested, pin it explicitly:

```dockerfile
# Old (unpinned, automatically picks latest)
FROM uade-cli:latest

# New (pinned, explicit version with UADE version + build number)
FROM uade-cli:3.05-base.1
```

### When to Update Dockerfile.web Pins

1. **Patch Update** (same UADE, new build number)
   - E.g., `3.05-base.1` → `3.05-base.2`
   - When: Security patches, dependency updates
   - Testing: Quick regression test (health check, basic conversion)

2. **Minor Update** (new UADE version)
   - E.g., `3.05-base.1` → `3.06-base.1`
   - When: UADE upstream releases new version
   - Testing: Full E2E test suite (API, UI, integration, format detection)

3. **Never Auto-Update**
   - Always require explicit `FROM` change + validation tests
   - Prevents silent breakage from upstream

---

## Building and Publishing Base Images

### Local Build

```powershell
# Build specific UADE version
docker build -f Dockerfile -t uade-cli:3.05-base.1 .

# Tag with variant shortcuts
docker tag uade-cli:3.05-base.1 uade-cli:3.05-base
docker tag uade-cli:3.05-base.1 uade-cli:3.05-base.latest
docker tag uade-cli:3.05-base.1 uade-cli:latest
```

### Push to Registry

```powershell
# Push all tags
docker push uade-cli:3.05-base.1
docker push uade-cli:3.05-base.latest
docker push uade-cli:3.05-base
docker push uade-cli:latest
```

### Dockerfile Changes (Version Bump)

When UADE upstream releases a new version, update `Dockerfile`:

```dockerfile
# Example: Update from 2.13 to 2.14
# Before:
RUN git clone --depth 1 https://gitlab.com/uade-music-player/uade.git

# After (optional: pin to tag):
RUN git clone --depth 1 --branch uade-2.14 https://gitlab.com/uade-music-player/uade.git
```

**Best Practice:** Always pin to a specific tag if possible:

```dockerfile
# Clone with specific tag (more predictable, prevents breaking changes)
RUN git clone --depth 1 --branch uade-2.14 \
    https://gitlab.com/uade-music-player/uade.git
```

---

## Changelog Management

### UADE_VERSIONS.md Template

Track all published versions in `deployment/UADE_VERSIONS.md`:

```markdown
# UADE Base Image Versions

## 3.05-base.1 (2025-11-11) [INITIAL RELEASE]
- **Image:** gcr.io/<GCP_PROJECT_ID>/uade-cli:3.05-base.1
- **UADE Version:** 3.05 (stable)
- **Base Image:** debian:stable-slim
- **Status:** Production (Dockerfile.web pinned to this version)
- **Changes:**
  - Initial versioned release with semantic versioning schema
  - Enables controlled updates and prevents breaking changes
```

---

## Version Bumping Checklist

### For Patch Updates (new build number, same UADE version)

Example: `2.13-base.1` → `2.13-base.2`

- [ ] Identify need (security patch, bug fix, dependency update)
- [ ] Update `Dockerfile` if needed (e.g., apt-get packages)
- [ ] Build locally: `docker build -f Dockerfile -t uade-cli:2.13-base.2 .`
- [ ] Run health check: `docker run --rm uade-cli:2.13-base.2 --version`
- [ ] Push to registry: `docker push uade-cli:2.13-base.2`
- [ ] Update `deployment/UADE_VERSIONS.md` with changes
- [ ] Run quick E2E regression test (health, basic conversion)
- [ ] Optionally update `Dockerfile.web` if critical fix
- [ ] Commit and push changelog

### For Minor Updates (new UADE version, reset build number to 1)

Example: `2.13-base.1` → `2.14-base.1`

- [ ] Check UADE upstream releases: [UADE GitLab](https://gitlab.com/uade-music-player/uade/-/releases)
- [ ] Update `Dockerfile` to pin new UADE version tag
- [ ] Update `Dockerfile` dependencies if documented in UADE release notes
- [ ] Build locally: `docker build -f Dockerfile -t uade-cli:2.14-base.1 .`
- [ ] Run health check: `docker run --rm uade-cli:2.14-base.1 --version`
- [ ] Push to registry: `docker push uade-cli:2.14-base.1`
- [ ] Update `deployment/UADE_VERSIONS.md` with upstream changes
- [ ] **Run full E2E test suite** against new base image
- [ ] Create GitHub Discussion or PR for feedback
- [ ] Once tests pass, update `Dockerfile.web` to new version
- [ ] Commit, tag release, and push to main

---

## Rollback Strategy

If a version has issues:

### Quick Rollback (revert Dockerfile.web pin)

```dockerfile
# If 2.14-base.1 has issues, revert to previous stable:
FROM uade-cli:2.13-base.1
```

### Rebuild Previous Version

```bash
# If 2.13-base.1 needs a rebuild:
git checkout <commit-hash-for-2.13-base.1>
docker build -f Dockerfile -t uade-cli:2.13-base.1 .
docker push uade-cli:2.13-base.1
```

---

## Key Benefits

| Benefit | How It's Achieved |
|---------|-------------------|
| **Stability** | Explicit versioning with UADE version + build number |
| **Predictability** | Pinned versions in Dockerfile.web, not auto-updated |
| **Testability** | Each version has defined E2E test requirements before production |
| **Rollback** | Quick revert to previous stable version in Dockerfile.web |
| **Isolation** | UADE upstream breaking changes don't auto-cascade to web player |
| **Traceability** | Clear changelog linking versions to release notes |
| **Automation** | CI/CD builds, tests, and publishes new versions on-demand |

---

## Maintenance Notes

- **Review UADE Releases:** Check [UADE GitLab](https://gitlab.com/uade-music-player/uade/-/releases) monthly
- **Security Updates:** Monitor Debian security advisories and rebuild base image with updated packages
- **Document Changes:** Always update `deployment/UADE_VERSIONS.md` when publishing a new version
- **Test Before Deploy:** Never skip the full E2E test suite before pinning a new version in `Dockerfile.web`
