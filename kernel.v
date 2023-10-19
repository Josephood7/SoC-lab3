`timescale 1ns / 10ps
module kernel
(   input [31:0] Xn,
    output reg [31:0] Yn,
    input   CLK,
    input   reset,
    input   [31:0] tap,
    output  finish  
);
    localparam DONE = 1;
    localparam RUNNING = 0;
    reg [3:0] cnt;    
    
    always @(posedge CLK or negedge reset) begin
        if (~reset) begin
            cnt <= 4'b0000;
            Yn <= 68'd0;
        end else begin
            if (finish) begin
                Yn <= (Xn * tap);        // the start of the next cycle
                cnt <= 4'b0000;
            end else begin
                Yn <= Yn + (Xn * tap);
                cnt <= cnt + 1;         // normally do Yn = Yn + (Xn * tap)
            end
        end
    end
    assign finish = (cnt == 4'b1010)? (DONE):(RUNNING);     // 1 cycle == 0~10
endmodule