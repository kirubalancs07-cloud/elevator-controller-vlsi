// =============================================================================
// elevator_controller.v
// Four-floor elevator controller with priority-based (SCAN/LOOK) servicing.
//
// Supports multiple simultaneous floor requests:
//   - cabin_req[i]      : passenger pressed floor button i inside the car
//   - hall_up_req[i]    : someone pressed "UP"   at floor i (not valid at top)
//   - hall_down_req[i]  : someone pressed "DOWN" at floor i (not valid at bottom)
//
// Scheduling policy (priority-based servicing):
//   1. While moving in a direction, the car keeps travelling and stops at any
//      floor with a pending request in that same direction (or a cabin call),
//      i.e. classic SCAN/elevator algorithm -> minimizes direction reversals
//      and average waiting time under multiple simultaneous requests.
//   2. If no more requests exist ahead in the current direction, the car
//      reverses only if a request exists behind it; otherwise it goes IDLE.
//   3. When IDLE, the next target is the NEAREST pending request (cabin or
//      hall), so the closest passenger is always serviced first.
//   4. A request at the car's current floor in the opposite direction is
//      serviced immediately (the door reopens) before the car moves on,
//      matching real elevator behaviour.
//
// All floor indices in the RTL are 0-based: index 0 = Floor 1 ... index
// NUM_FLOORS-1 = Floor NUM_FLOORS. current_floor is exposed 0-based; the
// Python UI adds +1 for display.
// =============================================================================

module elevator_controller #(
    parameter NUM_FLOORS  = 4,
    parameter FBITS       = 2,   // ceil(log2(NUM_FLOORS)) -> width of current_floor
    parameter MOVE_CYCLES = 5,   // clk cycles to travel between adjacent floors
    parameter DOOR_CYCLES = 4    // clk cycles the door stays open per stop
)(
    input  wire                    clk,
    input  wire                    rst_n,          // active-low synchronous reset

    // ---- external request inputs (level, sampled every cycle; a 1-cycle
    //      pulse is enough since requests are latched internally) ----------
    input  wire [NUM_FLOORS-1:0]   cabin_req,
    input  wire [NUM_FLOORS-1:0]   hall_up_req,
    input  wire [NUM_FLOORS-1:0]   hall_down_req,

    // ---- status outputs ---------------------------------------------------
    output reg  [FBITS-1:0]        current_floor,      // 0-based floor index
    output reg                     door_open,
    output reg                     moving_up,
    output reg                     moving_down,
    output reg  [1:0]              state_o,            // 0=IDLE,1=MOVE,2=DOOR
    output reg  [NUM_FLOORS-1:0]   cabin_req_pending,
    output reg  [NUM_FLOORS-1:0]   hall_up_pending,
    output reg  [NUM_FLOORS-1:0]   hall_down_pending
);

    // ------------------------------------------------------------------
    // FSM state encoding
    // ------------------------------------------------------------------
    localparam S_IDLE = 2'd0,
               S_MOVE  = 2'd1,
               S_DOOR  = 2'd2;

    reg [1:0]  state, next_state;

    // 0 = no direction, 1 = up, 2 = down  (kept separate from moving_up/down
    // outputs so direction can be "remembered" while IDLE for SCAN order)
    localparam DIR_NONE = 2'd0,
               DIR_UP   = 2'd1,
               DIR_DOWN = 2'd2;
    reg [1:0] direction;

    reg [$clog2(MOVE_CYCLES+1)-1:0] move_cnt;
    reg [$clog2(DOOR_CYCLES+1)-1:0] door_cnt;

    integer i;

    // ------------------------------------------------------------------
    // Combined "any request pending at floor i" mask (used for stop and
    // for nearest-floor search while idle)
    // ------------------------------------------------------------------
    wire [NUM_FLOORS-1:0] any_pending;
    assign any_pending = cabin_req_pending | hall_up_pending | hall_down_pending;

    // Is there a request strictly above / below current_floor, restricted
    // to the given direction's relevant mask?
    function automatic has_above;
        input [NUM_FLOORS-1:0] mask;
        input [FBITS-1:0]      floor;
        integer k;
        begin
            has_above = 1'b0;
            for (k = 0; k < NUM_FLOORS; k = k + 1)
                if (k > floor && mask[k])
                    has_above = 1'b1;
        end
    endfunction

    function automatic has_below;
        input [NUM_FLOORS-1:0] mask;
        input [FBITS-1:0]      floor;
        integer k;
        begin
            has_below = 1'b0;
            for (k = 0; k < NUM_FLOORS; k = k + 1)
                if (k < floor && mask[k])
                    has_below = 1'b1;
        end
    endfunction

    // Nearest pending floor to `floor` (used only from IDLE). Returns the
    // floor index; valid only when any_pending != 0.
    function automatic [FBITS-1:0] nearest_floor;
        input [NUM_FLOORS-1:0] mask;
        input [FBITS-1:0]      floor;
        integer k;
        integer best_dist;
        reg [FBITS-1:0] best_floor;
        integer diffv;
        begin
            best_dist  = NUM_FLOORS + 1;
            best_floor = floor;
            for (k = 0; k < NUM_FLOORS; k = k + 1) begin
                if (mask[k]) begin
                    diffv = (k > floor) ? (k - floor) : (floor - k);
                    if (diffv < best_dist) begin
                        best_dist  = diffv;
                        best_floor = k[FBITS-1:0];
                    end
                end
            end
            nearest_floor = best_floor;
        end
    endfunction

    // Should the car stop at its current floor given its current direction?
    function automatic should_stop_here;
        input [NUM_FLOORS-1:0] cabin_m, up_m, down_m;
        input [FBITS-1:0]      floor;
        input [1:0]            dir;
        begin
            should_stop_here =
                cabin_m[floor] ||
                (dir == DIR_UP   && up_m[floor])   ||
                (dir == DIR_DOWN && down_m[floor]) ||
                // reversal / boarding at a floor where only the opposite
                // hall call is pending and nothing remains ahead
                (dir == DIR_UP   && !has_above((cabin_m|up_m|down_m), floor) && down_m[floor]) ||
                (dir == DIR_DOWN && !has_below((cabin_m|up_m|down_m), floor) && up_m[floor]);
        end
    endfunction

    // ------------------------------------------------------------------
    // Request latch: OR-in new requests every cycle, clear serviced ones
    // the cycle the door opens at that floor.
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            cabin_req_pending <= {NUM_FLOORS{1'b0}};
            hall_up_pending   <= {NUM_FLOORS{1'b0}};
            hall_down_pending <= {NUM_FLOORS{1'b0}};
        end else begin
            cabin_req_pending <= cabin_req_pending | cabin_req;
            hall_up_pending   <= hall_up_pending   | hall_up_req;
            hall_down_pending <= hall_down_pending | hall_down_req;

            if (state == S_MOVE && next_state == S_DOOR) begin
                // about to stop at current_floor next cycle -> clear it
                cabin_req_pending[current_floor] <= 1'b0;
                if (direction != DIR_DOWN) hall_up_pending[current_floor]   <= 1'b0;
                if (direction != DIR_UP)   hall_down_pending[current_floor] <= 1'b0;
            end else if (state == S_IDLE && next_state == S_DOOR) begin
                cabin_req_pending[current_floor] <= 1'b0;
                hall_up_pending[current_floor]   <= 1'b0;
                hall_down_pending[current_floor] <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Next-state / control logic
    // ------------------------------------------------------------------
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (any_pending[current_floor])
                    next_state = S_DOOR;               // request appeared at rest floor
                else if (any_pending != {NUM_FLOORS{1'b0}})
                    next_state = S_MOVE;                // go serve nearest request
            end

            S_MOVE: begin
                if (move_cnt == MOVE_CYCLES-1) begin
                    // arriving at the next floor this cycle
                    if (should_stop_here(cabin_req_pending, hall_up_pending,
                                          hall_down_pending, current_floor, direction))
                        next_state = S_DOOR;
                    else
                        next_state = S_MOVE;
                end
            end

            S_DOOR: begin
                if (door_cnt == DOOR_CYCLES-1)
                    next_state = S_IDLE;                // re-evaluate direction from IDLE
            end
            default: next_state = S_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // State / datapath registers
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            current_floor <= {FBITS{1'b0}};
            direction     <= DIR_NONE;
            move_cnt      <= 0;
            door_cnt      <= 0;
            door_open     <= 1'b0;
            moving_up     <= 1'b0;
            moving_down   <= 1'b0;
        end else begin
            state <= next_state;

            case (state)
                S_IDLE: begin
                    door_open   <= 1'b0;
                    moving_up   <= 1'b0;
                    moving_down <= 1'b0;
                    move_cnt    <= 0;
                    if (next_state == S_MOVE) begin
                        // pick direction toward the nearest pending request
                        if (nearest_floor(any_pending, current_floor) > current_floor)
                            direction <= DIR_UP;
                        else
                            direction <= DIR_DOWN;
                    end
                end

                S_MOVE: begin
                    door_open   <= 1'b0;
                    moving_up   <= (direction == DIR_UP);
                    moving_down <= (direction == DIR_DOWN);

                    if (move_cnt == MOVE_CYCLES-1) begin
                        move_cnt <= 0;
                        // advance physical floor position
                        if (direction == DIR_UP)
                            current_floor <= current_floor + 1'b1;
                        else if (direction == DIR_DOWN)
                            current_floor <= current_floor - 1'b1;
                    end else begin
                        move_cnt <= move_cnt + 1'b1;
                    end
                end

                S_DOOR: begin
                    moving_up   <= 1'b0;
                    moving_down <= 1'b0;
                    door_open   <= 1'b1;
                    if (door_cnt == DOOR_CYCLES-1)
                        door_cnt <= 0;
                    else
                        door_cnt <= door_cnt + 1'b1;
                end
                default: ;
            endcase
        end
    end

    always @(*) state_o = state;

endmodule
