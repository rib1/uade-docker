from __future__ import annotations

import re
import sys
from pathlib import Path


ROUTE_RE = re.compile(r'@app\.route\("([^"]+)"')


def route_search_patterns(route: str) -> list[re.Pattern[str]]:
    if route == "/":
        return [
            re.compile(r'fetch\(\s*["\']/?["\']'),
            re.compile(r'curl[^\n]*["\']\$\{?BASE_URL(?:_[AB])?\}?/?["\']'),
        ]

    if "<" in route:
        prefix = route.split("<", 1)[0]
        return [re.compile(re.escape(prefix))]

    return [re.compile(re.escape(route) + r'(?=["\']|[\s?)}])')]


def main() -> None:
    server_path = Path("web/server.py")
    cli_paths = [Path(arg) for arg in sys.argv[1:]]
    test_paths = cli_paths or [Path("test_endpoints.sh"), Path("test_multiinstance.sh")]

    server_text = server_path.read_text(encoding="utf-8")
    tests_text = "\n".join(path.read_text(encoding="utf-8") for path in test_paths if path.exists())

    routes = []
    for match in ROUTE_RE.finditer(server_text):
        route = match.group(1)
        if route not in routes:
            routes.append(route)

    covered: list[str] = []
    uncovered: list[str] = []

    for route in routes:
        patterns = route_search_patterns(route)
        if any(pattern.search(tests_text) for pattern in patterns):
            covered.append(route)
        else:
            uncovered.append(route)

    print("--- Endpoint Coverage Summary ---")
    print(f"Test files scanned: {', '.join(path.name for path in test_paths if path.exists())}")
    print("Covered directly in test shell files:")
    for route in covered:
        print(f"  {route}")

    print()
    print("Not directly covered in test shell files:")
    for route in uncovered:
        print(f"  {route}")


if __name__ == "__main__":
    main()
