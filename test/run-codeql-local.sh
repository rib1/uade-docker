#!/bin/sh

set -eu

PROJECT_ROOT="${PROJECT_ROOT:-/workspace}"
REPORT_DIR="${PROJECT_ROOT}/reports/codeql"
DB_ROOT="/tmp/codeql-db"

mkdir -p "${REPORT_DIR}"
rm -rf "${DB_ROOT}"
mkdir -p "${DB_ROOT}"

run_codeql_for_language() {
    language="$1"
    output_file="$2"
    suite_one="$3"
    suite_two="$4"

    echo "Creating CodeQL database for ${language}..."
    codeql database create "${DB_ROOT}/${language}" \
        --language="${language}" \
        --source-root="${PROJECT_ROOT}" \
        --overwrite

    echo "Analyzing ${language} with CodeQL..."
    codeql database analyze "${DB_ROOT}/${language}" \
        --format=sarif-latest \
        --output="${output_file}" \
        --threads=0 \
        --ram=6144 \
        "${suite_one}" \
        "${suite_two}"
}

run_codeql_for_language \
    "python" \
    "${REPORT_DIR}/codeql-python.sarif" \
    "codeql/python-queries:codeql-suites/python-security-and-quality.qls" \
    "codeql/python-queries:codeql-suites/python-security-extended.qls"

run_codeql_for_language \
    "javascript" \
    "${REPORT_DIR}/codeql-javascript.sarif" \
    "codeql/javascript-queries:codeql-suites/javascript-security-and-quality.qls" \
    "codeql/javascript-queries:codeql-suites/javascript-security-extended.qls"

echo
echo "CodeQL SARIF reports written to:"
echo "  ${REPORT_DIR}/codeql-python.sarif"
echo "  ${REPORT_DIR}/codeql-javascript.sarif"
