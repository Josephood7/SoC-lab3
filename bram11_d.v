// bram behavior code (can't be synthesis)
// 11 words
`timescale 1ns / 10ps
module bram11_d 
(
    CLK,
    WE,
    EN,
    Di,
    Do,
    A
);

    input   wire            CLK;
    input   wire    [3:0]   WE;
    input   wire            EN;
    input   wire    [31:0]  Di;
    output  wire     [31:0]  Do;
    input   wire    [11:0]   A; 

    //  11 words
	reg [31:0] RAM[0:10];
    reg [11:0] r_A;
    
//    initial begin
//        for (integer i=0 ;i<12 ;i=i+1 ) begin
//            RAM[i] = 32'd0;
//        end
//    end
    
    always @(posedge CLK) begin
        r_A <= A;
    end
    
    initial begin
    RAM [0] <= 32'b0;
    RAM [1] <= 32'b0;
    RAM [2] <= 32'b0;
    RAM [3] <= 32'b0;
    RAM [4] <= 32'b0;
    RAM [5] <= 32'b0;
    RAM [6] <= 32'b0;
    RAM [7] <= 32'b0;
    RAM [8] <= 32'b0;
    RAM [9] <= 32'b0;
    RAM [10] <= 32'b0;
    end
        
    assign Do = {32{EN}} & RAM[r_A>>2];    // read

    reg [31:0] Temp_D;
    always @(posedge CLK) begin        
        if(EN) begin
            if(WE[0]) RAM[A>>2][7:0] <= Di[7:0];
            if(WE[1]) RAM[A>>2][15:8] <= Di[15:8];
            if(WE[2]) RAM[A>>2][23:16] <= Di[23:16];
            if(WE[3]) RAM[A>>2][31:24] <= Di[31:24];          
        end
    end

endmodule
