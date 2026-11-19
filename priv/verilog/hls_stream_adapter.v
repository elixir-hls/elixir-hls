// Adapts a CIRCT `hlstool --dynamic-hw` kernel `fn(x) -> y` to valid/ready streams (the
// RTL boundary's: a word moves in a clock where valid and ready are both 1): one input
// word per invocation, results in order.
//
// The kernel has two inputs per invocation: in0 (data) and in1 (0-bit start token), each with
// its own valid/ready, and may accept them in different cycles. So each input word is handed
// to both with an eager fork: remember which side already took it, and complete the stream
// transfer once both have. Outputs: out0 (result) goes to the stream; out1 (0-bit done token)
// is always accepted and dropped. `engaged`: the kernel has taken one of the two, so the word must
// stay valid until it has both.
module hls_stream_adapter #(
    parameter IW = 32,
    parameter OW = 32
) (
    input  wire          clk,
    input  wire          rst,
    output wire          engaged,
    // input stream
    input  wire          s_valid,
    output wire          s_ready,
    input  wire [IW-1:0] s_data,
    // output stream
    output wire          m_valid,
    input  wire          m_ready,
    output wire [OW-1:0] m_data,
    // kernel side
    output wire [IW-1:0] k_in0,
    output wire          k_in0_valid,
    input  wire          k_in0_ready,
    output wire          k_in1_valid,
    input  wire          k_in1_ready,
    input  wire [OW-1:0] k_out0,
    input  wire          k_out0_valid,
    output wire          k_out0_ready,
    input  wire          k_out1_valid,
    output wire          k_out1_ready
);
    reg taken0, taken1;
    wire take0 = s_valid & ~taken0 & k_in0_ready;
    wire take1 = s_valid & ~taken1 & k_in1_ready;
    wire both  = (taken0 | take0) & (taken1 | take1);

    assign k_in0       = s_data;
    assign k_in0_valid = s_valid & ~taken0;
    assign k_in1_valid = s_valid & ~taken1;
    assign s_ready     = both;
    assign engaged     = taken0 | taken1;

    always @(posedge clk) begin
        if (rst | (s_valid & both)) begin
            taken0 <= 1'b0;
            taken1 <= 1'b0;
        end else begin
            taken0 <= taken0 | take0;
            taken1 <= taken1 | take1;
        end
    end

    assign m_data       = k_out0;
    assign m_valid      = k_out0_valid;
    assign k_out0_ready = m_ready;
    assign k_out1_ready = 1'b1;
endmodule
