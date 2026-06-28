#!/bin/bash
# Compile all wrapgraphics examples.
# Must be run from the project root directory.
#
# Usage:
#   ./build/build_all.sh
#   bash build/build_all.sh

set -e

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT"

mkdir -p build

for tex in example/*.tex; do
    name="$(basename "$tex" .tex)"
    echo ""
    echo "=== Compiling $name ==="
    echo ""
    lualatex --shell-escape --output-directory=build "$tex"
done

echo ""
echo "=== All examples compiled ==="
echo "Output files are in build/"
ls -lh build/*.pdf 2>/dev/null || echo "(no PDFs found)"
