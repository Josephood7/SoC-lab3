`include "kernel.v"
`timescale 1ns / 10ps
module fir 
#(  parameter pADDR_WIDTH = 12,
    parameter pDATA_WIDTH = 32,
    parameter Tape_Num    = 11,
    parameter IDLE        =  0,    
    parameter BUSY        =  2'b10,      
    parameter HALT        =  0,
    parameter ADDRESS_RECEIVED = 1
)
(
    // AXI4-Lite Write (axilite) 
    output  reg                     awready,
    output  reg                     wready,
    input   wire                     awvalid,
    input   wire                     wvalid,
    input   wire [(pADDR_WIDTH-1):0] awaddr,
    input   wire [(pDATA_WIDTH-1):0] wdata,
    // AXI-4-Lite Read (axilite)
    output  reg                     arready,
    input   wire                     rready,
    input   wire                     arvalid,
    output  reg                     rvalid,
    input   wire [(pADDR_WIDTH-1):0] araddr,
    output  reg [(pDATA_WIDTH-1):0] rdata, 

    // Stream Slave (axis)
    input   wire                     ss_tvalid, 
    input   wire [(pDATA_WIDTH-1):0] ss_tdata, 
    input   wire                     ss_tlast, 
    output  reg                     ss_tready, 
    // Stream Master (axis)
    output  reg                     sm_tvalid, 
    output  reg [(pDATA_WIDTH-1):0] sm_tdata, 
    output  reg                     sm_tlast, 
    input   wire                     sm_tready,
    
    // bram for tap RAM
    output  reg [3:0]               tap_WE,
    output  reg                     tap_EN,
    output  reg [(pDATA_WIDTH-1):0] tap_Di,
    output  reg [(pADDR_WIDTH-1):0] tap_A,
    input   wire [(pDATA_WIDTH-1):0] tap_Do,

    // bram for data RAM
    output  reg [3:0]               data_WE,
    output  reg                     data_EN,
    output  reg [(pDATA_WIDTH-1):0] data_Di,
    output  reg [(pADDR_WIDTH-1):0] data_A,
    input   wire [(pDATA_WIDTH-1):0] data_Do,

    input   wire                     axis_clk,
    input   wire                     axis_rst_n
);
        
    // Declaration
    reg [3:0] tap_cnt, data_cnt;
    reg ap_start, ap_idle, ap_done;
    reg [1:0] last;
    reg [2:0] fir_state;
    integer fir_next_state;
    reg w_state;
    integer w_next_state;
    reg r_state;
    integer r_next_state;
    reg [1:0] w_address_reg;
    reg [1:0] r_address_reg;
    reg [pDATA_WIDTH - 1:0] data_length;
    reg [1:0] tap_ctrl;     
    reg fir_reset;
    wire fir_done; 
    wire [pDATA_WIDTH - 1:0] yn_wire;
    reg [pDATA_WIDTH - 1:0] yn_reg;
    
    // Initialization    
    initial begin
        ap_done = 0;
        ap_start = 0;
        ap_idle = 1;
        last = 2'b00;
    end
    
    // RAM for tap
    bram11_d tap_RAM (
        .CLK(axis_clk),
        .WE(tap_WE),
        .EN(tap_EN),
        .Di(tap_Di),
        .A(tap_A),
        .Do(tap_Do)
    );

    // RAM for data: choose bram11 or bram12
    bram11_d data_RAM(
        .CLK(axis_clk),
        .WE(data_WE),
        .EN(data_EN),
        .Di(data_Di),
        .A(data_A),
        .Do(data_Do)
    );
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        // ap_idle
        ap_idle <= (!axis_rst_n)? (1'b1):((ap_start)? (1'b0):((fir_state == IDLE)? (1'b1):(ap_idle)));
        
        // FSM
        fir_state <= (!axis_rst_n)? (IDLE):(fir_next_state);
        
        // axilite FSM
        w_state <= (!axis_rst_n)? (HALT):(w_next_state);    // write
        r_state <= (!axis_rst_n)? (HALT):(r_next_state);    // read
        
        // ram count
        if (!axis_rst_n) begin
            tap_cnt <= 0;
            data_cnt <= 0;
        end else begin
            if (tap_EN) begin
                tap_cnt <= (tap_cnt == 4'b1010)? (4'b0000):(tap_cnt + 1'b1);
            end
            if (data_EN) begin
                data_cnt <= (tap_cnt == 4'b1010)? (data_cnt):((data_cnt == 4'b1010)? (4'b0000):(data_cnt + 1'b1));
                data_EN <= (tap_cnt == 4'b1010)? (1'b1):(1'b0);
            end
        end
        
        // Configuration Register Address Map (Write / Read)
        if (!axis_rst_n) begin
            w_address_reg <= 2'b11;
            r_address_reg <= 2'b11;
        end else begin
            if (awvalid && awready) begin
                if (awaddr == 12'h00) begin                                 // 0x00
                    w_address_reg <= 2'b00;
                end
                else if (awaddr >= 12'h10 && awaddr <= 12'h14) begin        // 0x10 ~ 0x14
                    w_address_reg <= 2'b01;
                end
                else if (awaddr >= 12'h20 && awaddr <= 12'hFF) begin        //0x20 ~ 0xFF
                    w_address_reg <= 2'b10;
                end else begin
                    w_address_reg <= 2'b11;
                end
            end
            if (arvalid && awready) begin
                if (araddr == 12'h00) begin
                    r_address_reg <= 2'b00;
                end
                else if (araddr >= 12'h10 && araddr <= 12'h14) begin
                    r_address_reg <= 2'b01;
                end
                else if (araddr >= 12'h20 && araddr <= 12'hFF) begin
                    r_address_reg <= 2'b10;
                end else begin
                    r_address_reg <= 2'b11;
                end
            end
        end
    end
             
    always @(*) begin
        // FIR state
        case (fir_state)
            IDLE: begin
                fir_next_state = (ap_start)? (BUSY):(IDLE);
            end
            BUSY: begin
                fir_next_state = (ap_done && rready && rvalid && arvalid)? (IDLE):(BUSY);
            end 
            default: begin
                fir_next_state = IDLE;
            end
        endcase
        
        if (fir_state == IDLE) begin
            case (w_state)
                HALT: begin                
                    w_next_state = (awvalid)? (ADDRESS_RECEIVED):(HALT);   
                    awready = 1'b1;
                    wready = 1'b0;
                end
                ADDRESS_RECEIVED: begin
                    w_next_state = (wvalid)? (HALT):(ADDRESS_RECEIVED);         // FIR is Slave
                    awready = 1'b0;
                    wready = 1'b1;
                end
                default: begin
                    w_next_state = HALT;
                    awready = 1'b1;
                    wready = 1'b0;
                end
            endcase
        end else begin
            w_next_state = HALT;
        end    
        
        // Read state
        case(r_state)
            HALT: begin
                r_next_state = (arvalid)? (ADDRESS_RECEIVED):(HALT);
                arready = 1'b1;
                rvalid = 1'b0;
            end
            ADDRESS_RECEIVED: begin
                r_next_state = (rready)? (HALT):(ADDRESS_RECEIVED);
                arready = 1'b0;
                rvalid = 1'b1;
                case(w_address_reg)
                    2'b00 : rdata = {29'b0, ap_idle, ap_done, ap_start};
                    2'b01 : rdata = data_length;
                    2'b10 : rdata = tap_Do;
                    2'b11 : rdata = {29'b0, ap_idle, ap_done, ap_start};
                    default: rdata = {29'b0, ap_idle, ap_done, ap_start};
                endcase
            end
            default: begin
                r_next_state = HALT;
                arready = 1'b1;
                rvalid = 1'b0;
            end
        endcase
        
        // ram pointer
        tap_A = tap_cnt << 2 ;
        data_A = data_cnt << 2 ;               
    end
    
    // Data Store (Write)
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n) begin
            data_length <= 32'b0;
        end
    end
    
    always @(*) begin
        if (fir_state == IDLE) begin
            if (wvalid && wready) begin
                case (w_address_reg)
                    2'b00: begin
                        if (wdata[0] == 1'd1) begin     // 0x00 - [0]
                            ap_start = 1;
                        end else begin
                            ap_start = 0;
                        end
                        if (wdata[1] == 1'd1) begin     // 0x00 - [1]
                            ap_done = 1;
                        end else begin
                            ap_done = 0;
                        end
                        if (wdata[2] == 1'd1) begin     // 0x00 - [2]
                            ap_idle = 1;
                        end else begin
                            ap_idle = 0;
                        end
                    end
                    2'b01: begin
                        data_length = wdata;            // 0x10 ~ 0x14
                    end
                    2'b10: begin                        //0x20 ~ 0xFF
                        tap_Di = wdata;
                    end
                endcase
            end
        end else begin
            ap_start = (ap_start && ss_tvalid && ss_tready)? (IDLE):(ap_start);
        end
    end
    
    // Tap control
    always @(*) begin    
        tap_EN = (tap_ctrl[1] || tap_ctrl[0])? (1'b1):(1'b0);
        tap_WE = (tap_ctrl[1])? (4'b1111):(4'b0);
    end
        
    always @(*) begin
        if (fir_state == IDLE) begin                // write : 10,      read : 01,      idle : 00
            if (w_address_reg == 2'b10 && r_address_reg == 2'd2) begin
                tap_ctrl = (wvalid && wready)? (2'b10):((rvalid && rready)? (2'b01):(2'b00));
            end else if (r_address_reg == 2'b10) begin
                tap_ctrl = (rvalid && rready)? (2'b01):(2'b00);
            end else if (w_address_reg == 2'b10) begin
                tap_ctrl = (wvalid && wready)? (2'b10):(2'b00);
            end else begin
                tap_ctrl = 2'b00;
            end
        end else if (fir_state == BUSY) begin
            tap_ctrl = 2'b01;
        end else begin
            tap_ctrl = 2'b00;
        end
    end
    
    // axis  
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n) begin
            data_WE <= 4'b0000;
            data_EN <= 1'b0;
            fir_reset <= 1'b0;
            ss_tready <= 1'b0;            
        end else begin
            if (ap_start) begin
                data_WE <= 4'b1111;
                data_EN <= 1'b1;
                fir_reset <= 1'b0;
                ss_tready <= 1'b1;
                data_Di <= ss_tdata;        // Stream into data RAM
                data_cnt <= 1'b0;
            end else if (ap_done) begin
                data_EN <= 1'b0;
                fir_reset <= 1'b0;
                ss_tready <= 1'b0;
            end else if (fir_state == BUSY) begin
                if (tap_cnt == 4'b1010) begin       // Only when the 11 wide ram is full can fir reads it
                    data_WE <= 4'b1111;
                end else begin
                    data_WE <= 4'b0;
                end
                data_EN <= 1'b1;                    // Enable reading
                fir_reset <= 1'b1;                  // In operation
                ss_tready <= (tap_cnt == 4'b1001)? (1'b1):(1'b0);   // tlast
                if (ss_tvalid && ss_tready) begin   // Streaming data into data RAM
                    data_Di <= ss_tdata;
                end
            end else begin 
                data_EN <= 1'b0;
                fir_reset <= 1'b0;
                ss_tready <= 1'b0;
            end
        end
    end
    
    // Kernel Calculation
    kernel fir_kernel ( .Xn(data_Do), .Yn(yn_wire), .CLK(axis_clk), .reset(fir_reset), .tap(tap_Do), .finish(fir_done));
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        sm_tdata <= (!axis_rst_n)? (32'b0):((fir_done)? (yn_wire):(sm_tdata));
    end
    
    // tlast
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n) begin
            sm_tdata <= 32'b0;
            sm_tlast <= 1'b0;
            sm_tvalid <= 1'b0;
        end else begin
            if (ss_tlast && fir_state == BUSY) begin    // tlast in signaled
                last <= 2'b01;
                sm_tvalid <= 1'b0;
            end
            if (fir_done) begin                         // set sm_tvalid
                if (last == 2'b01) begin    // the last data
                    last <= 2'b10;          
                    //sm_tdata <= yn_reg;         // fir completed -> start outputing
                    sm_tvalid <= 1'b1;      // valid to output
                    sm_tlast <= 1'b1;
                end else if (last == 2'b10) begin
                    last <= 2'b00;
                    //sm_tdata <= yn_reg;
                    sm_tvalid <= 1'b1;
                    sm_tlast <= 1'b1;       // the last data transmission
                end else begin
                    //sm_tdata <= yn_reg;
                    sm_tvalid <= 1'b1;
                end
            end else if (sm_tready && sm_tvalid) begin  // after transmission reset sm_tvalid to stop transmission
                sm_tvalid <= 1'b0;
                sm_tlast <= 1'b0;
            end else begin
                sm_tvalid <= 1'b0;
                sm_tlast <= 1'b0;
            end
            
            // When FIR done, ap_done = 1
            ap_done <= (sm_tvalid && sm_tready && sm_tlast)? (1):((r_address_reg == 2'b00 && arvalid && rvalid && rready)? (0):(ap_done));
            ap_idle <= (sm_tvalid && sm_tready && sm_tlast)? (1):((r_address_reg == 2'b00 && arvalid && rvalid && rready)? (0):(ap_idle));
        end
    end       
endmodule