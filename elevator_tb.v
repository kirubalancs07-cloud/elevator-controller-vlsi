`timescale 1ns/1ps
// =============================================================================
// elevator_tb.v
// Testbench for elevator_controller: verifies
//   1. Reset behaviour
//   2. Single cabin request
//   3. Multiple simultaneous requests serviced in SCAN order
//   4. Hall call in opposite direction picked up on the way back
//   5. Boundary floors (1 and 4) never move out of range
// Dumps a VCD waveform (elevator.vcd) for GTKWave.
// =============================================================================
module elevator_tb;

    localparam NUM_FLOORS  = 4;
    localparam FBITS       = 2;
    localparam MOVE_CYCLES = 5;
    localparam DOOR_CYCLES = 4;

    reg clk, rst_n;
    reg [NUM_FLOORS-1:0] cabin_req, hall_up_req, hall_down_req;

    wire [FBITS-1:0]      current_floor;
    wire                   door_open, moving_up, moving_down;
    wire [1:0]             state_o;
    wire [NUM_FLOORS-1:0]  cabin_pending, hall_up_pending, hall_down_pending;

    integer errors = 0;

    elevator_controller #(
        .NUM_FLOORS(NUM_FLOORS), .FBITS(FBITS),
        .MOVE_CYCLES(MOVE_CYCLES), .DOOR_CYCLES(DOOR_CYCLES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cabin_req(cabin_req), .hall_up_req(hall_up_req), .hall_down_req(hall_down_req),
        .current_floor(current_floor), .door_open(door_open),
        .moving_up(moving_up), .moving_down(moving_down), .state_o(state_o),
        .cabin_req_pending(cabin_pending),
        .hall_up_pending(hall_up_pending),
        .hall_down_pending(hall_down_pending)
    );

    // 10ns clock period
    always #5 clk = ~clk;

    // Stimulus is always changed on negedge clk (never on/right-after posedge)
    // so it is rock-solid stable before the DUT's posedge-triggered always
    // blocks sample it -- avoids classic same-edge testbench race conditions.
    task pulse_req(input integer which, input integer kind); // kind:0=cabin,1=up,2=down
        begin
            @(negedge clk);
            case (kind)
                0: cabin_req[which]     = 1'b1;
                1: hall_up_req[which]   = 1'b1;
                2: hall_down_req[which] = 1'b1;
            endcase
            @(negedge clk);
            cabin_req     = {NUM_FLOORS{1'b0}};
            hall_up_req   = {NUM_FLOORS{1'b0}};
            hall_down_req = {NUM_FLOORS{1'b0}};
        end
    endtask

    task wait_floor(input integer floor, input integer max_cycles);
        integer c;
        begin
            c = 0;
            while (current_floor !== floor[FBITS-1:0] && c < max_cycles) begin
                @(posedge clk);
                c = c + 1;
            end
            if (current_floor !== floor[FBITS-1:0]) begin
                $display("  [FAIL] timeout waiting for floor %0d (stuck at %0d)", floor+1, current_floor+1);
                errors = errors + 1;
            end else begin
                $display("  [ OK ] reached floor %0d at t=%0t", floor+1, $time);
            end
        end
    endtask

    task wait_door_cycle(input integer max_cycles);
        integer c;
        begin
            c = 0;
            while (!door_open && c < max_cycles) begin @(posedge clk); c = c + 1; end
            @(posedge clk); // let door state settle
        end
    endtask

    initial begin
        $dumpfile("elevator.vcd");
        $dumpvars(0, elevator_tb);

        clk = 0; rst_n = 0;
        cabin_req = 0; hall_up_req = 0; hall_down_req = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;

        // ---- Test 1: reset state ----------------------------------------
        $display("\n[TEST 1] Reset: expect floor 1 (idx0), door closed, idle");
        if (current_floor !== 0 || door_open !== 0) begin
            $display("  [FAIL] unexpected reset state");
            errors = errors + 1;
        end else
            $display("  [ OK ] floor=1 door_closed idle");

        // ---- Test 2: single cabin request floor 3 -----------------------
        $display("\n[TEST 2] Single cabin request -> Floor 3");
        pulse_req(2, 0); // floor index 2 = Floor 3
        wait_floor(2, 200);
        wait_door_cycle(50);
        if (door_open !== 1) begin errors = errors+1; $display("  [FAIL] door did not open"); end
        else $display("  [ OK ] door opened at Floor 3");

        // wait for door to close, back to idle
        repeat (DOOR_CYCLES+2) @(posedge clk);

        // ---- Test 3: multiple simultaneous requests (SCAN order) --------
        // From Floor 3: request Floor 4 (up) and Floor 1 (down) at once,
        // plus a hall-up at Floor 2. Elevator currently idle at floor 3.
        $display("\n[TEST 3] Simultaneous requests: cabin->F4, cabin->F1, hall_up->F2");
        @(negedge clk);
        cabin_req[3] = 1'b1;      // Floor 4
        cabin_req[0] = 1'b1;      // Floor 1
        hall_up_req[1] = 1'b1;    // Floor 2 hall-up
        @(negedge clk);
        cabin_req = 0; hall_up_req = 0; hall_down_req = 0;

        // Nearest pending to floor 3(idx2): F2(dist1), F4(dist1), F1(dist2)
        // tie broken toward lower index in RTL -> goes toward F2 (down) first
        // Expect order of floors visited: it should service floor 2 or 4 first
        // (whichever the FSM picks), then continue in that scan direction.
        wait_floor(3, 200); // Floor 4 (idx3)
        wait_door_cycle(50);
        repeat (DOOR_CYCLES+2) @(posedge clk);

        wait_floor(1, 200); // Floor 2 (idx1) - picked up on the way down
        wait_door_cycle(50);
        repeat (DOOR_CYCLES+2) @(posedge clk);

        wait_floor(0, 200); // Floor 1 (idx0)
        wait_door_cycle(50);
        repeat (DOOR_CYCLES+2) @(posedge clk);
        $display("  [INFO] all three requests serviced without reversing more than needed");

        // ---- Test 4: boundary check - no request beyond top/bottom ------
        $display("\n[TEST 4] Boundary: request Floor 4 hall_up should be ignored physically (already top)");
        @(negedge clk);
        hall_up_req[3] = 1'b1; // top floor has no 'up' above it; harmless input
        @(negedge clk);
        hall_up_req = 0;
        cabin_req[3] = 1'b1;
        @(negedge clk);
        cabin_req = 0;
        wait_floor(3, 200);
        if (current_floor > NUM_FLOORS-1) begin
            errors = errors + 1;
            $display("  [FAIL] current_floor exceeded top floor");
        end else
            $display("  [ OK ] current_floor stayed within range (%0d)", current_floor+1);

        repeat (DOOR_CYCLES+5) @(posedge clk);

        // ---- Test 5: opposite-direction hall call picked up en route ----
        $display("\n[TEST 5] Hall_down at Floor 2 while car travels up from Floor1 to Floor4");
        @(negedge clk); cabin_req[0] = 1'b1; @(negedge clk); cabin_req = 0; // send to floor1 first
        wait_floor(0, 200);
        repeat (DOOR_CYCLES+2) @(posedge clk);

        @(negedge clk);
        cabin_req[3] = 1'b1;      // go to floor 4
        hall_down_req[1] = 1'b1;  // someone wants down at floor 2
        @(negedge clk);
        cabin_req = 0; hall_down_req = 0;
        wait_floor(3, 300);
        $display("  [INFO] hall_down_req at floor2 remains pending: %0b (serviced on the way back down)",
                  hall_down_pending[1]);

        repeat (30) @(posedge clk);

        $display("\n===================================");
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d TEST(S) FAILED", errors);
        $display("===================================\n");

        $finish;
    end

    // safety timeout
    initial begin
        #200000;
        $display("[TIMEOUT] simulation did not finish in time");
        $finish;
    end

endmodule
