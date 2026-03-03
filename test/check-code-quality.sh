#!/bin/bash

# UADE Docker - Code Quality Automation Script
# This script runs all code quality checks: ESLint, Black, ActionLint
# No local dependencies needed - all tools run in Docker containers
#
# Usage:
#   ./test/check-code-quality.sh              # Run all checks
#   ./test/check-code-quality.sh --fix        # Run with fixes enabled
#   ./test/check-code-quality.sh --eslint     # ESLint only
#   ./test/check-code-quality.sh --black      # Black only
#   ./test/check-code-quality.sh --ruff       # Ruff only
#   ./test/check-code-quality.sh --actionlint # ActionLint only
#   ./test/check-code-quality.sh --hadolint   # Hadolint only
#   ./test/check-code-quality.sh --compose    # Docker Compose only

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

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

# Parse arguments
FIX_MODE=false
RUN_ESLINT=true
RUN_BLACK=true
RUN_RUFF=true
RUN_ACTIONLINT=true
RUN_HADOLINT=true
RUN_COMPOSE=true

for arg in "$@"; do
    case $arg in
        --fix)
            FIX_MODE=true
            shift
            ;;
        --eslint)
            RUN_ESLINT=true
            RUN_BLACK=false
            RUN_RUFF=false
            RUN_ACTIONLINT=false
            RUN_HADOLINT=false
            RUN_COMPOSE=false
            shift
            ;;
        --black)
            RUN_BLACK=true
            RUN_ESLINT=false
            RUN_RUFF=false
            RUN_ACTIONLINT=false
            RUN_HADOLINT=false
            RUN_COMPOSE=false
            shift
            ;;
        --ruff)
            RUN_RUFF=true
            RUN_ESLINT=false
            RUN_BLACK=false
            RUN_ACTIONLINT=false
            RUN_HADOLINT=false
            RUN_COMPOSE=false
            shift
            ;;
        --actionlint)
            RUN_ACTIONLINT=true
            RUN_ESLINT=false
            RUN_BLACK=false
            RUN_RUFF=false
            RUN_HADOLINT=false
            RUN_COMPOSE=false
            shift
            ;;
        --hadolint)
            RUN_HADOLINT=true
            RUN_ESLINT=false
            RUN_BLACK=false
            RUN_RUFF=false
            RUN_ACTIONLINT=false
            RUN_COMPOSE=false
            shift
            ;;
        --compose)
            RUN_COMPOSE=true
            RUN_ESLINT=false
            RUN_BLACK=false
            RUN_RUFF=false
            RUN_ACTIONLINT=false
            RUN_HADOLINT=false
            shift
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--fix] [--eslint|--black|--actionlint|--hadolint|--compose]"
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

    if [ $exit_code -eq 0 ]; then
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

# ESLint Check
if [ "$RUN_ESLINT" = true ]; then
    print_header "ESLint - JavaScript/CSS Linting"

    echo "Running ESLint on /web/static..."

    FIX_MODE_ARG=""
    if [ "$FIX_MODE" = true ]; then
        FIX_MODE_ARG="--fix"
    fi

    # Check if eslint is available locally (in Docker container)
    if command -v eslint >/dev/null 2>&1; then
        # Use local eslint - run from the directory containing eslint.config.js
        OUTPUT=$(cd "${PROJECT_ROOT}/web/static" && eslint . $FIX_MODE_ARG 2>&1)
        EXIT_CODE=$?
    else
        # Fall back to Docker (for local dev environments)
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}/web/static:/data" \
               cytopia/eslint . $FIX_MODE_ARG 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "ESLint" 0
    else
        print_result "ESLint" $EXIT_CODE "$OUTPUT"
    fi
fi

# Black Check
if [ "$RUN_BLACK" = true ]; then
    print_header "Black - Python Code Formatting"

    echo "Running Black on /web..."

    FIX_MODE_ARG="--check"
    if [ "$FIX_MODE" = true ]; then
        FIX_MODE_ARG=""
    fi

    # Check if black is available locally (in Docker container)
    if command -v black >/dev/null 2>&1; then
        # Use local black
        OUTPUT=$(cd "${PROJECT_ROOT}/web" && black . --line-length 100 $FIX_MODE_ARG 2>&1)
        EXIT_CODE=$?
    else
        # Fall back to Docker (for local dev environments)
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}/web:/data" \
               cytopia/black . --line-length 100 $FIX_MODE_ARG 2>&1)
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

    echo "Running Ruff on /web..."

    FIX_MODE_ARG=""
    if [ "$FIX_MODE" = true ]; then
        FIX_MODE_ARG="--fix"
    fi

    # Check if ruff is available locally (in Docker container)
    if command -v ruff >/dev/null 2>&1; then
        # Use local ruff
        OUTPUT=$(cd "${PROJECT_ROOT}/web" && ruff check . $FIX_MODE_ARG 2>&1)
        EXIT_CODE=$?
    else
        # Fall back to Docker (for local dev environments)
        OUTPUT=$(docker run --rm \
               -v "${PROJECT_ROOT}:/workspace" \
               --workdir /workspace/web \
               ghcr.io/astral-sh/ruff:latest check . $FIX_MODE_ARG 2>&1)
        EXIT_CODE=$?
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        print_result "Ruff" 0
    else
        print_result "Ruff" $EXIT_CODE "$OUTPUT"
    fi
fi

# Hadolint Check
if [ "$RUN_HADOLINT" = true ]; then
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

            # Check if hadolint is available locally (in Docker container)
            if command -v hadolint >/dev/null 2>&1; then
                # Use local hadolint
                OUTPUT=$(hadolint "$dockerfile" 2>&1)
                EXIT_CODE=$?
            else
                # Fall back to Docker (for local dev environments)
                OUTPUT=$(docker run --rm -i \
                    -v "${PROJECT_ROOT}/.hadolint.yaml:/.hadolint.yaml:ro" \
                    hadolint/hadolint:v2.12.0 hadolint --config /.hadolint.yaml - < "$dockerfile" 2>&1)
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
    else
        # Find main Docker Compose files (not overrides which require base file)
        COMPOSE_FILES=$(find "${PROJECT_ROOT}" -maxdepth 1 -type f \( -name "docker-compose.yml" -o -name "compose.yml" \) 2>/dev/null | sort)

        if [ -z "$COMPOSE_FILES" ]; then
            echo -e "${YELLOW}⚠ No Docker Compose files found${NC}"
        else
            COMPOSE_COUNT=$(echo "$COMPOSE_FILES" | wc -l)
            echo "Found $COMPOSE_COUNT compose file(s). Validating..."

            COMPOSE_FAILED=false
            COMPOSE_OUTPUT=""
            while IFS= read -r composefile; do
                composefile_name=$(basename "$composefile")
                echo "  Checking: $composefile_name"

                # Use docker compose config to validate
                OUTPUT=$(docker compose -f "$composefile" config --quiet 2>&1)
                EXIT_CODE=$?

                if [ $EXIT_CODE -eq 0 ]; then
                    echo -e "    ${GREEN}✓${NC} $composefile_name"
                else
                    echo -e "    ${RED}✗${NC} $composefile_name"
                    COMPOSE_FAILED=true
                    COMPOSE_OUTPUT="$COMPOSE_OUTPUT\n$OUTPUT"
                fi
            done <<< "$COMPOSE_FILES"

            if [ "$COMPOSE_FAILED" = true ]; then
                print_result "Docker Compose" 1 "$COMPOSE_OUTPUT"
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

                # Check if actionlint is available locally (in Docker container)
                if command -v actionlint >/dev/null 2>&1; then
                    # Use local actionlint
                    OUTPUT=$(actionlint -color "$workflow" 2>&1)
                    EXIT_CODE=$?
                else
                    # Fall back to Docker (for local dev environments)
                    OUTPUT=$(docker run --rm \
                           -v "${PROJECT_ROOT}:/workspace" \
                           --workdir /workspace \
                           rhysd/actionlint -color ".github/workflows/$workflow_name" 2>&1)
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
