# Area / fit tracking (IHP sg13g2 stdcell, typ corner)

Tool: `tools/synth.sh [src.v] [top]` (yosys -> dfflibmap + abc against the IHP sg13g2
`sg13g2_stdcell_typ_1p20V_25C` liberty, fetched into `.synth/`). Reports mapped cell count and
`Chip area` per module. This is a *pre-layout* estimate (no PnR, no clock tree, no IO/pad ring), so
treat it as a floor, not the final area.

| module | mapped cells | chip area (um^2) | sequential |
|---|---|---|---|
| `pio_engine` (one engine, v0.4 incl. WAIT/IRQ/32-bit X/Y) | 4866 | 90 817 | 46.8% (868 dfrbpq) |
| `tt_um_protocol_emulator` (M1 UART TX) | see run | small | - |

## Budget

- 6x4 tiles: ~0.916 mm^2 gross = ~916 000 um^2 (usable stdcell ~0.75 mm^2 = 750 000 um^2).
- **4 engines alone = ~363 000 um^2 / ~19 500 cells** -> ~48% of usable area / ~80% of the
  ~24K-cell logic budget, before the sequencer, 4-bank IMEM (128x16) and the config port.
- The FIFOs are synthesised as **flops, not SRAM** (yosys "Replacing memory txf/rxf with list of
  registers"): 2x 4-deep x 32-bit per engine = 256 flops/engine. That is the biggest single
  area lever if we overflow.
- **Fallback (PLAN): 2 engines instead of 4** -> ~181 000 um^2, leaving comfortable headroom.

## Next

- Run the real IHP flow (tt-support-tools / LibreLane in the devcontainer) on the full top-level
  once M3 integration lands, and track mapped area vs the 6x4 tile budget in CI.
- Watch the MUX count (867 `mux2_1` + 130 `mux4_1` per engine) - it dominates PnR.
