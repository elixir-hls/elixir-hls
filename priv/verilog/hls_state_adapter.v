// Runs a stateful CIRCT `hlstool --dynamic-hw` kernel over a valid/ready stream (the RTL
// boundary's: a word moves in a clock where valid and ready are both 1). The kernel is f(x_1..x_NI, s_1..s_NS) -> (y_1..y_NY, s_1'..s_NS'):
// its inputs are in0..in(NI-1) = x (NI values, the fields of one stream element), then the
// state, then the 0-bit start token; its outputs out0.. = y (NY values), then the next state,
// then the 0-bit done token. Each port has its own valid/ready and the kernel may take or
// give them in different cycles.
//
// One element at a time, in one clock on the stream: its fields and the state registers are
// offered to every input port (each until taken) while the outputs are taken as they come (the
// next state into `next`; y through the output stream, and with several values kept until all have
// come, as one element); the kernel may need its outputs taken before it takes all its inputs.
// When every input was taken and every output received, the element is consumed from the input
// stream and the state updated. `restart` (a pulse, between elements) loads INIT into the state.
// `engaged`: the kernel has taken part of an element, which must be finished, kept valid: the kernel
// gives its outputs for what it has taken whatever comes next.
//
// EMIT = 1 (a kernel returning {[y], s} / {[], s}): out0 is a flag, then y and the next state;
// the y words go to the output stream only when the flag is 1 (otherwise they are taken and
// dropped), so an element may produce no output (rate changes).
//
// SHARED = 1 (an agent: one state for several functions, EHLS `agent` / `get_and_update`): the state
// is not kept here but comes in on state_in, and when an element is done its next state goes out on
// state_next with state_we high for that clock; state_out is state_in. The agent lets one adapter at a
// time take an element (it gates s_valid), so the state does not change under an element.
//
// Kernel ports are packed: k_in_data = {s_NS, .., s_1, x_NI, .., x_1}, k_in_valid[i] =
// in<i>_valid (bit NI+NS is the start token); k_out_data = {s_NS', .., s_1', y_NY, .., y_1[,
// flag]}, k_out_valid[i] = out<i>_valid (the last bit is the done token).
module hls_state_adapter #(
    // integers: generators may pass sized constants (1'd1), which would make the sums of
    // these parameters 1- or 2-bit wide
    parameter integer W = 32,           // bits per value: the kernel's ports
    parameter integer NS = 1,           // number of state values
    parameter [NS*W-1:0] INIT = 0,      // initial state {s_NS, .., s_1}
    parameter integer EMIT = 0,         // 1: out0 is an emit flag (see above)
    parameter integer NI = 1,           // values per input element
    parameter integer NY = 1,           // values per output element
    parameter integer SHARED = 0        // 1: the state is outside (see above)
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               restart,
    output wire               engaged,
    // input stream
    input  wire               s_valid,
    output wire               s_ready,
    input  wire [NI*W-1:0]   s_data,
    // output stream
    output wire               m_valid,
    input  wire               m_ready,
    output wire [NY*W-1:0]   m_data,
    // kernel
    output wire [(NI+NS)*W-1:0] k_in_data,
    output wire [NI+NS:0]        k_in_valid,
    input  wire [NI+NS:0]        k_in_ready,
    input  wire [(EMIT+NY+NS)*W-1:0] k_out_data,
    input  wire [EMIT+NY+NS:0]        k_out_valid,
    output wire [EMIT+NY+NS:0]        k_out_ready,
    // the current state (for the CPU to look at)
    output wire [NS*W-1:0]     state_out,
    // SHARED: the state from outside, the next one when an element is done
    input  wire [NS*W-1:0]     state_in,
    output wire                state_we,
    output wire [NS*W-1:0]     state_next
);
    localparam NIN = NI + NS;                   // data inputs
    localparam [NIN:0] ALL = {(NIN+1){1'b1}};
    localparam NO = EMIT + NY + NS;             // data outputs
    localparam [NO:0] ALL_OUT = {(NO+1){1'b1}};
    localparam Y = EMIT;                        // index of y_1 among the outputs

    reg  [NS*W-1:0] state;
    wire [NS*W-1:0] current = SHARED ? state_in : state;
    assign state_out = current;
    reg  [NS*W-1:0] next;      // next-state words received so far
    reg  [NIN:0]     in_done;   // inputs taken for the current frame
    reg  [NO:0]      out_done;  // outputs received for the current frame
    reg              flag_r;    // the emit flag, once received

    wire             f_valid = s_valid;
    wire [NI*W-1:0] frame = s_data;

    assign k_in_data  = {current, frame};
    assign k_in_valid = f_valid ? ~in_done : {(NIN+1){1'b0}};
    wire   [NIN:0] in_fire = k_in_valid & k_in_ready;

    // y goes to the output stream when it accepts (EMIT: once the flag says so; dropped when it says
    // not), the rest is taken as it comes
    wire   flag_known = EMIT == 0 || out_done[0] || k_out_valid[0];
    wire   flag = EMIT == 0 || (out_done[0] ? flag_r : k_out_data[0]);
    wire   [NO:0] ready_mask;
    wire   [NO:0] out_fire = k_out_valid & k_out_ready;
    wire   m_sent;
    wire   complete;
    genvar j;
    generate
        if (NY == 1) begin : g_one
            for (j = 0; j <= NO; j = j + 1) begin : g_ready
                if (j == Y)
                    assign ready_mask[j] = flag_known && (flag ? m_ready : 1'b1);
                else
                    assign ready_mask[j] = 1'b1;
            end
            assign m_valid = flag_known && flag && k_out_valid[Y] && !out_done[Y];
            assign m_data  = k_out_data[Y*W +: W];
            assign m_sent  = 1'b1;
        end else begin : g_several
            // kept as they come, one output of the kernel may not wait for another
            reg [NY*W-1:0] ybuf;
            reg             sent;
            wire [NY-1:0]   yv = k_out_valid >> Y;
            wire [NY-1:0]   yd = out_done >> Y;
            wire [NY-1:0]   yf = yv & ~yd;
            wire [NY*W-1:0] yk = k_out_data >> (Y*W);
            wire            y_all = (yd | yf) == {NY{1'b1}};
            assign ready_mask = {(NO+1){1'b1}};
            assign m_valid = flag_known && flag && y_all && !sent;
            genvar b;
            for (b = 0; b < NY; b = b + 1) begin : g_y
                assign m_data[b*W +: W] = yd[b] ? ybuf[b*W +: W] : yk[b*W +: W];
                always @(posedge clk) if (yf[b]) ybuf[b*W +: W] <= yk[b*W +: W];
            end
            assign m_sent = !(flag_known && flag) ? flag_known : (sent || m_ready);
            always @(posedge clk)
                if (rst || complete) sent <= 1'b0;
                else if (m_valid && m_ready) sent <= 1'b1;
        end
    endgenerate
    assign k_out_ready = ~out_done & ready_mask;

    assign complete = f_valid && ((in_done | in_fire) == ALL) && ((out_done | out_fire) == ALL_OUT) && m_sent;
    assign s_ready = complete;
    assign state_we = SHARED != 0 && complete;
    assign engaged = in_done != 0 || out_done != 0;
    wire   idle = !s_valid && !engaged;

    // the next state, including words arriving in this very cycle
    wire [NS*W-1:0] next_now;
    assign state_next = next_now;
    genvar i;
    generate
        for (i = 0; i < NS; i = i + 1) begin : g_next
            assign next_now[i*W +: W] = out_fire[i+Y+NY] ? k_out_data[(i+Y+NY)*W +: W] : next[i*W +: W];
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            state    <= INIT;
            next     <= INIT;
            in_done  <= {(NIN+1){1'b0}};
            out_done <= {(NO+1){1'b0}};
            flag_r   <= 1'b0;
        end else if (complete) begin
            state    <= next_now;
            in_done  <= {(NIN+1){1'b0}};
            out_done <= {(NO+1){1'b0}};
        end else begin
            if (restart && idle)
                state <= INIT;
            next     <= next_now;
            in_done  <= in_done | in_fire;
            out_done <= out_done | out_fire;
            if (EMIT && out_fire[0])
                flag_r <= k_out_data[0];
        end
    end
endmodule
