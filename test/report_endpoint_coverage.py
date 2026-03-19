from __future__ import annotations

import re
import sys
from pathlib import Path

ROUTE_RE = re.compile(r'@app\.route\("([^"]+)"')
COVERS_RE = re.compile(r"^\s*#\s*covers:\s*(.+?)\s*$", re.MULTILINE)


def route_search_patterns(route: str) -> list[re.Pattern[str]]:
    custom_patterns: dict[str, list[re.Pattern[str]]] = {
        "/": [
            re.compile(r'fetch\(\s*["\']/["\']'),
            re.compile(r'curl[^\n]*["\']\$\{?BASE_URL(?:_[AB])?\}?/["\']'),
        ],
    }

    if route in custom_patterns:
        return custom_patterns[route]

    if route == "/":
        return custom_patterns["/"]

    if "<" in route:
        prefix = route.split("<", 1)[0]
        return [re.compile(re.escape(prefix))]

    return [re.compile(re.escape(route) + r'(?=["\']|[\s?)}])')]


def main() -> None:
    server_path = Path("web/server.py")
    cli_paths = [Path(arg) for arg in sys.argv[1:]]
    test_paths = cli_paths or [Path("test_endpoints.sh"), Path("test_multiinstance.sh")]

    server_text = server_path.read_text(encoding="utf-8")
    existing_test_paths = [path for path in test_paths if path.exists()]
    tests_text = "\n".join(path.read_text(encoding="utf-8") for path in existing_test_paths)
    explicit_covers = {
        match.group(1).strip()
        for path in existing_test_paths
        for match in COVERS_RE.finditer(path.read_text(encoding="utf-8"))
    }

    routes = []
    for match in ROUTE_RE.finditer(server_text):
        route = match.group(1)
        if route not in routes:
            routes.append(route)

    covered: list[str] = []
    uncovered: list[str] = []

    for route in routes:
        patterns = route_search_patterns(route)
        if route in explicit_covers or any(pattern.search(tests_text) for pattern in patterns):
            covered.append(route)
        else:
            uncovered.append(route)

    print("--- Endpoint Coverage Summary ---")
    print(f"Test files scanned: {', '.join(path.name for path in existing_test_paths)}")
    print("Covered directly in test shell files:")
    for route in covered:
        print(f"  {route}")

    print()
    print("Not directly covered in test shell files:")
    for route in uncovered:
        print(f"  {route}")


if __name__ == "__main__":
    main()
