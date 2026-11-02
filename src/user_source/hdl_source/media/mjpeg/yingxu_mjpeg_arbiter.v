`timescale 1ns/1ps
`default_nettype none
// Strict priority only at transaction boundaries: 0 display, 1 decode write,
// 2 prefetch/other. Physical refresh is implemented above this service layer.
module yingxu_mjpeg_arbiter(
    input wire clk,rst,
    input wire [2:0] cvalid,output reg [2:0] cready,
    input wire [2:0] cwrite,input wire [62:0] caddr,input wire [11:0] cwords,
    input wire [2:0] cwvalid,output reg [2:0] cwready,input wire [95:0] cwdata,input wire [2:0] cwlast,
    output reg [2:0] crvalid,input wire [2:0] crready,output wire [31:0] crdata,output wire crlast,
    output reg [2:0] cdone,cerror,
    output wire mvalid,input wire mready,output reg mwrite,output reg [20:0] maddr,output reg [3:0] mwords,
    output reg mwvalid,input wire mwready,output reg [31:0] mwdata,output reg mwlast,
    input wire mrvalid,output reg mrready,input wire [31:0] mrdata,input wire mrlast,
    output wire [2:0] debug_owner,
    input wire mdone,merror
);
    reg active,pending;reg [1:0] owner;
    assign debug_owner={active,owner};
    // D9: register the entire command at each hop. VALID no longer travels
    // combinationally through both priority selectors to the receiver. The
    // selected payload stays stable until the actual downstream acceptance.
    assign mvalid=pending;
    assign crdata=mrdata;assign crlast=mrlast;
    always @* begin
        cready=0;cwready=0;crvalid=0;cdone=0;cerror=0;
        mwvalid=0;mwdata=0;mwlast=0;mrready=0;
        // Constant slices/indices keep the legacy TD reader's mux structure
        // explicit, for both command acknowledgement and transaction routing.
        case(owner)
            0:begin
                if(pending)cready[0]=mready;
                if(active)begin cwready[0]=mwready;crvalid[0]=mrvalid;cdone[0]=mdone;cerror[0]=merror;
                    mwvalid=cwvalid[0];mwdata=cwdata[31:0];mwlast=cwlast[0];mrready=crready[0];end
            end
            1:begin
                if(pending)cready[1]=mready;
                if(active)begin cwready[1]=mwready;crvalid[1]=mrvalid;cdone[1]=mdone;cerror[1]=merror;
                    mwvalid=cwvalid[1];mwdata=cwdata[63:32];mwlast=cwlast[1];mrready=crready[1];end
            end
            default:begin
                if(pending)cready[2]=mready;
                if(active)begin cwready[2]=mwready;crvalid[2]=mrvalid;cdone[2]=mdone;cerror[2]=merror;
                    mwvalid=cwvalid[2];mwdata=cwdata[95:64];mwlast=cwlast[2];mrready=crready[2];end
            end
        endcase
    end
    always @(posedge clk) begin
        if(rst) begin active<=0;owner<=0;pending<=0;mwrite<=0;maddr<=0;mwords<=0;end
        else begin
            if(!active && !pending)begin
                if(cvalid[0])begin pending<=1;owner<=0;mwrite<=cwrite[0];maddr<=caddr[20:0];mwords<=cwords[3:0];end
                else if(cvalid[1])begin pending<=1;owner<=1;mwrite<=cwrite[1];maddr<=caddr[41:21];mwords<=cwords[7:4];end
                else if(cvalid[2])begin pending<=1;owner<=2;mwrite<=cwrite[2];maddr<=caddr[62:42];mwords<=cwords[11:8];end
            end
            if(pending && mready)begin active<=1;pending<=0;end
            if(active && (mdone || merror)) active<=0;
        end
    end
endmodule
`default_nettype wire
