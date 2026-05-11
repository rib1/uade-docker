#!/bin/bash

# UADE Docker - Code Quality Automation Script
# This script runs all code quality checks, including linting, dead-code auditing,
# formatting, and workflow/config validation across the repo.
# No local dependencies needed - all tools run in Docker containers
#
# Usage:
#   ./test/check-code-quality.sh              # Run all checks
#   ./test/check-code-quality.sh --fix        # Run with fixes enabled
#   ./test/check-code-quality.sh --help       # Show usage and available checks
#   ./test/check-code-quality.sh --eslint     # ESLint only
#   ./test/check-code-quality.sh --black      # Black only
#   ./test/check-code-quality.sh --ruff       # Ruff only
#   ./test/check-code-quality.sh --actionlint # ActionLint only
#   ./test/check-code-quality.sh --hadolint   # Hadolint only
#   ./test/check-code-quality.sh --compose    # Docker Compose only
#   ./test/check-code-quality.sh --shellcheck # ShellCheck only
#   ./test/check-code-quality.sh --yamllint   # Yamllint only
#   ./test/check-code-quality.sh --stylelint  # Stylelint only
#   ./test/check-code-quality.sh --htmlhint   # HTMLHint only
#   ./test/check-code-quality.sh --knip       # knip dead-code audit only
#   ./test/check-code-quality.sh --knip-production # knip production dead-code audit only
#   ./test/check-code-quality.sh --playwright-sync # Playwright tooling version sync only
#   ./test/check-code-quality.sh --node-quality-sync # Node quality helper image sync only
#   ./test/check-code-quality.sh --python-sync # Python tooling version sync only
#   ./test/check-code-quality.sh --mypy       # mypy only
#   ./test/check-code-quality.sh --vulture    # Vulture dead-code audit only
#   ./test/check-code-quality.sh --purgecss      # PurgeCSS unused CSS check only
#   ./test/check-code-quality.sh --instructions  # Instruction files only
#   ./test/check-code-quality.sh --documentation # Documentation files only

# Don't use set -e because we want to run all checks even if one fails
# We handle errors manually and exit at the end based on FAILED_CHECKS count

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Allow PROJECT_ROOT to be overridden (useful for Docker containers)
if [ -z "$PROJECT_ROOT" ]; then
    PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
fi

# Git Bash (MSYS2) rewrites POSIX paths in docker args by default.
# Disable conversion so /workspace paths are passed to Docker unchanged.
if [ -n "${MSYSTEM:-}" ] || uname -s | grep -Eq 'MINGW|MSYS'; then
    export MSYS_NO_PATHCONV="${MSYS_NO_PATHCONV:-1}"
    export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:-*}"
fi

# Tool versions from manifests (managed by Dependabot)
NPM_QUALITY_MANIFEST="${PROJECT_ROOT}/test/package.json"
PY_QUALITY_MANIFEST="${PROJECT_ROOT}/test/requirements-quality.txt"
TOOLING_IMAGE_MANIFEST="${PROJECT_ROOT}/test/docker-compose.tooling.yml"

read_npm_tool_version() {
    local tool="$1"
    local version
    version=$(sed -nE "s/^[[:space:]]*\"${tool}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\\1/p" "$NPM_QUALITY_MANIFEST" | head -n1)
    if [ -z "$version" ]; then
        echo "ERROR: Could not read ${tool} version from ${NPM_QUALITY_MANIFEST}" >&2
        exit 1
    fi
    echo "$version"
}

read_pip_tool_version() {
    local tool="$1"
    local version
    version=$(sed -nE "s/^${tool}==([^[:space:]]+).*$/\\1/p" "$PY_QUALITY_MANIFEST" | head -n1)
    if [ -z "$version" ]; then
        echo "ERROR: Could not read ${tool} version from ${PY_QUALITY_MANIFEST}" >&2
        exit 1
    fi
    echo "$version"
}

read_tool_image() {
    local service="$1"
    local image
    image=$(awk -v svc="$service" '
        $0 ~ /^services:[[:space:]]*$/ {in_services=1; next}
        in_services && $0 ~ ("^  " svc ":[[:space:]]*$") {in_target=1; next}
        in_target && $0 ~ /^    image:[[:space:]]*/ {
            line=$0
            sub(/^    image:[[:space:]]*/, "", line)
            gsub(/"/, "", line)
            gsub(/[[:space:]]+$/, "", line)
            print line
            exit
        }
        in_target && $0 ~ /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {in_target=0}
    ' "$TOOLING_IMAGE_MANIFEST")
    if [ -z "$image" ]; then
        echo "ERROR: Could not read image for service '${service}' from ${TOOLING_IMAGE_MANIFEST}" >&2
        exit 1
    fi
    echo "$image"
}

if [ ! -f "$NPM_QUALITY_MANIFEST" ]; then
    echo "ERROR: Missing quality manifest: ${NPM_QUALITY_MANIFEST}" >&2
    exit 1
fi
if [ ! -f "$PY_QUALITY_MANIFEST" ]; then
    echo "ERROR: Missing quality manifest: ${PY_QUALITY_MANIFEST}" >&2
    exit 1
fi
if [ ! -f "$TOOLING_IMAGE_MANIFEST" ]; then
    echo "ERROR: Missing tooling image manifest: ${TOOLING_IMAGE_MANIFEST}" >&2
    exit 1
fi

ESLINT_VERSION="$(read_npm_tool_version eslint)"
STYLELINT_VERSION="$(read_npm_tool_version stylelint)"
HTMLHINT_VERSION="$(read_npm_tool_version htmlhint)"
KNIP_VERSION="$(read_npm_tool_version knip)"
PURGECSS_VERSION="$(read_npm_tool_version purgecss)"
BLACK_VERSION="$(read_pip_tool_version black)"
RUFF_VERSION="$(read_pip_tool_version ruff)"
MYPY_VERSION="$(read_pip_tool_version mypy)"
VULTURE_VERSION="$(read_pip_tool_version vulture)"
YAMLLINT_VERSION="$(read_pip_tool_version yamllint)"
HADOLINT_IMAGE="$(read_tool_image hadolint)"
ACTIONLINT_IMAGE="$(read_tool_image actionlint)"
SHELLCHECK_IMAGE="$(read_tool_image shellcheck)"
PYTHON_QUALITY_TARGETS=(web test/report_endpoint_coverage.py test/zap_seed_targets.py)

# Keep these pin reads explicit even when some fallback installs come from
# requirements-quality.txt as a whole rather than per-tool pip commands.
: "${MYPY_VERSION}" "${VULTURE_VERSION}"

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

print_usage() {
    cat <<'EOF'
Usage: ./test/check-code-quality.sh [--fix] [--help] [single-check option]

Run all checks:
  ./test/check-code-quality.sh

Run with auto-fixes:
  ./test/check-code-quality.sh --fix

Show help:
  ./test/check-code-quality.sh --help

Frontend Checks:
CSS Checks:
  --purgecss
  --stylelint

JavaScript Checks:
  --eslint
  --knip
  --knip-production
  --playwright-sync
  --node-quality-sync

HTML Checks:
  --htmlhint

Backend Python Checks:
  --python-sync
  --black
  --ruff
  --mypy
  --vulture

Infrastructure Checks:
  --hadolint
  --compose
  --actionlint
  --shellcheck
  --yamllint

Markdown And Documentation Checks:
  --instructions
  --documentation
EOF
}

enable_only_check() {
    local selected_check="$1"
    RUN_ESLINT=false
    RUN_BLACK=false
    RUN_RUFF=false
    RUN_ACTIONLINT=false
    RUN_HADOLINT=false
    RUN_COMPOSE=false
    RUN_SHELLCHECK=false
    RUN_YAMLLINT=false
    RUN_STYLELINT=false
    RUN_HTMLHINT=false
    RUN_KNIP=false
    RUN_KNIP_PRODUCTION=false
    RUN_PLAYWRIGHT_SYNC=false
    RUN_NODE_QUALITY_SYNC=false
    RUN_PYTHON_SYNC=false
    RUN_MYPY=false
    RUN_VULTURE=false
    RUN_INSTRUCTIONS=false
    RUN_DOCUMENTATION=false
    RUN_PURGECSS=false

    case "$selected_check" in
        eslint) RUN_ESLINT=true ;;
        black) RUN_BLACK=true ;;
        ruff) RUN_RUFF=true ;;
        actionlint) RUN_ACTIONLINT=true ;;
        hadolint) RUN_HADOLINT=true ;;
        compose) RUN_COMPOSE=true ;;
        shellcheck) RUN_SHELLCHECK=true ;;
        yamllint) RUN_YAMLLINT=true ;;
        stylelint) RUN_STYLELINT=true ;;
        htmlhint) RUN_HTMLHINT=true ;;
        knip) RUN_KNIP=true ;;
        knip-production) RUN_KNIP_PRODUCTION=true ;;
        playwright-sync) RUN_PLAYWRIGHT_SYNC=true ;;
        node-quality-sync) RUN_NODE_QUALITY_SYNC=true ;;
        python-sync) RUN_PYTHON_SYNC=true ;;
        mypy) RUN_MYPY=true ;;
        vulture) RUN_VULTURE=true ;;
        instructions) RUN_INSTRUCTIONS=true ;;
        documentation) RUN_DOCUMENTATION=true ;;
        purgecss) RUN_PURGECSS=true ;;
        # purifycss removed
    esac
}

# Parse arguments
FIX_MODE=false
RUN_ESLINT=true
RUN_BLACK=true
RUN_RUFF=true
RUN_ACTIONLINT=true
RUN_HADOLINT=true
RUN_COMPOSE=true
RUN_SHELLCHECK=true
RUN_YAMLLINT=true
RUN_STYLELINT=true
RUN_HTMLHINT=true
RUN_KNIP=true
RUN_KNIP_PRODUCTION=true
RUN_PLAYWRIGHT_SYNC=true
RUN_NODE_QUALITY_SYNC=true
RUN_PURGECSS=true
RUN_PYTHON_SYNC=true
RUN_MYPY=true
RUN_VULTURE=true
RUN_INSTRUCTIONS=true
RUN_DOCUMENTATION=true

for arg in "$@"; do
    case $arg in
        --help|-h)
            print_usage
            exit 0
            ;;
        --fix)
            FIX_MODE=true
            shift
            ;;
        --eslint)
            enable_only_check eslint
            shift
            ;;
        --black)
            enable_only_check black
            shift
            ;;
        --ruff)
            enable_only_check ruff
            shift
            ;;
        --actionlint)
            enable_only_check actionlint
            shift
            ;;
        --hadolint)
            enable_only_check hadolint
            shift
            ;;
        --compose)
            enable_only_check compose
            shift
            ;;
        --shellcheck)
            enable_only_check shellcheck
            shift
            ;;
        --yamllint)
            enable_only_check yamllint
            shift
            ;;
        --stylelint)
            enable_only_check stylelint
            shift
            ;;
        --htmlhint)
            enable_only_check htmlhint
            shift
            ;;
        --knip)
            enable_only_check knip
            shift
            ;;
        --knip-production)
            enable_only_check knip-production
            shift
            ;;
        --playwright-sync)
            enable_only_check playwright-sync
            shift
            ;;
        --node-quality-sync)
            enable_only_check node-quality-sync
            shift
            ;;
        --python-sync)
            enable_only_check python-sync
            shift
            ;;
        --mypy)
            enable_only_check mypy
            shift
            ;;
        --vulture)
            enable_only_check vulture
            shift
            ;;
        --instructions)
            enable_only_check instructions
            shift
            ;;
        --documentation)
            enable_only_check documentation
            shift
            ;;
        --purgecss)
            enable_only_check purgecss
            shift
            ;;
        # --purifycss removed
        *)
            echo "Unknown option: $arg"
            print_usage
            exit 1
            ;;
    esac
done
# Helper function to print headers
print_header() {
    echo -e "\n${BLUE}================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================================${NC}\n"
}

# Helper function to print results
print_result() {
    local test_name=$1
    local exit_code=$2
    local output=$3

    ((TOTAL_CHECKS++))

    if [ "$exit_code" -eq 0 ]; then
        echo -e "${GREEN}✓ PASSED${NC}: $test_name"
        ((PASSED_CHECKS++))
    else
        echo -e "${RED}✗ FAILED${NC}: $test_name"
        if [ -n "$output" ]; then
            echo -e "${RED}$output${NC}"
        fi
        ((FAILED_CHECKS++))
    fi
}

print_group_header() {
    echo
    echo "--- $1 ---"
    echo
}

print_subgroup_header() {
    echo
    echo "$1:"
    echo
}

# PurgeCSS Check
if [ "$RUN_PURGECSS" = true ]; then
    print_group_header "Frontend Checks"
    print_subgroup_header "CSS Checks"
    print_header "PurgeCSS - Unused CSS Removal Check"

    echo "Running PurgeCSS on web/static/style.css against all HTML and JS in web/..."

    PURGECSS_FIX_ARG=""
    if [ "$FIX_MODE" = true ]; then
        PURGECSS_FIX_ARG="--fix"
    fi

    if command -v node >/dev/null 2>&1 && command -v purgecss >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}/test" && node check-purgecss.mjs $PURGECSS_FIX_ARG 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
            -v "${PROJECT_ROOT}:/workspace" \
            --workdir /workspace/test \
            node:26-alpine sh -lc "npm install -g purgecss@${PURGECSS_VERSION} >/dev/null && node check-purgecss.mjs ${PURGECSS_FIX_ARG}" 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "PurgeCSS" 0
    else
        print_result "PurgeCSS" $EXIT_CODE "$OUTPUT"
    fi
fi

# Stylelint
if [ "$RUN_STYLELINT" = true ]; then
    print_header "Stylelint - CSS Linting"

    echo "Running Stylelint on /web/static/*.css..."

    STYLELINT_ARGS=(--config .stylelintrc.json "web/static/*.css")
    if [ "$FIX_MODE" = true ]; then
        STYLELINT_ARGS=(--config .stylelintrc.json --fix "web/static/*.css")
    fi

    if command -v stylelint >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}" && stylelint "${STYLELINT_ARGS[@]}" 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace \
               node:26-alpine sh -lc "npm install -g stylelint@${STYLELINT_VERSION} >/dev/null && stylelint ${STYLELINT_ARGS[*]}" 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "Stylelint" 0
    else
        print_result "Stylelint" $EXIT_CODE "$OUTPUT"
    fi
fi

# ESLint Check
if [ "$RUN_ESLINT" = true ]; then
    if [ "$RUN_PURGECSS" != true ] && [ "$RUN_STYLELINT" != true ]; then
        print_group_header "Frontend Checks"
    fi
    print_subgroup_header "JavaScript Checks"
    print_header "ESLint - JavaScript/CSS Linting"

    echo "Running ESLint on /web/static and /test/*.{js,mjs}..."

    FIX_MODE_ARG=""
    if [ "$FIX_MODE" = true ]; then
        FIX_MODE_ARG="--fix"
    fi

    run_eslint_dir() {
        local workdir="$1"
        local target="$2"
        local output
        local exit_code

        if command -v eslint >/dev/null 2>&1; then
            if [ -n "$FIX_MODE_ARG" ]; then
                output=$(cd "$workdir" && eslint "$target" "$FIX_MODE_ARG" 2>&1)
            else
                output=$(cd "$workdir" && eslint "$target" 2>&1)
            fi
            exit_code=$?
        else
            output=$(docker run --rm \
                   -v "${PROJECT_ROOT}:/workspace" \
                   --workdir "$target" \
                   node:26-alpine sh -lc "npm install -g eslint@${ESLINT_VERSION} >/dev/null && eslint . $FIX_MODE_ARG" 2>&1)
            exit_code=$?
        fi

        printf '%s' "$output"
        return $exit_code
    }

    WEB_OUTPUT=$(run_eslint_dir "${PROJECT_ROOT}/web/static" "/workspace/web/static")
    WEB_EXIT_CODE=$?
    TEST_OUTPUT=$(run_eslint_dir "${PROJECT_ROOT}/test" "/workspace/test")
    TEST_EXIT_CODE=$?

    OUTPUT=""
    if [ $WEB_EXIT_CODE -ne 0 ]; then
        OUTPUT="${OUTPUT}${WEB_OUTPUT}"
    fi
    if [ $TEST_EXIT_CODE -ne 0 ]; then
        if [ -n "$OUTPUT" ]; then
            OUTPUT="${OUTPUT}\n"
        fi
        OUTPUT="${OUTPUT}${TEST_OUTPUT}"
    fi

    EXIT_CODE=$(( WEB_EXIT_CODE > TEST_EXIT_CODE ? WEB_EXIT_CODE : TEST_EXIT_CODE ))

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "ESLint" 0
    else
        print_result "ESLint" $EXIT_CODE "$OUTPUT"
    fi
fi

# knip
if [ "$RUN_KNIP" = true ]; then
    if [ "$RUN_PURGECSS" != true ] && [ "$RUN_STYLELINT" != true ] && [ "$RUN_ESLINT" != true ]; then
        print_group_header "Frontend Checks"
        print_subgroup_header "JavaScript Checks"
    fi
    print_header "knip - JavaScript Dead-Code Audit"

    echo "Running knip on /web/static and /test with repo-specific config..."

    if command -v knip >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}/test" && knip --config knip.config.js --no-progress --treat-config-hints-as-errors --include-entry-exports 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace/test \
               node:26-alpine sh -lc "npm install -g knip@${KNIP_VERSION} >/dev/null && knip --config knip.config.js --no-progress --treat-config-hints-as-errors --include-entry-exports" 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "knip" 0
    else
        print_result "knip" $EXIT_CODE "$OUTPUT"
    fi
fi

# knip production audit
if [ "$RUN_KNIP_PRODUCTION" = true ]; then
    if [ "$RUN_PURGECSS" != true ] && [ "$RUN_STYLELINT" != true ] && [ "$RUN_ESLINT" != true ] && [ "$RUN_KNIP" != true ]; then
        print_group_header "Frontend Checks"
        print_subgroup_header "JavaScript Checks"
    fi
    print_header "knip - JavaScript Production Dead-Code Audit"

    echo "Running knip production audit on runtime JavaScript entrypoints..."

    if command -v knip >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}/test" && knip --config knip.config.js --no-progress --treat-config-hints-as-errors --include-entry-exports --production 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace/test \
               node:26-alpine sh -lc "npm install -g knip@${KNIP_VERSION} >/dev/null && knip --config knip.config.js --no-progress --treat-config-hints-as-errors --include-entry-exports --production" 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "knip production" 0
    else
        print_result "knip production" $EXIT_CODE "$OUTPUT"
    fi
fi

# Playwright tooling sync check
if [ "$RUN_PLAYWRIGHT_SYNC" = true ]; then
    if [ "$RUN_PURGECSS" != true ] && [ "$RUN_STYLELINT" != true ] && [ "$RUN_ESLINT" != true ] && [ "$RUN_KNIP" != true ] && [ "$RUN_KNIP_PRODUCTION" != true ]; then
        print_group_header "Frontend Checks"
        print_subgroup_header "JavaScript Checks"
    fi
    print_header "Playwright Tooling Sync"

    echo "Checking Playwright package and image version alignment..."

    if command -v node >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}" && node test/check-playwright-version-sync.mjs 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace \
               node:26-alpine node test/check-playwright-version-sync.mjs 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "Playwright Sync" 0
    else
        print_result "Playwright Sync" $EXIT_CODE "$OUTPUT"
    fi
fi

# Node quality tooling sync check
if [ "$RUN_NODE_QUALITY_SYNC" = true ]; then
    if [ "$RUN_PURGECSS" != true ] && [ "$RUN_STYLELINT" != true ] && [ "$RUN_ESLINT" != true ] && [ "$RUN_KNIP" != true ] && [ "$RUN_KNIP_PRODUCTION" != true ] && [ "$RUN_PLAYWRIGHT_SYNC" != true ]; then
        print_group_header "Frontend Checks"
        print_subgroup_header "JavaScript Checks"
    fi
    print_header "Node Quality Tooling Sync"

    echo "Checking Node quality helper image version alignment..."

    if command -v node >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}" && node test/check-node-quality-version-sync.mjs 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace \
               node:26-alpine node test/check-node-quality-version-sync.mjs 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "Node Quality Sync" 0
    else
        print_result "Node Quality Sync" $EXIT_CODE "$OUTPUT"
    fi
fi

# HTMLHint
if [ "$RUN_HTMLHINT" = true ]; then
    if [ "$RUN_PURGECSS" != true ] && [ "$RUN_STYLELINT" != true ] && [ "$RUN_ESLINT" != true ] && [ "$RUN_KNIP" != true ] && [ "$RUN_KNIP_PRODUCTION" != true ] && [ "$RUN_PLAYWRIGHT_SYNC" != true ] && [ "$RUN_NODE_QUALITY_SYNC" != true ]; then
        print_group_header "Frontend Checks"
    fi
    print_subgroup_header "HTML Checks"
    print_header "HTMLHint - HTML Validation"

    echo "Running HTMLHint on /web/static/index.html..."

    if command -v htmlhint >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}" && htmlhint --config .htmlhintrc web/static/index.html 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace \
               node:26-alpine sh -lc "npm install -g htmlhint@${HTMLHINT_VERSION} >/dev/null && htmlhint --config .htmlhintrc web/static/index.html" 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "HTMLHint" 0
    else
        print_result "HTMLHint" $EXIT_CODE "$OUTPUT"
    fi
fi

# Python tooling sync check
if [ "$RUN_PYTHON_SYNC" = true ]; then
    print_group_header "Backend Python Checks"
    print_header "Python Tooling Sync"

    echo "Checking Python target and CodeQL/fallback image version alignment..."

    if command -v node >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}" && node test/check-python-version-sync.mjs 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace \
               node:26-alpine node test/check-python-version-sync.mjs 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "Python Sync" 0
    else
        print_result "Python Sync" $EXIT_CODE "$OUTPUT"
    fi
fi

# Black Check
if [ "$RUN_BLACK" = true ]; then
    if [ "$RUN_PYTHON_SYNC" != true ]; then
        print_group_header "Backend Python Checks"
    fi
    print_header "Black - Python Code Formatting"

    echo "Running Black on /web, /test/report_endpoint_coverage.py, and /test/zap_seed_targets.py..."

    FIX_MODE_ARG="--check"
    if [ "$FIX_MODE" = true ]; then
        FIX_MODE_ARG=""
    fi

    if command -v black >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}" && black "${PYTHON_QUALITY_TARGETS[@]}" --line-length 100 $FIX_MODE_ARG 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace \
               "pyfound/black:${BLACK_VERSION}" \
               black "${PYTHON_QUALITY_TARGETS[@]}" --line-length 100 $FIX_MODE_ARG 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "Black" 0
    else
        print_result "Black" $EXIT_CODE "$OUTPUT"
    fi
fi

# Ruff Check
if [ "$RUN_RUFF" = true ]; then
    print_header "Ruff - Python Linting and Formatting"

    echo "Running Ruff on /web, /test/report_endpoint_coverage.py, and /test/zap_seed_targets.py..."

    RUFF_CHECK_ARGS=()
    RUFF_FORMAT_ARGS=(--check)
    if [ "$FIX_MODE" = true ]; then
        RUFF_CHECK_ARGS+=(--fix)
        RUFF_FORMAT_ARGS=()
    fi

    if command -v ruff >/dev/null 2>&1; then
        OUTPUT_FORMAT=$(cd "${PROJECT_ROOT}" && ruff format "${PYTHON_QUALITY_TARGETS[@]}" "${RUFF_FORMAT_ARGS[@]}" 2>&1)
        EXIT_CODE_FORMAT=$?
        OUTPUT_CHECK=$(cd "${PROJECT_ROOT}" && ruff check "${PYTHON_QUALITY_TARGETS[@]}" "${RUFF_CHECK_ARGS[@]}" 2>&1)
        EXIT_CODE_CHECK=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace \
               "ghcr.io/astral-sh/ruff:${RUFF_VERSION}" \
               check "${PYTHON_QUALITY_TARGETS[@]}" "${RUFF_CHECK_ARGS[@]}" 2>&1)
        EXIT_CODE=$?
        OUTPUT_FORMAT=""
        EXIT_CODE_FORMAT=0
        OUTPUT_CHECK="$OUTPUT"
        EXIT_CODE_CHECK="$EXIT_CODE"
    fi

    if [ $EXIT_CODE_FORMAT -eq 0 ] && [ $EXIT_CODE_CHECK -eq 0 ]; then
        print_result "Ruff" 0
    else
        COMBINED_OUTPUT="${OUTPUT_FORMAT}\n${OUTPUT_CHECK}"
        FINAL_EXIT_CODE=$(( EXIT_CODE_FORMAT > EXIT_CODE_CHECK ? EXIT_CODE_FORMAT : EXIT_CODE_CHECK ))
        print_result "Ruff" "$FINAL_EXIT_CODE" "$COMBINED_OUTPUT"
    fi
fi

# mypy Check
if [ "$RUN_MYPY" = true ]; then
    print_header "mypy - Lightweight Python Type Checking"

    echo "Running mypy on web/server.py..."

    MYPY_ARGS=(--config-file pyproject.toml --no-error-summary)

    if command -v mypy >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}" && mypy "${MYPY_ARGS[@]}" 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace \
               python:3.13-slim sh -lc "pip install --no-cache-dir -r test/requirements-quality.txt >/dev/null && mypy ${MYPY_ARGS[*]}" 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "mypy" 0
    else
        print_result "mypy" $EXIT_CODE "$OUTPUT"
    fi
fi

# Vulture Check
if [ "$RUN_VULTURE" = true ]; then
    print_header "Vulture - Python Dead-Code Audit"

    echo "Running Vulture on Python quality targets using pyproject.toml..."

    if command -v vulture >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}" && vulture --config pyproject.toml 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace \
               python:3.13-slim sh -lc "pip install --no-cache-dir -r test/requirements-quality.txt >/dev/null && vulture --config pyproject.toml" 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "Vulture" 0
    else
        print_result "Vulture" $EXIT_CODE "$OUTPUT"
    fi
fi

# Hadolint Check
if [ "$RUN_HADOLINT" = true ]; then
    print_group_header "Infrastructure Checks"
    print_header "Hadolint - Dockerfile Linting"

    # Find all Dockerfiles
    DOCKERFILES=$(find "${PROJECT_ROOT}" -type f \( -name "Dockerfile" -o -name "Dockerfile.*" \) ! -path "*/node_modules/*" ! -path "*/.git/*" 2>/dev/null | sort)

    if [ -z "$DOCKERFILES" ]; then
        echo -e "${YELLOW}⚠ No Dockerfiles found${NC}"
    else
        DOCKERFILE_COUNT=$(echo "$DOCKERFILES" | wc -l)
        echo "Found $DOCKERFILE_COUNT Dockerfile(s). Validating..."

        HADOLINT_FAILED=false
        HADOLINT_OUTPUT=""
        while IFS= read -r dockerfile; do
            dockerfile_name=$(basename "$dockerfile")
            echo "  Checking: $dockerfile_name"

            if command -v hadolint >/dev/null 2>&1; then
                OUTPUT=$(hadolint "$dockerfile" 2>&1)
                EXIT_CODE=$?
            else
                OUTPUT=$(docker run --rm -i \
                    -v "${PROJECT_ROOT}/.hadolint.yaml:/.hadolint.yaml:ro" \
                    "${HADOLINT_IMAGE}" hadolint --config /.hadolint.yaml - < "$dockerfile" 2>&1)
                EXIT_CODE=$?
            fi

            if [ $EXIT_CODE -eq 0 ]; then
                echo -e "    ${GREEN}✓${NC} $dockerfile_name"
            else
                echo -e "    ${RED}✗${NC} $dockerfile_name"
                HADOLINT_FAILED=true
                HADOLINT_OUTPUT="$HADOLINT_OUTPUT\n$OUTPUT"
            fi
        done <<< "$DOCKERFILES"

        if [ "$HADOLINT_FAILED" = true ]; then
            print_result "Hadolint" 1 "$HADOLINT_OUTPUT"
        else
            print_result "Hadolint" 0
        fi
    fi
fi

# Docker Compose Check
if [ "$RUN_COMPOSE" = true ]; then
    print_header "Docker Compose - Configuration Validation"

    # Check if docker compose plugin is available
    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ Docker Compose plugin not available (skipped in container)${NC}"
        print_result "Docker Compose" 0 # Skip check
    else
        MAIN_COMPOSE_FILE=$(find "${PROJECT_ROOT}" -maxdepth 1 -type f \( -name "docker-compose.yml" -o -name "compose.yml" \) 2>/dev/null | head -n 1)

        if [ -z "$MAIN_COMPOSE_FILE" ]; then
            echo -e "${YELLOW}⚠ No Docker Compose files found${NC}"
            print_result "Docker Compose" 0
        else
            OVERRIDE_FILES=()
            if [ -f "${PROJECT_ROOT}/docker-compose.dev.yml" ]; then
                OVERRIDE_FILES+=("${PROJECT_ROOT}/docker-compose.dev.yml")
            fi
            mapfile -t TEST_OVERRIDE_FILES < <(find "${PROJECT_ROOT}/test" -maxdepth 1 -type f -name "docker-compose.*.yml" 2>/dev/null | sort)
            ALL_COMPOSE_FILES=("$MAIN_COMPOSE_FILE" "${OVERRIDE_FILES[@]}" "${TEST_OVERRIDE_FILES[@]}")
            COMPOSE_COUNT=${#ALL_COMPOSE_FILES[@]}

            echo "Found $COMPOSE_COUNT compose file(s). Validating..."

            COMPOSE_FAILED=false
            COMPOSE_OUTPUT=""
            for composefile in "${ALL_COMPOSE_FILES[@]}"; do
                composefile_name=$(basename "$composefile")
                echo "  Checking: $composefile_name"

                if [ "$composefile" = "$MAIN_COMPOSE_FILE" ]; then
                    # Validate base file alone
                    OUTPUT=$(cd "${PROJECT_ROOT}" && docker compose -f "$composefile_name" config --quiet 2>&1)
                else
                    # Validate override file with the base file
                    main_composefile_name=$(basename "$MAIN_COMPOSE_FILE")
                    relative_override_path="${composefile#"${PROJECT_ROOT}"/}"
                    OUTPUT=$(cd "${PROJECT_ROOT}" && docker compose -f "$main_composefile_name" -f "$relative_override_path" config --quiet 2>&1)
                fi
                EXIT_CODE=$?

                if [ $EXIT_CODE -eq 0 ]; then
                    echo -e "    ${GREEN}✓${NC} $composefile_name"
                else
                    echo -e "    ${RED}✗${NC} $composefile_name\n$OUTPUT"
                    COMPOSE_FAILED=true
                    COMPOSE_OUTPUT="$COMPOSE_OUTPUT\n$OUTPUT"
                fi
            done

            if [ "$COMPOSE_FAILED" = true ]; then
                print_result "Docker Compose" 1
            else
                print_result "Docker Compose" 0
            fi
        fi
    fi
fi

# ActionLint Check
if [ "$RUN_ACTIONLINT" = true ]; then
    print_header "ActionLint - GitHub Workflows Validation"

    # Find all workflow files
    WORKFLOW_DIR="${PROJECT_ROOT}/.github/workflows"

    if [ ! -d "$WORKFLOW_DIR" ]; then
        echo -e "${YELLOW}⚠ Workflow directory not found${NC}"
    else
        WORKFLOWS=$(find "$WORKFLOW_DIR" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null | sort)

        if [ -z "$WORKFLOWS" ]; then
            echo -e "${YELLOW}⚠ No workflow files found${NC}"
        else
            WORKFLOW_COUNT=$(echo "$WORKFLOWS" | wc -l)
            echo "Found $WORKFLOW_COUNT workflow(s). Validating..."

            ACTIONLINT_FAILED=false
            ACTIONLINT_OUTPUT=""
            while IFS= read -r workflow; do
                workflow_name=$(basename "$workflow")
                echo "  Checking: $workflow_name"

                if command -v actionlint >/dev/null 2>&1; then
                    OUTPUT=$(actionlint -color "$workflow" 2>&1)
                    EXIT_CODE=$?
                else
                    OUTPUT=$(docker run --rm \
                           -v "${PROJECT_ROOT}:/workspace" \
                           --workdir /workspace \
                           "${ACTIONLINT_IMAGE}" -color ".github/workflows/$workflow_name" 2>&1)
                    EXIT_CODE=$?
                fi

                if [ $EXIT_CODE -eq 0 ]; then
                    echo -e "    ${GREEN}✓${NC} $workflow_name"
                else
                    echo -e "    ${RED}✗${NC} $workflow_name"
                    ACTIONLINT_FAILED=true
                    ACTIONLINT_OUTPUT="$ACTIONLINT_OUTPUT\n$OUTPUT"
                fi
            done <<< "$WORKFLOWS"

            if [ "$ACTIONLINT_FAILED" = true ]; then
                print_result "ActionLint" 1 "$ACTIONLINT_OUTPUT"
            else
                print_result "ActionLint" 0
            fi
        fi
    fi
fi

# ShellCheck
if [ "$RUN_SHELLCHECK" = true ]; then
    print_header "ShellCheck - Shell Script Linting"

    mapfile -t SHELL_FILES < <(find "${PROJECT_ROOT}/test" -maxdepth 1 -type f -name "*.sh" 2>/dev/null | sort)

    if [ "${#SHELL_FILES[@]}" -eq 0 ]; then
        echo -e "${YELLOW}⚠ No shell scripts found${NC}"
    else
        FILE_COUNT=${#SHELL_FILES[@]}
        echo "Found $FILE_COUNT shell script(s). Validating..."

        if command -v shellcheck >/dev/null 2>&1; then
            OUTPUT=$(shellcheck -x --severity=style "${SHELL_FILES[@]}" 2>&1)
            EXIT_CODE=$?
        else
            SHELL_FILES_REL=()
            for file in "${SHELL_FILES[@]}"; do
                SHELL_FILES_REL+=("${file#"${PROJECT_ROOT}"/}")
            done
            OUTPUT=$(docker run --rm \
                -v "${PROJECT_ROOT}:/workspace" \
                --workdir /workspace \
                "${SHELLCHECK_IMAGE}" -x --severity=style "${SHELL_FILES_REL[@]}" 2>&1)
            EXIT_CODE=$?
        fi

        if [ $EXIT_CODE -eq 0 ]; then
            print_result "ShellCheck" 0
        else
            print_result "ShellCheck" $EXIT_CODE "$OUTPUT"
        fi
    fi
fi

# Yamllint
if [ "$RUN_YAMLLINT" = true ]; then
    print_header "Yamllint - YAML Validation"

    mapfile -t YAML_FILES < <(
        {
            find "${PROJECT_ROOT}/.github" "${PROJECT_ROOT}/test" -type f \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null
            find "${PROJECT_ROOT}" -maxdepth 1 -type f \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null
        } | sort
    )

    if [ "${#YAML_FILES[@]}" -eq 0 ]; then
        echo -e "${YELLOW}⚠ No YAML files found${NC}"
    else
        FILE_COUNT=${#YAML_FILES[@]}
        echo "Found $FILE_COUNT YAML file(s). Validating..."

        if command -v yamllint >/dev/null 2>&1; then
            YAMLLINT_CONFIG="${PROJECT_ROOT}/.yamllint.yml"
            if [ -f "$YAMLLINT_CONFIG" ]; then
                OUTPUT=$(yamllint -c "$YAMLLINT_CONFIG" "${YAML_FILES[@]}" 2>&1)
            else
                OUTPUT=$(yamllint "${YAML_FILES[@]}" 2>&1)
            fi
        else
            YAML_FILES_REL=()
            for file in "${YAML_FILES[@]}"; do
                YAML_FILES_REL+=("${file#"${PROJECT_ROOT}"/}")
            done
            OUTPUT=$(docker run --rm \
                -v "${PROJECT_ROOT}:/workspace" \
                --workdir /workspace \
                python:3.13-slim sh -lc \
                "pip install --no-cache-dir yamllint==${YAMLLINT_VERSION} >/dev/null && if [ -f .yamllint.yml ]; then yamllint -c .yamllint.yml \"\$@\"; else yamllint \"\$@\"; fi" \
                sh "${YAML_FILES_REL[@]}" 2>&1)
        fi
        EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ]; then
            print_result "Yamllint" 0
        else
            print_result "Yamllint" $EXIT_CODE "$OUTPUT"
        fi
    fi
fi

# Instruction Files Check
if [ "$RUN_INSTRUCTIONS" = true ]; then
    print_group_header "Markdown And Documentation Checks"
    print_header "Instruction Files - Repo Guidance Validation"

    echo "Running repo-specific checks on instruction files..."

    if command -v node >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}" && node test/check-instructions.mjs 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace \
               node:26-alpine node test/check-instructions.mjs 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "Instruction Files" 0
    else
        print_result "Instruction Files" $EXIT_CODE "$OUTPUT"
    fi
fi

# Documentation Files Check
if [ "$RUN_DOCUMENTATION" = true ]; then
    print_header "Documentation Files - Markdown Integrity Validation"

    echo "Running repo-specific checks on README.md and docs/**/*.md..."

    if command -v node >/dev/null 2>&1; then
        OUTPUT=$(cd "${PROJECT_ROOT}" && node test/check-documentation.mjs 2>&1)
        EXIT_CODE=$?
    else
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace \
               node:26-alpine node test/check-documentation.mjs 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "Documentation Files" 0
    else
        print_result "Documentation Files" $EXIT_CODE "$OUTPUT"
    fi
fi

# Summary
print_header "Code Quality Check Summary"

echo "Total Checks: $TOTAL_CHECKS"
echo -e "${GREEN}Passed: $PASSED_CHECKS${NC}"
echo -e "${RED}Failed: $FAILED_CHECKS${NC}"

if [ "$FIX_MODE" = true ]; then
    echo -e "\n${YELLOW}Note: Running with --fix flag. Applicable issues have been auto-corrected.${NC}"
fi

# Exit with appropriate code
if [ $FAILED_CHECKS -eq 0 ]; then
    echo -e "\n${GREEN}All code quality checks passed! ✓${NC}\n"
    exit 0
else
    echo -e "\n${RED}Some code quality checks failed. Please review and fix.${NC}\n"
    exit 1
fi
