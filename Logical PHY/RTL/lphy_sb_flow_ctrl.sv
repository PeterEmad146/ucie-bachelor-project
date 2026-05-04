`timescale 1ns / 1ps

module lphy_sb_flow_ctrl #(
    parameter int LOCAL_CREDITS_INIT = 32   // Maximum 32 local credits per spec
)(
    input logic clk,
    input logic rst_n,
    input logic rdi_in_reset,   // High when RDI state is Reset
    
    // Request from Sideband Controller/Encoder
    input logic req_valid,
    input logic is_reg_req,     // High for Register Access Request
    input logic is_reg_cpl,     // HIgh for Register Access Completion
    input logic is_msg,         // High for Messages (with or without data)
    
    // Authorization Output
    output logic tx_allowed,    // High if credits are available to send the requests
    // Credit Return Inputs
    input logic local_crd_ret,   // From local RDI (pl_cfg_crd)
    input logic remote_crd_ret  // Extracted from received sideband header 'Cr' bit
);

    // Credit Counters
    // Local RDI credits (Max 32)
    logic [5:0] local_crd_count;
    
    // Remote E2E credits for Register Accesses (Initialized to 4)
    logic [2:0] remote_crd_count;
    
    // Credit Consumption logic
    logic consume_local;
    logic consume_remote;
    
    always_comb begin
        consume_local = 1'b0;
        consume_remote = 1'b0;
        
        if(req_valid && tx_allowed) begin
            // The Transmitter must not check for credits before sending Register Access Completions
            if (is_reg_req) begin
                consume_local = 1'b1;
                consume_remote = 1'b1;
            end else if (is_msg) begin
                consume_local = 1'b1;
            end
        end
    end
    
    // Authorization logic
    always_comb begin
        if (is_reg_cpl) begin
            // Completions must always sink and do not require credits
            tx_allowed = 1'b1;
        end else if (is_reg_req) begin
            // Needs both local RDI space and Remote E2E space
            tx_allowed = (local_crd_count > 0) && (remote_crd_count > 0);
        end else if (is_msg) begin
            // Only needs local RDI space
            tx_allowed = (local_crd_count > 0);
        end else begin
            tx_allowed = 1'b0;
        end
    end
    
    // Sequential Counter Updates
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            local_crd_count <= LOCAL_CREDITS_INIT[5:0];
            remote_crd_count <= 3'd4;
        end else if (rdi_in_reset) begin
            // The Adapter credit counters for register access request transmission
            // are initialized to 4 whenever RDI is in Reset state.
            local_crd_count <= LOCAL_CREDITS_INIT[5:0];
            remote_crd_count <= 3'd4;
        end else begin
            // Local Credit Update
            if (consume_local && !local_crd_ret)
                local_crd_count <= local_crd_count - 1'b1;
            else if (!consume_local && local_crd_ret && (local_crd_count < LOCAL_CREDITS_INIT[5:0]))
                local_crd_count <= local_crd_count + 1'b1;
            
            // Remote Credit Update
            if (consume_remote && !remote_crd_ret) 
                remote_crd_count <= remote_crd_count - 1'b1;
            else if (!consume_remote && remote_crd_ret && (remote_crd_count < 3'd4))
                remote_crd_count <= remote_crd_count + 1'b1;
        end
    end

endmodule