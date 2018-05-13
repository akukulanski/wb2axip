////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	axilwr2wbsp.v (AXI lite to wishbone slave, read channel)
//
// Project:	Pipelined Wishbone to AXI converter
//
// Purpose:	Bridge an AXI lite write channel triplet to a single wishbone
//		write channel.  A full AXI lite to wishbone bridge will also
//	require the read channel and an arbiter.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2016-2018, Gisselquist Technology, LLC
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory, run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
module	axilwr2wbsp(i_clk, i_axi_reset_n,
	// AXI write address channel signals
	o_axi_awready, i_axi_awaddr, i_axi_awcache, i_axi_awprot, i_axi_awvalid,
	// AXI write data channel signals
	o_axi_wready, i_axi_wdata, i_axi_wstrb, i_axi_wvalid,
	// AXI write response channel signals
	o_axi_bresp, o_axi_bvalid, i_axi_bready,
	// We'll share the clock and the reset
	o_wb_cyc, o_wb_stb, o_wb_addr, o_wb_data, o_wb_sel,
		i_wb_ack, i_wb_stall, i_wb_err
`ifdef	FORMAL
	, f_first, f_mid, f_last
`endif
	);
	localparam C_AXI_DATA_WIDTH	= 32;// Width of the AXI R&W data
	parameter C_AXI_ADDR_WIDTH	= 28;	// AXI Address width
	localparam AW			= C_AXI_ADDR_WIDTH-2;// WB Address width
	parameter LGFIFO                =  3;
	localparam	DW = C_AXI_DATA_WIDTH;
	localparam	FLEN=(1<<LGFIFO);


	input	wire			i_clk;	// Bus clock
	input	wire			i_axi_reset_n;	// Bus reset

	// AXI write address channel signals
	output	wire			o_axi_awready;//Slave is ready to accept
	input	wire	[AW+1:0]	i_axi_awaddr;	// Write address
	input	wire	[3:0]		i_axi_awcache;	// Write Cache type
	input	wire	[2:0]		i_axi_awprot;	// Write Protection type
	input	wire			i_axi_awvalid;	// Write address valid

	// AXI write data channel signals
	output	wire			o_axi_wready;  // Write data ready
	input	wire	[DW-1:0]	i_axi_wdata;	// Write data
	input	wire	[DW/8-1:0]	i_axi_wstrb;	// Write strobes
	input	wire			i_axi_wvalid;	// Write valid

	// AXI write response channel signals
	output	wire	[1:0]		o_axi_bresp;	// Write response
	output	reg			o_axi_bvalid;  // Write reponse valid
	input	wire			i_axi_bready;  // Response ready

	// We'll share the clock and the reset
	output	reg				o_wb_cyc;
	output	reg				o_wb_stb;
	output	reg	[(AW-1):0]		o_wb_addr;
	output	reg	[(DW-1):0]		o_wb_data;
	output	wire	[(DW/8-1):0]		o_wb_sel;
	input	wire				i_wb_ack;
	input	wire				i_wb_stall;
	input	wire				i_wb_err;
`ifdef	FORMAL
	// Output connections only used in formal mode
	output	wire	[LGFIFO:0]		f_first;
	output	wire	[LGFIFO:0]		f_mid;
	output	wire	[LGFIFO:0]		f_last;
`endif

	wire	w_reset;
	assign	w_reset = (!i_axi_reset_n);

	reg			fifo_full, fifo_empty;

	reg	[LGFIFO:0]	r_first, r_mid, r_last, r_next;
	wire	[LGFIFO:0]	w_first_plus_one;
	wire	[LGFIFO:0]	next_first, next_last, next_mid, fifo_fill;
	reg			wb_pending, last_ack;
	reg	[LGFIFO:0]	wb_outstanding;

	wire	axi_stalled;

	assign	axi_stalled = (fifo_full)||(err_state)
				||((o_wb_stb)&&(i_wb_stall));

	assign	o_axi_awready = (!axi_stalled)&&(i_axi_awvalid)&&(i_axi_wvalid);
	assign	o_axi_wready  = o_axi_awready;

	initial	o_wb_cyc = 1'b0;
	initial	o_wb_stb = 1'b0;
	always @(posedge i_clk)
	if ((w_reset)||((o_wb_cyc)&&(i_wb_err))||(err_state))
		o_wb_stb <= 1'b0;
	else if ((i_axi_awvalid)&&(o_axi_awready))
		o_wb_stb <= 1'b1;
	else if ((o_wb_cyc)&&(!i_wb_stall))
		o_wb_stb <= 1'b0;

	always @(*)
		o_wb_cyc = (wb_pending)||(o_wb_stb);

	always @(posedge i_clk)
	if (o_axi_awready)
		o_wb_addr <= i_axi_awaddr[AW+1:2];

	always @(posedge i_clk)
	if (o_axi_wready)
		o_wb_data <= i_axi_wdata;

	always @(posedge i_clk)
	if (o_axi_wready)
		o_wb_sel <= i_axi_wstrb;

	initial	wb_pending     = 0;
	initial	wb_outstanding = 0;
	initial	last_ack    = 1;
	always @(posedge i_clk)
	if ((w_reset)||(!o_wb_cyc)||(i_wb_err)||(err_state))
	begin
		wb_pending     <= 1'b0;
		wb_outstanding <= 0;
		last_ack       <= 1;
	end else case({ (o_wb_stb)&&(!i_wb_stall), i_wb_ack })
	2'b01: begin
		wb_outstanding <= wb_outstanding - 1'b1;
		wb_pending <= (wb_outstanding >= 2);
		last_ack <= (wb_outstanding <= 2);
		end
	2'b10: begin
		wb_outstanding <= wb_outstanding + 1'b1;
		wb_pending <= 1'b1;
		last_ack <= (wb_outstanding == 0);
		end
	default: begin end
	endcase

	assign	next_first = r_first + 1'b1;
	assign	next_last  = r_last + 1'b1;
	assign	next_mid   = r_mid + 1'b1;
	assign	fifo_fill  = (r_first - r_last);

	initial	fifo_full  = 1'b0;
	initial	fifo_empty = 1'b1;
	always @(posedge i_clk)
	if (w_reset)
	begin
		fifo_full  <= 1'b0;
		fifo_empty <= 1'b1;
	end else case({ (o_axi_bvalid)&&(i_axi_bready),
				(i_axi_awvalid)&&(o_axi_awready) })
	2'b01: begin
		fifo_full  <= (next_first[LGFIFO-1:0] == r_last[LGFIFO-1:0])
					&&(next_first[LGFIFO]!=r_last[LGFIFO]);
		fifo_empty <= 1'b0;
		end
	2'b10: begin
		fifo_full <= 1'b0;
		fifo_empty <= 1'b0;
		end
	default: begin end
	endcase

	initial	r_first = 0;
	always @(posedge i_clk)
	if (w_reset)
		r_first <= 0;
	else if ((i_axi_awvalid)&&(o_axi_awready))
		r_first <= r_first + 1'b1;

	initial	r_mid = 0;
	always @(posedge i_clk)
	if (w_reset)
		r_mid <= 0;
	else if ((o_wb_cyc)&&((i_wb_ack)||(i_wb_err)))
		r_mid <= r_mid + 1'b1;
	else if ((err_state)&&(r_mid != r_first))
		r_mid <= r_mid + 1'b1;

	initial	r_last = 0;
	always @(posedge i_clk)
	if (w_reset)
		r_last <= 0;
	else if ((o_axi_bvalid)&&(i_axi_bready))
		r_last <= r_last + 1'b1;

	reg	[LGFIFO:0]	err_loc;
	always @(posedge i_clk)
	if ((o_wb_cyc)&&(i_wb_err))
		err_loc <= r_mid;

	wire	[DW:0]	read_data;

	initial	o_axi_bresp = 2'b00;
	always @(posedge i_clk)
	if (w_reset)
		o_axi_bresp <= 0;
	else if ((!o_axi_bvalid)||(i_axi_bready))
	begin
		if ((!err_state)&&((!o_wb_cyc)||(!i_wb_err)))
			o_axi_bresp <= 2'b00;
		else if ((!err_state)&&(o_wb_cyc)&&(i_wb_err))
		begin
			if (o_axi_bvalid)
				o_axi_bresp <= (r_mid == next_last) ? 2'b10 : 2'b00;
			else
				o_axi_bresp <= (r_mid == r_last) ? 2'b10 : 2'b00;
		end else if (err_state)
		begin
			if (next_last == err_loc)
				o_axi_bresp <= 2'b10;
			else if (o_axi_bresp[1])
				o_axi_bresp <= 2'b11;
		end else
			o_axi_bresp <= 0;
	end


	reg	err_state;	
	initial err_state  = 0;
	always @(posedge i_clk)
	if (w_reset)
		err_state <= 0;
	else if (r_first == r_last)
		err_state <= 0;
	else if ((o_wb_cyc)&&(i_wb_err))
		err_state <= 1'b1;

	initial	o_axi_bvalid = 1'b0;
	always @(posedge i_clk)
	if (w_reset)
		o_axi_bvalid <= 0;
	else if ((o_wb_cyc)&&((i_wb_ack)||(i_wb_err)))
		o_axi_bvalid <= 1'b1;
	else if ((o_axi_bvalid)&&(i_axi_bready))
	begin
		if (err_state)
			o_axi_bvalid <= (next_last != r_first);
		else
			o_axi_bvalid <= (next_last != r_mid);
	end

	// Make Verilator happy
	// verilator lint_off UNUSED
	// verilator lint_on  UNUSED

`ifdef	FORMAL
	reg	f_past_valid;
	initial f_past_valid = 1'b0;
	always @(posedge i_clk)
		f_past_valid <= 1'b1;

	always @(*)
	if (!f_past_valid)
		assume(w_reset);

	always @(*)
	if (err_state)
		assert(!o_axi_awready);

	always @(*)
	if (err_state)
		assert((!o_wb_cyc)&&(!o_axi_awready));

	always @(*)
	if ((fifo_empty)&&(!w_reset))
		assert((!fifo_full)&&(r_first == r_last)&&(r_mid == r_last));

	always @(*)
	if (fifo_full)
		assert((!fifo_empty)
			&&(r_first[LGFIFO-1:0] == r_last[LGFIFO-1:0])
			&&(r_first[LGFIFO] != r_last[LGFIFO]));

	always @(*)
	assert(fifo_fill <= (1<<LGFIFO));

	always @(*)
	if (fifo_full)
		assert(!o_axi_awready);
	always @(*)
		assert(fifo_full == (fifo_fill == (1<<LGFIFO)));
	always @(*)
	if (fifo_fill == (1<<LGFIFO))
		assert(!o_axi_awready);
	always @(*)
		assert(wb_pending == (wb_outstanding != 0));

	always @(*)
		assert(last_ack == (wb_outstanding <= 1));


	assign	f_first = r_first;
	assign	f_mid   = r_mid;
	assign	f_last  = r_last;

	wire	[LGFIFO:0]	f_wb_nreqs, f_wb_nacks, f_wb_outstanding;
	fwb_master #(
		.AW(AW), .DW(DW), .F_LGDEPTH(LGFIFO+1)
		) fwb(i_clk, w_reset,
		o_wb_cyc, o_wb_stb, 1'b1, o_wb_addr, o_wb_data, o_wb_sel,
			i_wb_ack, i_wb_stall, 32'h0, i_wb_err,
		f_wb_nreqs,f_wb_nacks, f_wb_outstanding);

	always @(*)
	if (o_wb_cyc)
		assert(f_wb_outstanding == wb_outstanding);

	always @(*)
	if (o_wb_cyc)
		assert(wb_outstanding <= (1<<LGFIFO));

	wire	[LGFIFO:0]	wb_fill;
	assign	wb_fill = r_first - r_mid;
	always @(*)
		assert(wb_fill <= fifo_fill);
	always @(*)
	if (!w_reset)
	begin
		if (o_wb_stb)
			assert(wb_outstanding+1 == wb_fill);
		else if (o_wb_cyc)
			assert(wb_outstanding == wb_fill);
		else if (!err_state)
			assert((wb_fill == 0)&&(wb_outstanding == 0));
	end

	wire	[LGFIFO:0]	f_axi_rd_outstanding,
				f_axi_wr_outstanding,
				f_axi_awr_outstanding;

	faxil_slave #(
		.C_AXI_ADDR_WIDTH(C_AXI_ADDR_WIDTH),
		.F_LGDEPTH(LGFIFO+1),
		.F_AXI_MAXWAIT(0),
		.F_AXI_MAXDELAY(0)
		) faxil(i_clk, i_axi_reset_n,
		//
		// AXI write address channel signals
		o_axi_awready, i_axi_awaddr, i_axi_awcache, i_axi_awprot, i_axi_awvalid,
		// AXI write data channel signals
		o_axi_wready, i_axi_wdata, i_axi_wstrb, i_axi_wvalid,
		// AXI write response channel signals
		o_axi_bresp, o_axi_bvalid, i_axi_bready,
		// AXI read address channel signals
		1'b0, i_axi_awaddr, i_axi_awcache, i_axi_awprot,
			1'b0,
		// AXI read data channel signals
		o_axi_bresp, 1'b0, 32'h0, 1'b0,
		f_axi_rd_outstanding, f_axi_wr_outstanding,
		f_axi_awr_outstanding);

	always @(*)
		assert(f_axi_wr_outstanding == f_axi_awr_outstanding);
	always @(*)
		assert(f_axi_rd_outstanding == 0);
	always @(*)
		assert(f_axi_wr_outstanding == fifo_fill);
	wire	[LGFIFO:0]	f_mid_minus_err, f_err_minus_last,
				f_first_minus_err;
	assign	f_mid_minus_err  = f_mid - err_loc;
	assign	f_err_minus_last = err_loc - f_last;
	assign	f_first_minus_err = f_first - err_loc;
	always @(*)
	if (o_axi_bvalid)
	begin
		if (!err_state)
			assert(!o_axi_bresp[1]);
		else if (err_loc == f_last)
			assert(o_axi_bresp == 2'b10);
		else if (f_err_minus_last < (1<<LGFIFO))
			assert(!o_axi_bresp[1]);
		else
			assert(o_axi_bresp[1]);
	end

	always @(*)
	if (err_state)
		assert(o_axi_bvalid == (r_first != r_last));
	else
		assert(o_axi_bvalid == (r_mid != r_last));

	always @(*)
	if (err_state)
		assert(f_first_minus_err <= (1<<LGFIFO));

	always @(*)
	if (err_state)
		assert(f_first_minus_err != 0);

	always @(*)
	if (err_state)
		assert(f_mid_minus_err <= f_first_minus_err);

	always @(*)
	if (i_axi_wvalid)
		assume(|i_axi_wstrb);
`endif
endmodule
