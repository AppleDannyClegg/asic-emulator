#!/usr/bin/env bash
# Map a Verilog source to the IHP sg13g2 stdcell library and report the mapped cell area.
# Usage: tools/synth.sh [src.v] [top]   (default: src/pio_engine.v)
# Env:   LIBERTY=<path to .lib>   PDK_ROOT=<tt pdk root>   (else fetches the liberty into .synth/)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/src/pio_engine.v}"
TOP="${2:-$(basename "$SRC" .v)}"
LIB="${LIBERTY:-${PDK_ROOT:-}/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib}"
if [ ! -f "$LIB" ]; then
  LIB="$ROOT/.synth/sg13g2_stdcell_typ_1p20V_25C.lib"
  mkdir -p "$(dirname "$LIB")"
  [ -f "$LIB" ] || curl -sL -o "$LIB" \
    https://raw.githubusercontent.com/IHP-GmbH/IHP-Open-PDK/main/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib
fi
echo "== synth $TOP from $SRC (lib $(basename "$LIB")) =="
yosys -q -p "
  read_verilog -sv $SRC;
  hierarchy -top $TOP;
  synth -top $TOP -flatten;
  dfflibmap -liberty $LIB;
  abc -liberty $LIB;
  setundef -zero;
  opt_clean;
  stat -liberty $LIB;
"
