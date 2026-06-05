#!/usr/bin/env bash
# lower the verity-emitted yul (../yul/*.yul) to evm bytecode.
# needs standalone solc 0.8.33 (verity's pin). override with SOLC=/path/to/solc.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
solc_bin="${SOLC:-solc}"
yul_dir="$here/../yul"
out="$here/bytecode"
mkdir -p "$out"

if ! command -v "$solc_bin" >/dev/null 2>&1; then
  echo "solc not found ('$solc_bin'). install solc 0.8.33: 'svm install 0.8.33' or Verity's 'make setup-solc'." >&2
  exit 1
fi

ver="$("$solc_bin" --version | sed -n 's/.*Version: \([0-9.]*\).*/\1/p' | head -1)"
[ "$ver" = "0.8.33" ] || echo "warning: solc $ver (verity pins 0.8.33; selectors/codegen may differ)" >&2

for f in "$yul_dir"/*.yul; do
  name="$(basename "$f" .yul)"
  # strict-assembly compiles the `object \"...\" { ... }` form verity emits.
  "$solc_bin" --strict-assembly --optimize --bin "$f" \
    | awk '/Binary representation:/{getline; print; exit}' > "$out/$name.bin"
  echo "built $out/$name.bin ($(wc -c < "$out/$name.bin") bytes hex)"
done
echo "done. wire VerityParity.t.sol into ../../../test/formal/ and run forge test (see README)."
