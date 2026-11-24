# 4-Floor Elevator Controller — CLA2 VLSI Design Project
**Course:** 21ECC303TA – VLSI Design and Technology  
**Assessment:** CLA-2 | Problem Statement 3  
**Student:** Kirubalan | SRMIST Tiruchirappalli

---

## Project Overview

A fully verified RTL implementation of a **four-floor elevator controller** with
**priority-based (SCAN / LOOK algorithm) servicing** of simultaneous floor
requests, plus a Python GUI that runs the same scheduling engine so you can
interact with the design visually.

---

## Repository Layout

```
elevator/
├── rtl/
│   └── elevator_controller.v      # Synthesizable Verilog RTL (top module)
├── tb/
│   └── elevator_tb.v              # 5-scenario testbench (Icarus Verilog)
├── python/
│   ├── elevator_engine.py         # Python model of the exact RTL FSM (no GUI dep.)
│   └── elevator_gui.py            # Tkinter UI — run this for the demo
├── synth/
│   ├── yosys_report.txt           # Generic synthesis statistics
│   └── elevator_controller_synth.v
├── sim_out/
│   ├── sim_log.txt                # Testbench console output
│   └── elevator.vcd               # GTKWave waveform (open after simulation)
└── README.md
```

---

## Quick Start

### RTL Simulation (Icarus Verilog)
```bash
# Compile
iverilog -g2012 -o sim_out/elevator_sim \
         rtl/elevator_controller.v tb/elevator_tb.v

# Run (prints pass/fail per scenario)
vvp sim_out/elevator_sim

# View waveform
gtkwave elevator.vcd &
```

### Synthesis (Yosys — generic cells)
```bash
yosys -p "read_verilog rtl/elevator_controller.v; synth -top elevator_controller; stat"
```

### Python GUI
```bash
# Engine self-test (no GUI required)
python3 python/elevator_engine.py

# Full GUI (requires Python ≥ 3.8 + tkinter)
cd python
python3 elevator_gui.py
```

---

## Design — Architecture Summary

### FSM States
| State | Meaning |
|-------|---------|
| `IDLE` | Car at rest; samples pending requests each cycle |
| `MOVE` | Car travelling between floors; counts `MOVE_CYCLES` ticks per floor |
| `DOOR` | Door open at a serviced floor; counts `DOOR_CYCLES` ticks |

### Scheduling Policy (SCAN/LOOK)
1. **While moving** — stop at every floor with a pending request *in the current travel direction* (cabin call or matching hall call). This is the SCAN sweep.  
2. **Reversal** — if nothing is pending further ahead, reverse only if requests exist behind; otherwise go `IDLE`.  
3. **From IDLE** — choose the *nearest* pending floor to minimise wasted travel.  
4. **Opposite call at current floor** — served immediately before the car moves on (realistic door re-open behaviour).

### Key Parameters (RTL)
| Parameter | Default | Description |
|-----------|---------|-------------|
| `NUM_FLOORS` | 4 | Number of floors |
| `MOVE_CYCLES` | 5 | Clock cycles to travel one floor |
| `DOOR_CYCLES` | 4 | Clock cycles door stays open |

---

## Synthesis Results (Yosys — generic)

| Metric | Value |
|--------|-------|
| Total cells | 324 |
| Flip-flops (DFF) | 28 |
| Multiplexers | 64 |
| Logic gates | 232 |
| Memory bits | 0 |
| Check issues | 0 |

---

## Testbench Scenarios

| Test | Scenario | Result |
|------|----------|--------|
| T1 | Reset: floor=1, door closed, IDLE | ✅ PASS |
| T2 | Single cabin request → Floor 3 | ✅ PASS |
| T3 | Simultaneous: cabin F4, cabin F1, hall-up F2 | ✅ PASS |
| T4 | Boundary: no movement beyond Floor 4 | ✅ PASS |
| T5 | Opposite-direction hall call picked up on return | ✅ PASS |

---

## GUI Controls

| Control | Action |
|---------|--------|
| **▲ / ▼ buttons** (right panel) | Hall UP / DOWN calls at each floor |
| **1 / 2 / 3 / 4 buttons** (cabin panel) | Cabin destination buttons |
| **Speed slider** | Simulation speed (20 ms – 200 ms per tick) |
| **Orange highlight** | Pending (latched) request |
| **Yellow car halves** | Door open animation |
| **Event log** | Scrolling history of all stops and direction changes |
