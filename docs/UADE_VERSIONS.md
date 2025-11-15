# UADE Base Image Versions Changelog

This file tracks all published versions of the `uade-cli` base Docker image and their deployment status.

## Current Stable Version

**`3.05-base.2`** (lha and zip extract support)

---

## Version History

### 3.05-base.1 (2025-11-11) [INITIAL RELEASE]

- **Image:** `ghcr.io/rib1/uade-cli:3.05-base.1`
- **UADE Binary Version:** 3.05 (stable)
- **Status:** Stable version (pinned in Dockerfile.web)
- **Base Image:** `debian:stable-slim`
- **Build Duration:** ~8 minutes

**Changes:**

- Initial versioned release of UADE CLI base image
- Implements semantic versioning: UADE_VERSION-base.BUILD_NUMBER
- Enables controlled updates and prevents breaking changes from upstream

**Features:**

- Core UADE command-line tools (uade123, uade-convert)
- Support for MOD, AHX, TFMX, S3M, XM, IT, and other formats
- Non-root user security
- SUID permissions for audio device access
- Helper script: `uade-convert` for TFMX dual-file conversion

**Testing:**

- ✅ Health check: `uade123 --version` works
- ✅ Conversion test: UADE available and functional
- ✅ Web player integration: Dockerfile.web builds and runs successfully
- ✅ API endpoints: Health, examples, and core functionality verified

**Deployment Status:**

- Currently used by: Dockerfile.web
- Available as: `ghcr.io/rib1/uade-cli:3.05-base.1`, `ghcr.io/rib1/uade-cli:3.05-base`, `ghcr.io/rib1/uade-cli:latest`
- Verified binary: `uade123 3.05`

---

### 3.05-base.2 (2025-11-15) [LHA/UNZIP SUPPORT]

- **Image:** `ghcr.io/rib1/uade-cli:3.05-base.2`
- **UADE Binary Version:** 3.05 (stable)
- **Status:** Stable version
- **Base Image:** `debian:stable-slim`
- **Build Duration:** ~8 minutes

**Changes:**

- Added `lhasa` and `unzip` to base image for LHA and ZIP archive extraction
- Updated documentation with tested LHA and ZIP extraction examples
- Version bump to v3.05-base.2

**Features:**

- All features from 3.05-base.1
- Extract and convert Amiga modules directly from LHA and ZIP archives in one command

**Testing:**

- ✅ LHA extraction and conversion tested (Project-X.lha)
- ✅ ZIP extraction and conversion tested (chip_shop.zip)

**Deployment Status:**

- Available as: `ghcr.io/rib1/uade-cli:3.05-base.2`, `ghcr.io/rib1/uade-cli:3.05-base`, `ghcr.io/rib1/uade-cli:latest`
- Verified binary: `uade123 3.05`

---

## Planned Updates

### Next: UADE 3.06 Base Image (Pending Upstream Release)

- **Status:** Awaiting UADE upstream release
- **Expected:** Q1 2025 (check [UADE Releases](https://gitlab.com/uade-music-player/uade/-/releases))

**Process for next version:**

1. Check upstream releases
2. Build new base image: `3.06-base.1`
3. Run full E2E test suite
4. Update Dockerfile.web pin to `uade-cli:3.06-base.1`
5. Commit and tag release

---

## Version Pinning in Dockerfile.web

| Dockerfile.web Version | UADE CLI Version | Release Date | Status |
|---|---|---|---|
| v1.0 | 3.05-base.1 | 2025-11-11 | Current stable version |

---

## Building New Versions

### For Maintainers: Quick Reference

**Create a new build number (same UADE version):**

```bash
# Example: 3.05-base.1 → 3.05-base.2 (security patch)
docker build -f Dockerfile -t ghcr.io/rib1/uade-cli:3.05-base.2 .
docker tag ghcr.io/rib1/uade-cli:3.05-base.2 ghcr.io/rib1/uade-cli:3.05-base
docker tag ghcr.io/rib1/uade-cli:3.05-base.2 ghcr.io/rib1/uade-cli:latest
docker push ghcr.io/rib1/uade-cli:3.05-base.2
```

**Create a new UADE version (reset build to 1):**

```bash
# Example: 3.05-base.1 → 3.06-base.1
# 1. Update Dockerfile to clone --branch uade-3.06
# 2. Build:
docker build -f Dockerfile -t gcr.io/<GCP_PROJECT_ID>/uade-cli:3.06-base.1 .
# 3. Test (full E2E suite)
# 4. Push:
docker push gcr.io/<GCP_PROJECT_ID>/uade-cli:3.06-base.1
docker tag gcr.io/<GCP_PROJECT_ID>/uade-cli:3.06-base.1 gcr.io/<GCP_PROJECT_ID>/uade-cli:latest
docker push gcr.io/<GCP_PROJECT_ID>/uade-cli:latest
# 5. Update docs/UADE_VERSIONS.md
# 6. Update Dockerfile.web (after E2E passes)
```

---

## Dependencies

### System Libraries (debian:stable-slim)

- **libao4:** UADE audio output
- **libao-dev:** Build-time dependency (removed after build)
- **ca-certificates:** TLS verification for curl
- **curl:** Download modules from web
- **openssl:** TLS/SSL support

### Build Dependencies (removed after build)

- build-essential
- git
- autoconf / automake
- libtool
- pkg-config
- meson
- ninja-build

### Upstream Dependencies

- **bencodetools:** UADE prerequisite (auto-cloned and built)
- **libzakalwe:** UADE prerequisite (auto-cloned and built)

---

## Rollback Instructions

If a version has critical issues:

### Step 1: Revert Dockerfile.web to previous version

```dockerfile
# If 3.05-base.2 has issues:
# Change:
FROM gcr.io/<GCP_PROJECT_ID>/uade-cli:3.05-base.2

# To:
FROM gcr.io/<GCP_PROJECT_ID>/uade-cli:3.05-base.1
```

### Step 2: Rebuild and test

```bash
docker build -f Dockerfile.web -t uade-web:test .
# Run E2E tests
npm test
```

### Step 3: Commit and redeploy

```bash
git add Dockerfile.web
git commit -m "Rollback to uade-cli:3.05-base.1 (critical fix for issue #X)"
git push origin main
# Redeploy to Cloud Run, etc.
```

---

## Documentation Links

- **UADE Upstream Releases:** [GitLab Releases](https://gitlab.com/uade-music-player/uade/-/releases)
- **UADE Documentation:** [GitHub](https://github.com/libsidplay/uade)
- **Dockerfile Versioning Schema:** [DOCKER_VERSIONING.md](./DOCKER_VERSIONING.md)
- **Base Image Issues:** [GitHub Issues](https://github.com/rib1/uade-docker/issues)
