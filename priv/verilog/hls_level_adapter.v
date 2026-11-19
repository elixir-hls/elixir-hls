// A level instance (elixir-hls EHLS.Level): the arguments the CPU writes, a kernel behind its
// stream / state adapter, and the result held.
//
// The CPU writes the arguments' 32-bit words (wr, wr_index, wr_data), which fires nothing, then the
// start write (start). In that clock all the words are copied into the element to compute, so words
// half written are never taken, and `issued` counts the start. The kernel gets the element when it
// is free; a start while it computes leaves the element to take next, the latest one (only the latest
// counts: an element replaced before it was taken is never computed). When the result comes, it is
// held in `result`, with the count of its start in `done`, both changed in the same clock; the CPU
// reads them together (peek) and waits until `done` reaches the count of its own start.
//
// `enable` (the instance's bit of pipe_enable): while it is low, starts are ignored and the result
// stays the last one; when it rises, the result goes back to INIT. A computation under way when it
// fell gives nothing. Every value is W bits (the kernel's ports, 32 or 64), NI of them in, NY out.
module hls_level_adapter #(
    parameter W = 32,
    parameter NI = 1,
    parameter NY = 1,
    parameter [W*NY-1:0] INIT = 0
) (
    input  wire            clk,
    input  wire            rst,
    input  wire            enable,
    // the CPU's writes
    input  wire            wr,
    input  wire [7:0]      wr_index,
    input  wire [31:0]     wr_data,
    input  wire            start,
    output reg  [31:0]     issued,
    // the result and the count of the start it is for
    output reg  [W*NY-1:0] result,
    output reg  [31:0]     done,
    // the kernel's stream
    output reg             s_valid,
    input  wire            s_ready,
    output reg  [W*NI-1:0] s_data,
    input  wire            m_valid,
    output wire            m_ready,
    input  wire [W*NY-1:0] m_data
);
    localparam NW = W * NI / 32;      // 32-bit words of the arguments

    reg [W*NI-1:0] words;             // as the CPU writes them
    reg [W*NI-1:0] elem;              // taken at the start write, the next to compute
    reg            pend;              // elem not given to the kernel yet
    reg [31:0]     pend_count, offer_count;
    reg            busy;              // the kernel took s_data, its result not back yet
    reg            stale;             // what the kernel computes now is from before a stop
    reg            enable_d;

    assign m_ready = 1'b1;

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            words <= 0; elem <= 0; pend <= 0; pend_count <= 0; offer_count <= 0;
            s_valid <= 0; s_data <= 0; busy <= 0; stale <= 0; enable_d <= 0;
            issued <= 0; done <= 0; result <= INIT;
        end else begin
            enable_d <= enable;
            if (wr)
                for (i = 0; i < NW; i = i + 1)
                    if (wr_index == i) words[32 * i +: 32] <= wr_data;

            // the element to the kernel, once it is free (s_data stays as it is while offered)
            if (s_valid && s_ready) begin
                s_valid <= 0;
                busy <= 1;
            end else if (!s_valid && !busy && pend && enable) begin
                s_valid <= 1;
                s_data <= elem;
                offer_count <= pend_count;
                pend <= 0;
            end

            if (m_valid) begin
                busy <= 0;
                stale <= 0;
                if (!stale && enable) begin
                    result <= m_data;
                    done <= offer_count;
                end
            end

            if (!enable) begin
                pend <= 0;
                done <= issued;
                // still computing after this clock (a result coming now ends what was in flight)
                if (s_valid || (busy && !m_valid)) stale <= 1;
            end else if (!enable_d) begin
                result <= INIT;
            end

            // after the rest: a start in the same clock as the element went to the kernel stays pending
            if (start && enable) begin
                elem <= words;
                pend <= 1;
                pend_count <= issued + 1;
                issued <= issued + 1;
            end
        end
    end
endmodule
