"""
elevator_engine.py
-------------------
Pure-Python model of the SAME scheduling policy implemented in
rtl/elevator_controller.v, so the GUI's behaviour matches the hardware:

  1. SCAN / LOOK servicing: while moving, keep going and stop at every
     floor that has a pending request in the current direction of travel
     (or a cabin call for that floor).
  2. If nothing is pending further ahead, reverse only if something is
     pending behind; otherwise go idle.
  3. From idle, head for the NEAREST pending request.
  4. A request at the current floor in the opposite direction is served
     immediately (matches real elevators / the RTL's reversal case).

Floors are 0-based internally (0 = Floor 1 ... N-1 = Floor N), exactly
like the RTL's `current_floor`.

This module has NO GUI dependency so it can be exercised by a plain
`python3 elevator_engine.py` self-test, independent of tkinter/display.
"""

from dataclasses import dataclass, field
from enum import Enum


class State(Enum):
    IDLE = "IDLE"
    MOVE = "MOVE"
    DOOR = "DOOR"


class Direction(Enum):
    NONE = 0
    UP = 1
    DOWN = 2


@dataclass
class ElevatorEngine:
    num_floors: int = 4
    move_ticks: int = 5   # ticks to travel one floor  (== MOVE_CYCLES in RTL)
    door_ticks: int = 4   # ticks the door stays open  (== DOOR_CYCLES in RTL)

    current_floor: int = 0
    state: State = State.IDLE
    direction: Direction = Direction.NONE

    cabin_pending: list = field(default_factory=lambda: None)
    hall_up_pending: list = field(default_factory=lambda: None)
    hall_down_pending: list = field(default_factory=lambda: None)

    _move_cnt: int = 0
    _door_cnt: int = 0
    door_open: bool = False

    # simple event log for the UI ("Floor 3: door opened", ...)
    log: list = field(default_factory=list)

    def __post_init__(self):
        self.cabin_pending = [False] * self.num_floors
        self.hall_up_pending = [False] * self.num_floors
        self.hall_down_pending = [False] * self.num_floors

    # -------------------------------------------------------------- #
    # External request inputs (call these from button handlers)
    # -------------------------------------------------------------- #
    def request_cabin(self, floor: int):
        if 0 <= floor < self.num_floors:
            self.cabin_pending[floor] = True
            self._log(f"Cabin button pressed for Floor {floor + 1}")

    def request_hall_up(self, floor: int):
        if 0 <= floor < self.num_floors - 1:
            self.hall_up_pending[floor] = True
            self._log(f"Hall UP call at Floor {floor + 1}")

    def request_hall_down(self, floor: int):
        if 0 < floor < self.num_floors:
            self.hall_down_pending[floor] = True
            self._log(f"Hall DOWN call at Floor {floor + 1}")

    # -------------------------------------------------------------- #
    # Internal helpers (mirror the RTL functions of the same intent)
    # -------------------------------------------------------------- #
    def _any_pending_mask(self):
        return [c or u or d for c, u, d in
                zip(self.cabin_pending, self.hall_up_pending, self.hall_down_pending)]

    def _has_above(self, mask, floor):
        return any(mask[k] for k in range(floor + 1, self.num_floors))

    def _has_below(self, mask, floor):
        return any(mask[k] for k in range(0, floor))

    def _nearest_floor(self, mask, floor):
        best, best_d = floor, self.num_floors + 1
        for k in range(self.num_floors):
            if mask[k]:
                d = abs(k - floor)
                if d < best_d:
                    best, best_d = k, d
        return best

    def _should_stop_here(self):
        f, d = self.current_floor, self.direction
        combined = self._any_pending_mask()
        if self.cabin_pending[f]:
            return True
        if d == Direction.UP and self.hall_up_pending[f]:
            return True
        if d == Direction.DOWN and self.hall_down_pending[f]:
            return True
        # reversal case: nothing left ahead, but opposite call waiting here
        if d == Direction.UP and not self._has_above(combined, f) and self.hall_down_pending[f]:
            return True
        if d == Direction.DOWN and not self._has_below(combined, f) and self.hall_up_pending[f]:
            return True
        return False

    def _clear_requests_here(self):
        f, d = self.current_floor, self.direction
        self.cabin_pending[f] = False
        # NONE (idle-stop) clears both; UP clears up-call; DOWN clears down-call
        if d != Direction.DOWN:
            self.hall_up_pending[f] = False
        if d != Direction.UP:
            self.hall_down_pending[f] = False

    def _log(self, msg):
        self.log.append(msg)
        if len(self.log) > 200:
            self.log.pop(0)

    # -------------------------------------------------------------- #
    # One simulation tick == one clock cycle in the RTL
    # -------------------------------------------------------------- #
    def tick(self):
        mask = self._any_pending_mask()

        if self.state == State.IDLE:
            self.door_open = False
            if mask[self.current_floor]:
                self._clear_requests_here()
                self.state = State.DOOR
                self._door_cnt = 0
                self.door_open = True
                self._log(f"Floor {self.current_floor + 1}: door opened")
            elif any(mask):
                target = self._nearest_floor(mask, self.current_floor)
                self.direction = Direction.UP if target > self.current_floor else Direction.DOWN
                self.state = State.MOVE
                self._move_cnt = 0
                self._log(f"Departing Floor {self.current_floor + 1}, "
                           f"heading {self.direction.name}")

        elif self.state == State.MOVE:
            self._move_cnt += 1
            if self._move_cnt >= self.move_ticks:
                self._move_cnt = 0
                self.current_floor += 1 if self.direction == Direction.UP else -1
                self.current_floor = max(0, min(self.num_floors - 1, self.current_floor))
                if self._should_stop_here():
                    self._clear_requests_here()
                    self.state = State.DOOR
                    self._door_cnt = 0
                    self.door_open = True
                    self._log(f"Floor {self.current_floor + 1}: door opened")
                # else keep moving in the same direction next tick

        elif self.state == State.DOOR:
            self._door_cnt += 1
            if self._door_cnt >= self.door_ticks:
                self.door_open = False
                self.state = State.IDLE
                self._log(f"Floor {self.current_floor + 1}: door closed")

    # -------------------------------------------------------------- #
    def progress_fraction(self):
        """0.0..1.0 -- how far through the current inter-floor move we are,
        for smooth UI animation. 0 when not moving."""
        if self.state != State.MOVE:
            return 0.0
        return self._move_cnt / self.move_ticks


# ----------------------------------------------------------------------
# Self-test: run with `python3 elevator_engine.py` -- no GUI required.
# Mirrors the scenarios checked in tb/elevator_tb.v.
# ----------------------------------------------------------------------
if __name__ == "__main__":
    def run_until_idle(eng, max_ticks=2000):
        for _ in range(max_ticks):
            eng.tick()
            if eng.state == State.IDLE and not any(eng._any_pending_mask()):
                return True
        return False

    print("Test 1: single cabin request to Floor 3")
    e = ElevatorEngine()
    e.request_cabin(2)
    ok = run_until_idle(e)
    assert ok, "did not settle"
    print("  PASS -", e.log[-3:])

    print("Test 2: simultaneous requests serviced via SCAN")
    e = ElevatorEngine()
    e.request_cabin(3)   # Floor 4
    e.request_cabin(0)   # Floor 1
    e.request_hall_up(1)  # Floor 2
    visited = []
    for _ in range(2000):
        prev_floor, prev_door = e.current_floor, e.door_open
        e.tick()
        if e.door_open and not prev_door:
            visited.append(e.current_floor + 1)
        if e.state == State.IDLE and not any(e._any_pending_mask()):
            break
    print("  Visited floors in order:", visited)
    assert set(visited) >= {1, 2, 4}, "not all requests serviced"
    print("  PASS")

    print("Test 3: boundary floors never exceeded")
    e = ElevatorEngine()
    e.request_cabin(3)
    for _ in range(200):
        e.tick()
        assert 0 <= e.current_floor <= 3
    print("  PASS")

    print("\nAll engine self-tests passed.")
