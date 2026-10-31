`timescale 1ns/1ps
`default_nettype none
// One outstanding held-bus + toggle request/response crossing.
// Both clocks must share reset; independent one-sided resets are unsupported.
module yingxu_mjpeg_mailbox #(parameter WIDTH=58,STATUS=9)(
    input wire sclk,dclk,rst,
    input wire svalid,output wire sready,input wire [WIDTH-1:0] spayload,
    output reg sdone,output reg [STATUS-1:0] sstatus,
    output reg dvalid,input wire dready,output reg [WIDTH-1:0] dpayload,
    input wire ddone,input wire [STATUS-1:0] dstatus
);
    reg request,ack,sbusy,dwaiting,dcapture;
    reg [WIDTH-1:0] hold_payload;
    reg [STATUS-1:0] hold_status;
    (* async_reg="true" *) reg req_m,req_s,ack_m,ack_s;
    reg req_seen,ack_seen;
    assign sready=!sbusy;
    always @(posedge sclk) begin
        if(rst) begin request<=0;sbusy<=0;sdone<=0;sstatus<=0;hold_payload<=0;ack_m<=0;ack_s<=0;ack_seen<=0;end
        else begin
            ack_m<=ack;ack_s<=ack_m;sdone<=0;
            if(svalid && sready) begin hold_payload<=spayload;request<=~request;sbusy<=1;end
            if(ack_s!=ack_seen) begin ack_seen<=ack_s;sstatus<=hold_status;sdone<=1;sbusy<=0;end
        end
    end
    always @(posedge dclk) begin
        if(rst) begin req_m<=0;req_s<=0;req_seen<=0;ack<=0;dvalid<=0;dpayload<=0;dwaiting<=0;dcapture<=0;hold_status<=0;end
        else begin
            req_m<=request;req_s<=req_m;
            if(req_s!=req_seen && !dvalid && !dwaiting && !dcapture) begin req_seen<=req_s;dcapture<=1;end
            if(dcapture) begin dpayload<=hold_payload;dvalid<=1;dcapture<=0;end
            if(dvalid && dready) begin dvalid<=0;dwaiting<=1;end
            if(ddone && dwaiting) begin hold_status<=dstatus;ack<=~ack;dwaiting<=0;end
        end
    end
endmodule
`default_nettype wire
