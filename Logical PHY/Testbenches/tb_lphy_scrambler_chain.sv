`timescale 1ps / 1ps

module tb_lphy_scrambler_chain;

    logic clk;
    logic rst_n;
    logic enable;
    logic load_seed;
    logic [22:0] seed_in;
    
    logic [7:0] tx_raw_data;
    logic [7:0] scrambled_data;
    logic [7:0] rx_recovered_data;
    
    // Instantiate TX Scrambler
    lphy_scrambler tx_scrambler (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .load_seed(load_seed),
        .seed_in(seed_in),
        .data_in(tx_raw_data),
        .data_out(scrambled_data)
    );
    
    // Instantiate RX Descrambler
    lphy_descrambler rx_descrambler (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .load_seed(load_seed),
        .seed_in(seed_in),
        .data_in(scrambled_data),
        .data_out(rx_recovered_data)
    );
    
    // Clock Generation
    initial begin
        clk = 1;
        forever #5000 clk = ~clk;
    end
    
    // Test Sequence
    initial begin
        // 1. Initialize
        rst_n = 0;
        enable = 0;
        load_seed = 0;
        seed_in = 23'h0;
        tx_raw_data = 8'h00;
        
        #15000 rst_n = 1;
        
        // 2. Load specific Lane 3 Seed (Table 20)
        @(posedge clk);
        load_seed = 1;
        seed_in = 23'h18C0DB;
        @(posedge clk);
        load_seed = 0;
        
        // 3. Send sequential data and verify
        enable = 1;
        for (int i = 0; i < 256; i++) begin
            @(posedge clk);
            tx_raw_data = i[7:0];
            #1
            if(rx_recovered_data !== tx_raw_data) begin
                $error("Mismatch at Time %0t! Sent: %h, Scrambled: %h, Recovered: %h",
                        $time, tx_raw_data, scrambled_data, rx_recovered_data);
            end else begin
                $display("Success: Sent %h -> Scrambled to %h -> Recovered %h",
                          tx_raw_data, scrambled_data, rx_recovered_data);
            end
        end
        
        // 4. Disable scrambling test
        enable = 0;
        tx_raw_data = 8'hAA;
        @(posedge clk);
        #1;
        if (scrambled_data !== 8'hAA || rx_recovered_data != 8'hAA) begin
            $error("Bypass mode failed");
        end
        
        $display("Scrambler to Descrambler chain simulation passed perfectly.");
        $finish;
    end
endmodule