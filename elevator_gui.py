"""
elevator_gui.py
----------------
Tkinter UI/UX for the 4-floor elevator: a picture of the building with
hall call buttons at each floor, a cabin panel, and an animated car that
moves between floors using the exact scheduling policy implemented in
rtl/elevator_controller.v (see elevator_engine.py).

Run:
    python3 elevator_gui.py

No third-party dependencies -- only the Python standard library (tkinter).
"""

import tkinter as tk
from tkinter import ttk
from elevator_engine import ElevatorEngine, State, Direction

# ---------------------------------------------------------------- config --
NUM_FLOORS = 4
TICK_MS = 60          # ms per simulation tick (animation speed)
CANVAS_W = 340
CANVAS_H = 480
FLOOR_H = CANVAS_H // NUM_FLOORS
SHAFT_X0, SHAFT_X1 = 190, 300
CAR_MARGIN = 8

BG = "#0f172a"
FLOOR_LINE = "#334155"
SHAFT_COLOR = "#1e293b"
CAR_COLOR = "#38bdf8"
CAR_DOOR_COLOR = "#fbbf24"
TEXT_COLOR = "#e2e8f0"
BTN_ACTIVE = "#f97316"


class ElevatorApp:
    def __init__(self, root):
        self.root = root
        root.title("4-Floor Elevator Controller - Simulation")
        root.configure(bg=BG)
        root.resizable(False, False)

        self.engine = ElevatorEngine(num_floors=NUM_FLOORS)

        main = tk.Frame(root, bg=BG)
        main.pack(padx=14, pady=14)

        # ---- left: building canvas ----------------------------------
        left = tk.Frame(main, bg=BG)
        left.grid(row=0, column=0, sticky="n")

        self.canvas = tk.Canvas(left, width=CANVAS_W, height=CANVAS_H,
                                 bg=BG, highlightthickness=0)
        self.canvas.pack()

        self.status_var = tk.StringVar()
        tk.Label(left, textvariable=self.status_var, fg=TEXT_COLOR, bg=BG,
                  font=("Consolas", 11, "bold"), justify="left", anchor="w"
                  ).pack(fill="x", pady=(8, 0))

        # ---- right: controls ------------------------------------------
        right = tk.Frame(main, bg=BG)
        right.grid(row=0, column=1, sticky="n", padx=(18, 0))

        tk.Label(right, text="HALL CALLS", fg=TEXT_COLOR, bg=BG,
                  font=("Segoe UI", 11, "bold")).pack(anchor="w")
        hall_frame = tk.Frame(right, bg=BG)
        hall_frame.pack(pady=(2, 14))
        self.hall_up_btns = {}
        self.hall_down_btns = {}
        for row, floor in enumerate(reversed(range(NUM_FLOORS))):
            tk.Label(hall_frame, text=f"Floor {floor + 1}", fg=TEXT_COLOR, bg=BG,
                      width=8, anchor="w", font=("Segoe UI", 10)
                      ).grid(row=row, column=0, sticky="w", pady=2)
            up_state = "normal" if floor < NUM_FLOORS - 1 else "disabled"
            down_state = "normal" if floor > 0 else "disabled"
            b_up = tk.Button(hall_frame, text="▲", width=3, state=up_state,
                              command=lambda f=floor: self.on_hall_up(f))
            b_up.grid(row=row, column=1, padx=2)
            b_down = tk.Button(hall_frame, text="▼", width=3, state=down_state,
                                command=lambda f=floor: self.on_hall_down(f))
            b_down.grid(row=row, column=2, padx=2)
            self.hall_up_btns[floor] = b_up
            self.hall_down_btns[floor] = b_down

        tk.Label(right, text="CABIN PANEL", fg=TEXT_COLOR, bg=BG,
                  font=("Segoe UI", 11, "bold")).pack(anchor="w")
        cabin_frame = tk.Frame(right, bg=BG)
        cabin_frame.pack(pady=(2, 14))
        self.cabin_btns = {}
        for i, floor in enumerate(range(NUM_FLOORS)):
            b = tk.Button(cabin_frame, text=str(floor + 1), width=4, height=2,
                          font=("Segoe UI", 11, "bold"),
                          command=lambda f=floor: self.on_cabin(f))
            b.grid(row=i // 2, column=i % 2, padx=4, pady=4)
            self.cabin_btns[floor] = b

        tk.Label(right, text="EVENT LOG", fg=TEXT_COLOR, bg=BG,
                  font=("Segoe UI", 11, "bold")).pack(anchor="w")
        log_frame = tk.Frame(right, bg=BG)
        log_frame.pack()
        self.log_box = tk.Listbox(log_frame, width=34, height=10, bg="#111827",
                                    fg="#a3e635", font=("Consolas", 9),
                                    highlightthickness=0, borderwidth=0)
        self.log_box.pack()

        speed_frame = tk.Frame(right, bg=BG)
        speed_frame.pack(pady=(10, 0), fill="x")
        tk.Label(speed_frame, text="Speed", fg=TEXT_COLOR, bg=BG,
                  font=("Segoe UI", 9)).pack(side="left")
        self.speed_scale = tk.Scale(speed_frame, from_=20, to=200, orient="horizontal",
                                     bg=BG, fg=TEXT_COLOR, highlightthickness=0,
                                     troughcolor="#334155", length=160,
                                     command=self.on_speed_change)
        self.speed_scale.set(TICK_MS)
        self.speed_scale.pack(side="left", padx=6)

        self._draw_static()
        self.car_id = None
        self.door_ids = []
        self.tick_ms = TICK_MS
        self._log_seen = 0
        self._loop()

    # ------------------------------------------------------------ UI ---
    def _floor_y(self, floor_idx):
        """Top-of-floor pixel y for a given 0-based floor index (0=ground)."""
        row_from_top = (NUM_FLOORS - 1) - floor_idx
        return row_from_top * FLOOR_H

    def _draw_static(self):
        c = self.canvas
        # shaft
        c.create_rectangle(SHAFT_X0, 0, SHAFT_X1, CANVAS_H,
                            fill=SHAFT_COLOR, outline=FLOOR_LINE)
        # floor separators + labels
        for f in range(NUM_FLOORS):
            y = self._floor_y(f)
            c.create_line(10, y + FLOOR_H, CANVAS_W - 10, y + FLOOR_H,
                          fill=FLOOR_LINE, width=2)
            c.create_text(30, y + FLOOR_H // 2, text=f"F{f + 1}",
                          fill=TEXT_COLOR, font=("Segoe UI", 13, "bold"), anchor="w")
        c.create_line(10, 0, CANVAS_W - 10, 0, fill=FLOOR_LINE, width=2)
        c.create_rectangle(10, 0, CANVAS_W - 10, CANVAS_H, outline=FLOOR_LINE, width=2)

    def on_cabin(self, floor):
        self.engine.request_cabin(floor)

    def on_hall_up(self, floor):
        self.engine.request_hall_up(floor)

    def on_hall_down(self, floor):
        self.engine.request_hall_down(floor)

    def on_speed_change(self, val):
        self.tick_ms = int(val)

    # -------------------------------------------------------- render ---
    def _car_y(self):
        """Smoothly interpolated car top-y, including mid-move animation."""
        eng = self.engine
        base_y = self._floor_y(eng.current_floor)
        if eng.state == State.MOVE:
            frac = eng.progress_fraction()
            if eng.direction == Direction.UP:
                # moving from current_floor towards current_floor+1 (visually upward)
                target_y = self._floor_y(min(eng.current_floor + 1, NUM_FLOORS - 1))
                return base_y + (target_y - base_y) * frac
            elif eng.direction == Direction.DOWN:
                target_y = self._floor_y(max(eng.current_floor - 1, 0))
                return base_y + (target_y - base_y) * frac
        return base_y

    def _redraw_dynamic(self):
        c = self.canvas
        if self.car_id is not None:
            c.delete(self.car_id)
        for did in self.door_ids:
            c.delete(did)
        self.door_ids = []

        y_top = self._car_y() + CAR_MARGIN
        y_bot = self._car_y() + FLOOR_H - CAR_MARGIN
        self.car_id = c.create_rectangle(SHAFT_X0 + 6, y_top, SHAFT_X1 - 6, y_bot,
                                          fill=CAR_COLOR, outline="#0369a1", width=2)
        if self.engine.door_open:
            mid_x = (SHAFT_X0 + SHAFT_X1) / 2
            d1 = c.create_rectangle(SHAFT_X0 + 6, y_top, mid_x - 3, y_bot,
                                     fill=CAR_DOOR_COLOR, outline="")
            d2 = c.create_rectangle(mid_x + 3, y_top, SHAFT_X1 - 6, y_bot,
                                     fill=CAR_DOOR_COLOR, outline="")
            self.door_ids = [d1, d2]

        # button highlight for pending requests
        _OFF = "gray85"   # cross-platform neutral button background
        for f in range(NUM_FLOORS):
            self.cabin_btns[f].configure(
                bg=BTN_ACTIVE if self.engine.cabin_pending[f] else _OFF)
            if f in self.hall_up_btns:
                self.hall_up_btns[f].configure(
                    bg=BTN_ACTIVE if self.engine.hall_up_pending[f] else _OFF)
            if f in self.hall_down_btns:
                self.hall_down_btns[f].configure(
                    bg=BTN_ACTIVE if self.engine.hall_down_pending[f] else _OFF)

        dir_txt = {Direction.NONE: "-", Direction.UP: "UP", Direction.DOWN: "DOWN"}[self.engine.direction]
        self.status_var.set(
            f"Floor: {self.engine.current_floor + 1}   "
            f"State: {self.engine.state.value}   Dir: {dir_txt}\n"
            f"Door: {'OPEN' if self.engine.door_open else 'closed'}"
        )

        # log
        while self._log_seen < len(self.engine.log):
            self.log_box.insert(tk.END, self.engine.log[self._log_seen])
            self.log_box.yview_moveto(1.0)
            self._log_seen += 1

    # ------------------------------------------------------------ loop -
    def _loop(self):
        self.engine.tick()
        self._redraw_dynamic()
        self.root.after(self.tick_ms, self._loop)


def main():
    root = tk.Tk()
    ElevatorApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
