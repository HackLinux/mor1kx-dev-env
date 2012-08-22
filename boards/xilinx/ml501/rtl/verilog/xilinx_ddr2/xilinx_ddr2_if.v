//////////////////////////////////////////////////////////////////////
////                                                              ////
////  Xilinx ML501 DDR2 controller Wishbone Interface             ////
////                                                              ////
////  Description                                                 ////
////  Simple interface to the Xilinx MIG generated DDR2 controller////
////                                                              ////
////  To Do:                                                      ////
////   Use full capacity of BRAM                                  ////
////   Employ LRU replacement scheme                              ////
////   Remove hard-coding of things relating to number of lines   ////
////                                                              ////
////  Author(s):                                                  ////
////      - Julius Baxter, julius.baxter@orsoc.se                 ////
////                                                              ////
////                                                              ////
//////////////////////////////////////////////////////////////////////
////                                                              ////
//// Copyright (C) 2010 Authors and OPENCORES.ORG                 ////
////                                                              ////
//// This source file may be used and distributed without         ////
//// restriction provided that this copyright statement is not    ////
//// removed from the file and that any derivative work contains  ////
//// the original copyright notice and the associated disclaimer. ////
////                                                              ////
//// This source file is free software; you can redistribute it   ////
//// and/or modify it under the terms of the GNU Lesser General   ////
//// Public License as published by the Free Software Foundation; ////
//// either version 2.1 of the License, or (at your option) any   ////
//// later version.                                               ////
////                                                              ////
//// This source is distributed in the hope that it will be       ////
//// useful, but WITHOUT ANY WARRANTY; without even the implied   ////
//// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR      ////
//// PURPOSE.  See the GNU Lesser General Public License for more ////
//// details.                                                     ////
////                                                              ////
//// You should have received a copy of the GNU Lesser General    ////
//// Public License along with this source; if not, download it   ////
//// from http://www.opencores.org/lgpl.shtml                     ////
////                                                              ////
//////////////////////////////////////////////////////////////////////
/*
 * This is an interface to the Xilinx MIG-sourced DDR2 controller.
 * 
 * The controller's interface is via FIFO buffers - one for address and control
 * the other is for data. The data FIFO interface is 128-bits wide. 
 * 
 * This module has a cache with different aspects on each port. As we're to 
 * ultimately interface to a 32-bit wide Wishbone bus, one side is 32-bits
 * and the other is 128-bits wide to accommodate the DDR2 controller's data
 * path.
 * 
 * At present, the cache controller doesn't employ associativity, so any
 * line can be used for any location. A round-robin approach to line 
 * use is employed. TODO is LRU scheme instead of round robin.
 * 
 * The cache is a macro generated by Xilinx's IP generation tool. This is 
 * because memories with dual-aspect ratios cannot be inferred via HDL.
 * 
 * The size of lines, as set by the defines, controls how long each read
 * and write burst to/from the SDRAM is.
 * 
 * There are two clock domains - the Wishbone and the DDR2 controller domain.
 * 
 * A signal is sent to control logic in the DDR2 domain side to load and store 
 * the contents of a particular line from and to the DDR2 controller's data
 * FIFOs. This loading and storing is done at the DDR2 clock domain's rate.
 * 
 * The writing of address and control data is done from the Wishbone domain.
 * 
 * Multi-cycle paths:
 * Write:
 * To indicate that a writeback is occuring, a system-bus domain (wishbone, in
 * this case) signal is set, and then sampled in the controller domain whenever
 * a system-bus domain clock edge is detected. This register is "do_writeback"
 * and then the controller domain register "ddr2_write_done" is asserted when
 * the data has been written out of the RAMs and into the controller's fifos.
 * "ddr2_write_done" is then sampled by the system-bus domain and "do_writeback"
 * So there are paths between:
 * ( register -> (sampled by) -> register )
 * wb_clk:do_writeback -> ddr2_clk:do_writeback_ddr2
 * wb_clk:do_writeback -> ddr2_clk:ddr2_write_done
 * ddr2_clk:ddr2_write_done -> wb_clk:do_writeback
 * 
 * Read:
 * The only signal crossing we have here is the one indicating the read data
 * has arrived into the cache RAM from the controller. The controller domain
 * register "ddr2_read_done" is set, and sampled in the system-bus domain by the
 * logic controlling the "do_readfrom" register. "ddr2_read_done" is cleared
 * when the controller domain sees that "do_readfrom" has been de-asserted.
 * So there are paths between:
 * ( register -> (sampled by) -> register )
 * ddr2_clk:ddr2_read_done -> wb_clk:do_readfrom
 * wb_clk:do_readfrom -> ddr2_clk:ddr2_read_done
 * 
*/
module xilinx_ddr2_if (
    input [31:0]       wb_adr_i,
    input 	       wb_stb_i,
    input 	       wb_cyc_i,
    input [2:0]        wb_cti_i,
    input [1:0]        wb_bte_i,
    input 	       wb_we_i,
    input [3:0]        wb_sel_i,
    input [31:0]       wb_dat_i,
    output [31:0]      wb_dat_o,
    output reg 	       wb_ack_o,
			  
    output [12:0]      ddr2_a,
    output [1:0]       ddr2_ba,
    output 	       ddr2_ras_n,
    output 	       ddr2_cas_n,
    output 	       ddr2_we_n,
    output [1:0]       ddr2_cs_n,
    output [1:0]       ddr2_odt,
    output [1:0]       ddr2_cke,
    output [7:0]       ddr2_dm,

    inout [63:0]       ddr2_dq,		  
    inout [7:0]        ddr2_dqs,
    inout [7:0]        ddr2_dqs_n,
    output [1:0]       ddr2_ck,
    output [1:0]       ddr2_ck_n,
			  
    input 	       ddr2_if_clk,
    input 	       ddr2_if_rst,			
    input 	       idly_clk_200,
			  
    input 	       wb_clk,
    input 	       wb_rst);
   
`include "xilinx_ddr2_params.v"

   // Define to add a counter, signaling error if the controller locks up
   // (no ack after a certain period of time)
   //`define ERR_COUNTER
   
/*
`define DDR2_CACHE_NUM_LINES 16
`define DDR2_CACHE_NUM_LINES_ENC_WIDTH 4 // log2(`DDR2_CACHE_NUM_LINES)
 */
`define DDR2_CACHE_NUM_LINES 4
`define DDR2_CACHE_NUM_LINES_ENC_WIDTH 2 // log2(`DDR2_CACHE_NUM_LINES)

`define DDR2_CACHE_NUM_WORDS_PER_LINE 256
`define DDR2_CACHE_ADDR_WIDTH_WORDS_PER_LINE 8
`define DDR2_CACHE_TAG_ADDR_WIDTH (32-`DDR2_CACHE_ADDR_WIDTH_WORDS_PER_LINE-2)

`define DDR2_CACHE_DDR2_SIDE_NUM_WORDS_PER_LINE (`DDR2_CACHE_NUM_WORDS_PER_LINE/4)
`define DDR2_CACHE_DDR2_SIDE_ADDR_WIDTH_NUM_WORDS_PER_LINE (`DDR2_CACHE_ADDR_WIDTH_WORDS_PER_LINE - 2)
`define DDR2_CACHE_DDR2_SIDE_ADDR_WIDTH (`DDR2_CACHE_NUM_LINES_ENC_WIDTH + `DDR2_CACHE_DDR2_SIDE_ADDR_WIDTH_NUM_WORDS_PER_LINE)

`define DDR2_CACHE_TAG_BITS 31:(`DDR2_CACHE_ADDR_WIDTH_WORDS_PER_LINE+2)

   wire 	       ddr2_clk; // DDR2 iface domain clock.
   wire 	       ddr2_rst; // reset from the ddr2 module
   
   wire 	       wb_req;   
   reg 		       wb_req_r;
   reg 		       wb_ack_o_r;   
   
   wire 	       wb_req_new;
   reg 		       wb_req_new_r;
   
   wire 	       wb_req_addr_hit;
   
   wire 	       cached_addr_valid;
   

   wire [31:(32 -`DDR2_CACHE_TAG_ADDR_WIDTH)] cached_addr;
   
`define DDR2_BURST_8_DQ64_ADDR_WIDTH 4 // = log2(burst of 8 64-bits = 16 words)
`define DDR2_BURST_4_DQ64_ADDR_WIDTH 3 // = log2(burst of 4 64-bits = 8 words)
   // This counts how many addresses we should write to the fifo - the number 
   // of discrete FIFO transactions.
   reg [`DDR2_CACHE_ADDR_WIDTH_WORDS_PER_LINE-`DDR2_BURST_8_DQ64_ADDR_WIDTH - 1:0] addr_counter;

   wire 	       cache_write;
      
   wire 	       cache_hit;
   
   wire 	       wb_cache_en;
   
   reg 		       do_writeback, do_writeback_r;
   wire 	       do_writeback_start, do_writeback_finished;
   // Wire to indicate writing to data FIFO of MIG has completed
   wire 	       do_writeback_data_finished;
   // Wire to indicate that address FIFO of MIG should be written to to 
   // initiate memory accesses.
   reg 		       do_writeback_addresses, do_writeback_addresses_r;
      
   reg 		       do_readfrom, do_readfrom_r;   
   wire 	       do_readfrom_start, do_readfrom_finished;
   wire 	       doing_readfrom;
   
   reg 		       do_af_write;   
   
   // Domain crossing logic
   reg 		       wb_clk_r;
   reg 		       wb_clk_in_ddr2_clk;
   
   reg 		       wb_clk_in_ddr2_clk_r;
   wire 	       wb_clk_edge;   
   reg [2:0] 	       ddr2_clk_phase;
   // Sample when clk phase is 0
   reg 		       do_writeback_ddr2;
   reg 		       do_writeback_ddr2_fifo_we;
   reg 		       ddr2_write_done;   
   reg [`DDR2_CACHE_DDR2_SIDE_ADDR_WIDTH_NUM_WORDS_PER_LINE - 1:0] ddr2_cache_line_word_addr;   
   wire [127:0]        ddr2_cache_data_o;
   reg 		       rd_data_valid_r;
   reg 		       ddr2_read_done;
   
   // DDR2 MIG interface wires
   wire 	       app_af_afull;
   wire 	       app_wdf_afull;
   wire 	       app_wdf_wren;
   wire 	       app_af_wren;
   wire [30:0] 	       writeback_af_addr;
   wire [30:0] 	       readfrom_af_addr;   
   wire [30:0] 	       app_af_addr;
   wire [2:0] 	       app_af_cmd;
   
   wire [(APPDATA_WIDTH)-1:0] app_wdf_data;
   wire [(APPDATA_WIDTH/8)-1:0] app_wdf_mask_data;
   wire 			rd_data_valid;
   wire [(APPDATA_WIDTH)-1:0] 	rd_data_fifo_out;
   wire 			phy_init_done;
   
   wire [`DDR2_CACHE_NUM_LINES - 1 :0] 	cache_line_addr_validate;
   wire [`DDR2_CACHE_NUM_LINES - 1 :0] 	cache_line_addr_invalidate;
   wire [`DDR2_CACHE_NUM_LINES - 1 :0] 	cache_line_addr_valid;
   wire [`DDR2_CACHE_NUM_LINES - 1 :0] 	cache_line_hit;
   wire [`DDR2_CACHE_TAG_BITS] 	cache_line_addr [0:`DDR2_CACHE_NUM_LINES-1] ;

   // Cache control signals
   // Wishbone side
   wire [`DDR2_CACHE_ADDR_WIDTH_WORDS_PER_LINE-1:0] wb_cache_adr;
   wire [3:0] 			wb_cache_sel_we;
   // DDR side
   wire 			ddr2_cache_en;
   wire [15:0] 			ddr2_cache_we;

   reg 				wb_bursting; // Indicate if burst is enabled
   reg [3:0] 			wb_burst_addr; // Burst counter, up to 16
   wire [1:0] 			wb_burst_addr_4beat;
   wire [2:0] 			wb_burst_addr_8beat;
   wire 			wb_burst_addr_incr;
   wire 			ack_err;
   reg 				ack_err_r;


   // Synchronisation signals
   reg                          sync, sync_r;
   wire 			sync_start;
   wire 			sync_done;

   // Decoded select line
   wire [`DDR2_CACHE_NUM_LINES-1:0] selected_cache_line;
   wire [`DDR2_CACHE_NUM_LINES_ENC_WIDTH-1:0] selected_cache_line_enc;
   reg [`DDR2_CACHE_NUM_LINES_ENC_WIDTH-1:0] selected_cache_line_enc_ddr2_clk;
   
   genvar 				      i;
   generate
      for (i=0;i<`DDR2_CACHE_NUM_LINES;i=i+1) begin : cache_addr
	 xilinx_ddr2_wb_if_cache_adr_reg cache_addr_reg_inst
	   ( .adr_i(wb_adr_i[`DDR2_CACHE_TAG_BITS]), 
	     .validate(cache_line_addr_validate[i]), 
	     .invalidate(cache_line_addr_invalidate[i]), 
	     .cache_hit(cache_line_hit[i]), 
	     .adr_valid(cache_line_addr_valid[i]),
	     .cached_adr_o(cache_line_addr[i]),
	     .clk(wb_clk), 
	     .rst(wb_rst));
      end   
   endgenerate

   wire start_writeback, start_fill;
   
   xilinx_ddr2_wb_if_cache_control xilinx_ddr2_wb_if_cache_control0
     (
      // Outputs
      .start_writeback			(start_writeback),
      .start_fill			(start_fill),
      .cache_line_validate		(cache_line_addr_validate),
      .cache_line_invalidate		(cache_line_addr_invalidate),
      .selected_cache_line		(selected_cache_line),
      .selected_cache_line_enc		(selected_cache_line_enc),
      .sync_done                        (sync_done),
      // Inputs
      .cache_line_addr_valid		(cache_line_addr_valid),
      .cache_line_addr_hit		(cache_line_hit),
      .wb_req				(wb_req),
      .cache_write			(cache_write),
      .writeback_done			(do_writeback_finished),
      .fill_done			(do_readfrom_finished),
      .sync_start                       (sync_start),
      .wb_clk				(wb_clk),
      .wb_rst				(wb_rst));

   defparam xilinx_ddr2_wb_if_cache_control0.num_lines = `DDR2_CACHE_NUM_LINES;
   defparam xilinx_ddr2_wb_if_cache_control0.num_lines_log2 = `DDR2_CACHE_NUM_LINES_ENC_WIDTH;

   assign cached_addr = selected_cache_line[0] ? cache_line_addr[0] :
			selected_cache_line[1] ? cache_line_addr[1] :
			selected_cache_line[2] ? cache_line_addr[2] :
			selected_cache_line[3] ? cache_line_addr[3] : 0;   
   
   assign cache_write = wb_req & wb_we_i & wb_ack_o;
   
   assign cache_hit = |(selected_cache_line & cache_line_hit);
   
   assign cached_addr_valid = |(selected_cache_line & cache_line_addr_valid);
   
   assign wb_req_addr_hit = (wb_req & cache_hit & cached_addr_valid);
   
   // Wishbone request detection
   assign wb_req = wb_stb_i & wb_cyc_i & phy_init_done & !sync; 
   
   always @(posedge wb_clk)
     wb_req_r <= wb_req;
   
   assign wb_req_new = wb_req & !wb_req_r;

   always @(posedge wb_clk)
     wb_req_new_r <= wb_req_new;

   always @(posedge wb_clk)
     if (wb_rst)
       wb_bursting <= 0;
   // Reset if acking end of transfer
     else if (wb_ack_o && wb_cti_i == 3'b111)
       wb_bursting <= 0;
   // Set if beginning new transaction and incrementing burst indicated
   // TODO - double check if this burst is going to go over a cache line
   // boundary - if so don't allow burst, fall back to classic cycles.
     else if (wb_req_new)
       wb_bursting <= (wb_cti_i == 3'b010);

   // Help constrain additions to appropriate bit-width for wrapping
   assign wb_burst_addr_4beat = wb_adr_i[3:2] + 1;
   assign wb_burst_addr_8beat = wb_adr_i[4:2] + 1;
   
   // Increment burst address whenever we get a hit when reading, or
   // when acking and writing.
   assign wb_burst_addr_incr = (wb_req_addr_hit & (!wb_we_i | 
						(wb_we_i & wb_ack_o)));
   
   // Calculate burst address depending on burst type indicator
   always @(posedge wb_clk)
     if (wb_rst)
       wb_burst_addr <= 0;
     else if (wb_req_new)
       // When we have a bursting read to an address which is in cache then
       // initialise the address to the next word in the burst sequence.
       // If it's a miss, or it's a write, then we just take what's on the
       // bus.
       wb_burst_addr <= !(wb_req_addr_hit & !wb_we_i) ? wb_adr_i[5:2] :
		    wb_bte_i==2'b01 ? {wb_adr_i[5:4], wb_burst_addr_4beat }:
		    wb_bte_i==2'b10 ? {wb_adr_i[5], wb_burst_addr_8beat }:
		    wb_bte_i==2'b11 ? wb_adr_i[5:2] + 1 :
		    wb_adr_i[5:2];
     else if (wb_burst_addr_incr & wb_bte_i==2'b01)
       wb_burst_addr[1:0] <= wb_burst_addr[1:0] + 1;
     else if (wb_burst_addr_incr & wb_bte_i==2'b10)
       wb_burst_addr[2:0] <= wb_burst_addr[2:0] + 1;
     else if (wb_burst_addr_incr & wb_bte_i==2'b11)
       wb_burst_addr[3:0] <= wb_burst_addr[3:0] + 1;
   
`ifdef ERR_COUNTER
   reg [26:0] ack_err_cntr;
   
   always @(posedge wb_clk)
     if (wb_rst)
       ack_err_cntr <= 0;
     else if (!wb_req)
       ack_err_cntr <= 0;
     else if (|ack_err_cntr)
       ack_err_cntr <= ack_err_cntr + 1;
     else if (wb_req_new & !(|ack_err_cntr))
       ack_err_cntr <= 1;

   assign ack_err = (&ack_err_cntr);
   
   always @(posedge wb_clk)
     ack_err_r <= ack_err;

   assign wb_err_o = ack_err_r;
   
`else // !`ifdef ERR_COUNTER
   
   assign ack_err = 0;
   always @(posedge wb_clk)
     ack_err_r <= 0;

   assign wb_err_o = 0;
   
`endif
   
   always @(posedge wb_clk)
     if (wb_rst)
       wb_ack_o <= 0;
     else
       wb_ack_o <= wb_req_addr_hit &
		   (
		    // Simple acks on classic cycles
		    (!wb_bursting && !wb_ack_o && !wb_ack_o_r)
		    // De-assert ack when we see the final transaction
		    || (wb_bursting && !(wb_cti_i==3'b111))
		    );
   
   always @(posedge wb_clk)
     wb_ack_o_r <= wb_ack_o;
   
   // Logic controling synchronisation
   always @(posedge wb_clk)
     if (wb_rst)
       sync <= 0;
     else if (sync_done) // Sync. done indicator from cache controller
       sync <= 0;

   always @(posedge wb_clk)
     sync_r <= sync;

   assign sync_start = sync & !sync_r;
   
   task do_sync;
      begin
	 // Wait for us to not be doing a transaction.
	 while(wb_req)
	   @wb_clk;
	 // Cache not busy, initiate sync.
	 sync = 1;
      end
   endtask // do_sync

   // Writeback/readfrom lower address generation
   always @(posedge wb_clk)
     if (wb_rst)
       addr_counter <= 0;
     else if (app_af_wren)
       addr_counter <= addr_counter+1;
   
   // Determine if we're writing access requests into DDR2 interface AF
   always @(posedge wb_clk)
     if (wb_rst)
       do_af_write <= 0;
     else if (do_readfrom_start | do_writeback_data_finished)
       do_af_write <= 1;
     else if ((&addr_counter)) // Stop when counter rolls over
       do_af_write <= 0;	 
   
   // Wishbone side of cache enable. Always enabled unless doing DDR2-side
   // things (fill or writeback).
   assign wb_cache_en =	!(do_readfrom | do_writeback);
   
   
   // Writeback detect logic
   always @(posedge wb_clk)
     if (wb_rst)
       do_writeback <= 0;
     else if (ddr2_write_done) // DDR2 domain signal
       do_writeback <= 0;
     else if (start_writeback)
       do_writeback <= 1;

   always @(posedge wb_clk)
     do_writeback_r <= do_writeback;

   // Detect falling edge of do_writeback
   assign do_writeback_data_finished = !do_writeback & do_writeback_r;
   
   always @(posedge wb_clk)
     if (wb_rst)
       do_writeback_addresses <= 0;
     else if (do_writeback_data_finished)
       do_writeback_addresses <= 1;
     else if ((&addr_counter))
       do_writeback_addresses <= 0;

   always @(posedge wb_clk)
     do_writeback_addresses_r <= do_writeback_addresses;

   // Detect rising edge of do_writeback
   assign do_writeback_start = do_writeback & !do_writeback_r;
   // Detect falling edge of address writing control signal
   assign do_writeback_finished = !do_writeback_addresses & 
				  do_writeback_addresses_r;
      
   // DDR2 Read detect logic
   always @(posedge wb_clk)
     if (wb_rst)
       do_readfrom <= 0;
     else if (ddr2_read_done) // DDR2 domain signal
       do_readfrom <= 0;
     else if (start_fill)
       do_readfrom <= 1;

   always @(posedge wb_clk)
     do_readfrom_r <= do_readfrom;

   // Detect line fill request rising edge
   assign do_readfrom_start = do_readfrom & !do_readfrom_r;
   // Detect line fill request falling edge
   assign do_readfrom_finished = !do_readfrom & do_readfrom_r;
   assign doing_readfrom = do_readfrom | do_readfrom_r;   

   // Address fifo signals
   assign app_af_wren = (do_readfrom_r | do_writeback_addresses_r) & 
			!app_af_afull & do_af_write ;   
   assign app_af_cmd[0] = do_readfrom; // 1 - read, 0 - write
   assign app_af_cmd[2:1] = 0;

   assign writeback_af_addr = {1'd0, cached_addr, addr_counter, 3'd0};
   
   assign readfrom_af_addr = {1'd0, wb_adr_i[`DDR2_CACHE_TAG_BITS], 
			      addr_counter, 3'd0};
   
   assign app_af_addr = doing_readfrom ?  readfrom_af_addr : writeback_af_addr;
   assign app_wdf_wren = do_writeback_ddr2_fifo_we;
   assign app_wdf_data = ddr2_cache_data_o;
   assign app_wdf_mask_data = 0;   
   
   always @(posedge wb_clk) 
     if (wb_rst) wb_clk_r <= 0; else wb_clk_r <= ~wb_clk_r;   
   always @(posedge ddr2_clk) wb_clk_in_ddr2_clk <= wb_clk_r;
   always @(posedge ddr2_clk) wb_clk_in_ddr2_clk_r <= wb_clk_in_ddr2_clk;
   
   assign wb_clk_edge = wb_clk_in_ddr2_clk & !wb_clk_in_ddr2_clk_r;
   
   always @(posedge ddr2_clk)
     if (ddr2_rst)
       ddr2_clk_phase <= 0;
     else if (wb_clk_edge)
       ddr2_clk_phase <= 0;
     else
       ddr2_clk_phase <= ddr2_clk_phase + 1;

   always @(posedge ddr2_clk)
     if (ddr2_rst)
       do_writeback_ddr2 <= 0;
     else if (&ddr2_cache_line_word_addr)
       do_writeback_ddr2 <= 0;
     else if (!(|ddr2_clk_phase) & do_writeback & // sample WB domain
	      !ddr2_write_done) 
       do_writeback_ddr2 <= 1;   
   
   always @(posedge ddr2_clk)
     if (ddr2_rst)
       ddr2_cache_line_word_addr <= 0;
     else if (rd_data_valid | (do_writeback_ddr2 & !app_wdf_afull))
       ddr2_cache_line_word_addr <= ddr2_cache_line_word_addr + 1;
     else if (ddr2_write_done | ddr2_read_done)
       ddr2_cache_line_word_addr <= 0;

   always @(posedge ddr2_clk)
     do_writeback_ddr2_fifo_we <= (do_writeback_ddr2 & !app_wdf_afull);
   
   always @(posedge ddr2_clk)
     if (ddr2_rst)
       ddr2_write_done <= 0;
     else if ((&ddr2_cache_line_word_addr))
       ddr2_write_done <= 1;
     else if ((!(|ddr2_clk_phase)) & !do_writeback) // sample WB domain
       ddr2_write_done <= 0;
         
   always @(posedge ddr2_clk)
     rd_data_valid_r <= rd_data_valid;
   
   // Read done signaling to WB domain
   always @(posedge ddr2_clk)
     if (ddr2_rst)
       ddr2_read_done <= 0;
     else if (rd_data_valid_r & (&ddr2_cache_line_word_addr))
       ddr2_read_done <= 1;
     else if (!(|ddr2_clk_phase) & !do_readfrom) // Read WB domain
       ddr2_read_done <= 0;

   // Lower word address uses potentially bursting address counter
   assign wb_cache_adr = wb_bursting ?
       {wb_adr_i[(`DDR2_CACHE_ADDR_WIDTH_WORDS_PER_LINE+2)-1:6],wb_burst_addr}:
       wb_adr_i[(`DDR2_CACHE_ADDR_WIDTH_WORDS_PER_LINE+2)-1:2];
     
   assign wb_cache_sel_we = {4{wb_we_i & wb_ack_o}} & wb_sel_i;
   assign ddr2_cache_en = (rd_data_valid |do_writeback_ddr2);   
   assign ddr2_cache_we = {16{rd_data_valid}};

   always @(posedge ddr2_clk)
     if (!(|ddr2_clk_phase)) // Read WB domain 
       selected_cache_line_enc_ddr2_clk <= selected_cache_line_enc;
   
   
   
   // Xilinx Coregen true dual-port RAMB
   // Wishbone side : 32-bit
   // DDR2 side : 128-bit
   xilinx_ddr2_if_cache cache_mem0
     (
      // Wishbone side
      .clka(wb_clk),
      .ena(wb_cache_en),
      .wea(wb_cache_sel_we),
      .addra({2'd0, selected_cache_line_enc,wb_cache_adr}),
      .dina(wb_dat_i),
      .douta(wb_dat_o),

      // DDR2 controller side
      .clkb(ddr2_clk),
      .enb(ddr2_cache_en),
      .web(ddr2_cache_we),
      .addrb({2'd0, selected_cache_line_enc_ddr2_clk,
	      ddr2_cache_line_word_addr}),
      .dinb(rd_data_fifo_out),
      .doutb(ddr2_cache_data_o));
  
   ddr2_mig #
     (
     .BANK_WIDTH            (BANK_WIDTH),
     .CKE_WIDTH             (CKE_WIDTH),
     .CLK_WIDTH             (CLK_WIDTH),
     .COL_WIDTH             (COL_WIDTH),
     .CS_NUM                (CS_NUM),
     .CS_WIDTH              (CS_WIDTH),
     .CS_BITS               (CS_BITS),
     .DM_WIDTH                     (DM_WIDTH),
     .DQ_WIDTH              (DQ_WIDTH),
     .DQ_PER_DQS            (DQ_PER_DQS),
     .DQ_BITS               (DQ_BITS),
     .DQS_WIDTH             (DQS_WIDTH),
     .DQS_BITS              (DQS_BITS),
     .HIGH_PERFORMANCE_MODE (HIGH_PERFORMANCE_MODE),
     .ODT_WIDTH             (ODT_WIDTH),
     .ROW_WIDTH             (ROW_WIDTH),
     .APPDATA_WIDTH         (APPDATA_WIDTH),
     .ADDITIVE_LAT          (ADDITIVE_LAT),
     .BURST_LEN             (BURST_LEN),
     .BURST_TYPE            (BURST_TYPE),
     .CAS_LAT               (CAS_LAT),
     .ECC_ENABLE            (ECC_ENABLE),
     .MULTI_BANK_EN         (MULTI_BANK_EN),
     .ODT_TYPE              (ODT_TYPE),
     .REDUCE_DRV            (REDUCE_DRV),
     .REG_ENABLE            (REG_ENABLE),
     .TREFI_NS              (TREFI_NS),
     .TRAS                  (TRAS),
     .TRCD                  (TRCD),
     .TRFC                  (TRFC),
     .TRP                   (TRP),
     .TRTP                  (TRTP),
     .TWR                   (TWR),
     .TWTR                  (TWTR),
     .SIM_ONLY              (SIM_ONLY),
     .RST_ACT_LOW           (RST_ACT_LOW),
     .CLK_TYPE                     (CLK_TYPE),
     .DLL_FREQ_MODE                (DLL_FREQ_MODE),
     .CLK_PERIOD            (CLK_PERIOD)
       )
   ddr2_mig0
     (
     .sys_clk           (ddr2_if_clk),
     .idly_clk_200      (idly_clk_200),
     .sys_rst_n         (ddr2_if_rst),
     .ddr2_ras_n        (ddr2_ras_n),
     .ddr2_cas_n        (ddr2_cas_n),
     .ddr2_we_n         (ddr2_we_n),
     .ddr2_cs_n         (ddr2_cs_n),
     .ddr2_cke          (ddr2_cke),
     .ddr2_odt          (ddr2_odt),
     .ddr2_dm           (ddr2_dm),
     .ddr2_dq           (ddr2_dq),
     .ddr2_dqs          (ddr2_dqs),
     .ddr2_dqs_n        (ddr2_dqs_n),
     .ddr2_ck           (ddr2_ck),
     .ddr2_ck_n         (ddr2_ck_n),
     .ddr2_ba           (ddr2_ba),
     .ddr2_a            (ddr2_a),
     
      .clk0_tb           (ddr2_clk),
      .rst0_tb           (ddr2_rst),
      .usr_clk (wb_clk),
     .app_af_afull      (app_af_afull),
     .app_wdf_afull     (app_wdf_afull),
     .rd_data_valid     (rd_data_valid),
     .rd_data_fifo_out  (rd_data_fifo_out),
     .app_af_wren       (app_af_wren),
     .app_af_cmd        (app_af_cmd),
     .app_af_addr       (app_af_addr),
     .app_wdf_wren      (app_wdf_wren),
     .app_wdf_data      (app_wdf_data),
     .app_wdf_mask_data (app_wdf_mask_data),
     .phy_init_done     (phy_init_done)
      );
     

endmodule // xilinx_ddr2_if2

// Local Variables:
// verilog-library-directories:("." "ddr2_mig")
// verilog-library-extensions:(".v" ".h")
// End:


module xilinx_ddr2_wb_if_cache_adr_reg
  (adr_i, validate, invalidate,
   cached_adr_o, cache_hit, adr_valid,
   clk, rst);

   parameter full_adr_width = 32;
   parameter word_adr_width = 2; // 4 bytes per word   
   parameter line_adr_width = 8; // 256 words per "line"

   parameter tag_width = full_adr_width - line_adr_width - word_adr_width;
   
   
   input [full_adr_width-1: word_adr_width + line_adr_width] adr_i;
   input 		 validate;
   input 		 invalidate;
   output [full_adr_width-1: word_adr_width + line_adr_width] cached_adr_o;   
   output 		  cache_hit;
   output reg 		  adr_valid;
   
   input 		  clk, rst;
   
   reg [tag_width-1:0] 	  cached_adr;

   assign cached_adr_o = cached_adr;   

   always @(posedge clk)
     if (rst)
       cached_adr <= 0;
     else if (validate)
       cached_adr <= adr_i;
   
   always @(posedge clk)
     if (rst)
       adr_valid <= 0;
     else if (validate)
       adr_valid <= 1;
     else if (invalidate)
       adr_valid <= 0;
   
   assign cache_hit = (adr_i == cached_adr);

endmodule // xilinx_ddr2_wb_if_cache_adr_reg

module xilinx_ddr2_wb_if_cache_control
  ( cache_line_addr_valid, cache_line_addr_hit,
    wb_req,
    cache_write,
    writeback_done, fill_done,
    sync_start, sync_done,
    start_writeback, start_fill,
    cache_line_validate, cache_line_invalidate,   
    selected_cache_line, selected_cache_line_enc,
    wb_clk, wb_rst);

   parameter num_lines = 16;
   parameter num_lines_log2 = 4;
   
   input [num_lines-1:0] cache_line_addr_valid;
   input [num_lines-1:0] cache_line_addr_hit;
   
   input 		 wb_req;
   input 		 cache_write;   
   input 		 writeback_done, fill_done;

   input 		 sync_start;
   output 		 sync_done;
   
   output reg 		 start_writeback;
   output reg 		 start_fill;
   output reg [num_lines-1:0] cache_line_validate;
   output reg [num_lines-1:0] cache_line_invalidate;
   
   output [num_lines-1:0]     selected_cache_line;
   output reg [num_lines_log2-1:0] selected_cache_line_enc;
   
   input 			   wb_clk, wb_rst;
   
   reg [num_lines-1:0] 		   lines_dirty;
   
   reg [num_lines-1:0] 		   selected_cache_line_from_miss;
   
   reg 				   selected_cache_line_new;
   
   reg 				   invalidate_clean_line;
   
   reg [num_lines-1:0] 		   selected_cache_line_r;
   reg [num_lines-1:0] 		   selected_cache_line_r2;   
   
   reg 				   wb_req_r;
   
   wire 			   wb_req_new;
   reg 				   wb_req_new_r;
   
   parameter sync_line_check_wait = 4;
   reg [num_lines-1:0] 		   sync_line_counter;
   reg 				   sync_doing;
   reg [sync_line_check_wait-1:0]  sync_line_select_wait_counter_shr;
   reg 				   sync_line_done;
   wire 			   sync_writeback_line;


   always @(posedge wb_clk)
     wb_req_r <= wb_req;
   
   assign wb_req_new = wb_req & !wb_req_r;
   
   always @(posedge wb_clk)
     wb_req_new_r <= wb_req_new;

   // Select a cache line when we miss. Currently very simply is round robin
   always @(posedge wb_clk)
     if (wb_rst)
       selected_cache_line_from_miss <= 1;
     else if (wb_req_new_r & !(|selected_cache_line_r)) // miss,no line selected
       // Shift select bit one
       selected_cache_line_from_miss 
	 <= {selected_cache_line_from_miss[num_lines-2:0], 
	     selected_cache_line_from_miss[num_lines-1]};
   
   
   // Line selection logic, when line address is valid and hit, we select
   always @(posedge wb_clk)
     if (wb_rst)
       selected_cache_line_r <= 0;   
     else if (wb_req_new)
       selected_cache_line_r <= cache_line_addr_valid & cache_line_addr_hit;
     else if (wb_req_new_r & !(|selected_cache_line_r))
       selected_cache_line_r <= selected_cache_line_from_miss;
     else if (sync_doing)
       selected_cache_line_r <= sync_line_counter;

   always @(posedge wb_clk)
     selected_cache_line_r2 <= selected_cache_line_r;

   assign selected_cache_line = selected_cache_line_r2;   

   // A new line of cache has been selected
   always @(posedge wb_clk)
     if (wb_rst)
       selected_cache_line_new <= 0;
     else if (wb_req_new & (&(cache_line_addr_valid & cache_line_addr_hit)))
       // New line address selected
       selected_cache_line_new <= 1;
     else if (!(|selected_cache_line_r) & wb_req_new_r)
       // Didn't select one last time, so we must have forced ourselves to 
       // select a new one
       selected_cache_line_new <= 1;
     else if (selected_cache_line_new)
       selected_cache_line_new <= 0;

   always @(posedge wb_clk)
     if (wb_rst)
       lines_dirty <= 0;
     else if (cache_write)
       lines_dirty <= lines_dirty | selected_cache_line_r;
     else if (writeback_done)
       lines_dirty <= lines_dirty & ~(selected_cache_line_r);
   
   // Validate the cache line address in the register when line filled
   always @(posedge wb_clk)
     if (wb_rst)
       cache_line_validate <= 0;
     else if (fill_done)
       cache_line_validate <= selected_cache_line_r;
     else if (|cache_line_validate)
       cache_line_validate <= 0;
   
   // Invalidate the cache line address in the register when line written back
   always @(posedge wb_clk)
     if (wb_rst)
       cache_line_invalidate <= 0;
     else if ((writeback_done & !sync_doing) | invalidate_clean_line)
       cache_line_invalidate <= selected_cache_line_r;
     else if (|cache_line_invalidate)
       cache_line_invalidate <= 0;

   // Initiate-writeback logic
   always @(posedge wb_clk)
     if (wb_rst)
       start_writeback <= 0;
     else if (start_writeback)
       start_writeback <= 0;
     else if (selected_cache_line_new & 
	      (|(lines_dirty & selected_cache_line_r)) &
	      (|(selected_cache_line_r & cache_line_addr_valid)) & 
	      !(|(cache_line_addr_hit & selected_cache_line_r)))
       start_writeback <= 1;
     else if (sync_writeback_line)
       start_writeback <= 1;

   // Invalidate lines which we haven't written to so we can fill them
   always @(posedge wb_clk)
     if (wb_rst)
       invalidate_clean_line <= 0;
     else if (invalidate_clean_line)
       invalidate_clean_line <= 0;
     else if ((selected_cache_line_new) &  // New line selected
	      !(|(lines_dirty & selected_cache_line_r)) & // It's not dirty
	      // It's valid, but we've selected it so we're trashing it
	      (|(selected_cache_line_r & cache_line_addr_valid)) & 
	      !(|(cache_line_addr_hit & selected_cache_line_r))) // Not a hit
       invalidate_clean_line <= 1;

   reg 			  invalidate_clean_line_r;   
   always @(posedge wb_clk)
     invalidate_clean_line_r <= invalidate_clean_line;
   
   
   // Initiate-fill logic
   always @(posedge wb_clk)
     if (wb_rst)
       start_fill <= 0;
     else if (((selected_cache_line_new) & // New line selected
	       // not valid
	       !(|(cache_line_addr_valid & selected_cache_line_r))) | 
	      (writeback_done & !sync_doing) | invalidate_clean_line_r
	      )
       start_fill <= 1;
     else if (start_fill)
       start_fill <= 0;

   // Hardcoded to 4 lines currently.
   always @(posedge wb_clk)
     if (selected_cache_line_r[0])
       selected_cache_line_enc <= 0;
     else if (selected_cache_line_r[1])
       selected_cache_line_enc <= 1;	     
     else if (selected_cache_line_r[2])
       selected_cache_line_enc <= 2;	     
     else if (selected_cache_line_r[3])
       selected_cache_line_enc <= 3;


   // Synchronisation control

   always @(posedge wb_clk)
     if (wb_rst)
       sync_doing <= 0;
     else if (sync_start)
       sync_doing <= 1;
     else if (sync_done)
       sync_doing <= 0;

   always @(posedge wb_clk)
     if (wb_rst)
       sync_line_counter <= 0;
     else if (sync_start)
       // Set first line to check
       sync_line_counter[0] <= 1'b1;
     else if (sync_line_done)
       // Shift along, check next line
       sync_line_counter <=  {sync_line_counter[num_lines-2:0], 1'b0};

   // Pulse this on finishing of checking lines
   assign sync_done = sync_line_counter[num_lines-1] & sync_line_done;
   
   // Pulses when a dirty line is detected and should be written back.
   assign sync_writeback_line = sync_doing & 
				sync_line_select_wait_counter_shr[0] & 
				cache_line_addr_valid &
				|(sync_line_counter & lines_dirty);
   
   always @(posedge wb_clk)
     if (wb_rst)
       sync_line_select_wait_counter_shr <= 0;
     else if (|sync_line_select_wait_counter_shr)
       sync_line_select_wait_counter_shr
	 <= {1'b0,sync_line_select_wait_counter_shr[sync_line_check_wait-1:1]};
     else if (sync_start | (sync_line_done & !sync_done))
       sync_line_select_wait_counter_shr[sync_line_check_wait-1] <= 1'b1;

   always @(posedge wb_clk)
     if (wb_rst)
       sync_line_done <= 1'b0;
     else if (sync_line_done)
       sync_line_done <= 1'b0;   
   // Either line doesn't need writeback
     else if (sync_line_select_wait_counter_shr[0] & !sync_writeback_line)
       sync_line_done <= 1'b1;
   // Or writeback finished
     else if  (writeback_done & sync_doing)
       sync_line_done <= 1'b1;
     

endmodule // xilinx_ddr2_wb_if_cache_control
