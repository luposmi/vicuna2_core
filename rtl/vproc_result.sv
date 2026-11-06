// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_result #(
        parameter int unsigned      XIF_ID_W       = 3,    // width in bits of instruction IDs
        parameter bit               DONT_CARE_ZERO = 1'b0  // initialize don't care values to zero
    )(
        input  logic                clk_i,
        input  logic                async_rst_ni,
        input  logic                sync_rst_ni,

        input  logic                result_empty_valid_i,
        input  logic [XIF_ID_W-1:0] result_empty_id_i,

        input  logic                result_lsu_valid_i,
        output logic                result_lsu_ready_o,
        input  logic [XIF_ID_W-1:0] result_lsu_id_i,
        input  logic                result_lsu_exc_i,
        input  logic [5:0]          result_lsu_exccode_i,

        input  logic                result_xreg_valid_i,
        output logic                result_xreg_ready_o,
        input  logic [XIF_ID_W-1:0] result_xreg_id_i,
        input  logic [4:0]          result_xreg_addr_i,
        input  logic [31:0]         result_xreg_data_i,

        `ifdef RISCV_ZVE32F
        input  logic                result_freg_i,
        output logic                result_freg_o,

        input logic                 fpu_res_acc,
        input logic [XIF_ID_W-1:0]  fpu_res_id,

        `endif

        input  logic                result_csr_valid_i,
        output logic                result_csr_ready_o,
        input  logic [XIF_ID_W-1:0] result_csr_id_i,
        input  logic [4:0]          result_csr_addr_i,
        input  logic [31:0]         result_csr_data_i,

        output logic                result_fifo_full_stall_o,

        vproc_xif.coproc_result     xif_result_if,
        vproc_xif.coproc_commit     xif_commit_if
    );



  // One outstanding transaction per XIF ID; commit cannot be backpressured.
  localparam int unsigned XIF_ID_CNT = 1 << XIF_ID_W;
  logic result_fire;
  assign result_fire = xif_result_if.result_valid && xif_result_if.result_ready;

  /////////////////
  // FIFO of committed XIF IDs.  Vicuna must signal result in the order in which the instructions were committed
  // additional signals are available (full/empty signalling) which can be used to stall the pipeline if necessary.  Tie these to issue interface? (Commit cannot stall)
  ////////////////
  logic [XIF_ID_W-1:0] res_id_fifo_out;
  logic                res_id_fifo_empty;
  logic                res_id_fifo_full;
  fifo_v3 #(
    .FALL_THROUGH (1'b0        ),
    .dtype        (logic [XIF_ID_W-1:0]),
    .DEPTH        (XIF_ID_CNT)
  ) commit_id_fifo (
    .clk_i,
    .rst_ni     (sync_rst_ni),
    .flush_i    (1'b0                                                   ),
    .data_i     (xif_commit_if.commit.id                                ),
    .push_i     (xif_commit_if.commit_valid & !xif_commit_if.commit.commit_kill),
    .data_o     (res_id_fifo_out                                        ),
    .pop_i      (result_fire),
    .empty_o    (res_id_fifo_empty                                      ),
    .full_o     (res_id_fifo_full                                       )  // Commit interface cannot stall, stall issue interface instead.  For CVA6, this prevents offloading.  For CV32E40X, TODO: investigate this
  );

  assign result_fifo_full_stall_o = res_id_fifo_full || empty_res_fifo_full ||
                                    xreg_res_fifo_full || vlsu_res_fifo_full ||
                                    csr_res_fifo_full;
  ////////////////
  // FIFO of results from each source.
  // Each source is guarunteed to signal in order, but might not be in order relative to each other (i.e. load vector load followed by an independent vector alu operation)
  // Buffering only necessary for most fifos if scalar core is not ready to receive the result (Use fallthrough mode)
  ///////////////

  // FIFO for empty result signalling.
  logic                empty_res_valid;
  logic                pop_empty_id;
  logic [XIF_ID_W-1:0] empty_res_fifo_out;
  logic                empty_res_fifo_empty;
  logic                empty_res_fifo_full;

  fifo_v3 #(
    .FALL_THROUGH (1'b0       ), //FOR CVA6 CANNOT HAVE FALLTHROUGH ENABLED (Result must come at least one cycle after commit/issue)
    .dtype        (logic [XIF_ID_W-1:0]),
    .DEPTH        (XIF_ID_CNT)
  ) res_empty_fifo (
    .clk_i,
    .rst_ni     (sync_rst_ni),
    .flush_i    (1'b0                          ),
    .data_i     (result_empty_id_i             ),
    .push_i     (result_empty_valid_i          ),
    .data_o     (empty_res_fifo_out            ),
    .pop_i      (pop_empty_id                  ),
    .empty_o    (empty_res_fifo_empty          ),
    .full_o     (empty_res_fifo_full           )
  );

  assign empty_res_valid = !res_id_fifo_empty && !empty_res_fifo_empty &&
                            (empty_res_fifo_out == res_id_fifo_out);
  assign pop_empty_id = empty_res_valid && result_fire;

  //FIFO for xreg result signalling : TODO: Extend to support floating point results  (Might need its own fifo since xreg result and freg result might not be signalled in order?)
  logic                xreg_res_valid;
  logic                pop_xreg_id;
  logic                xreg_res_fifo_empty;
  logic                xreg_res_fifo_full;

  typedef struct packed {
    logic [XIF_ID_W -     1:0] id;
    logic [              31:0] data;
    logic [               4:0] rd;
  } res_xreg_fifo_data;

  res_xreg_fifo_data xreg_res_fifo_in, xreg_res_fifo_out;

  fifo_v3 #(
    .FALL_THROUGH (1'b0        ),
    .dtype        (res_xreg_fifo_data),
    .DEPTH        (XIF_ID_CNT)
  ) res_xreg_fifo (
    .clk_i,
    .rst_ni     (sync_rst_ni),
    .flush_i    (1'b0                          ),
    .data_i     (xreg_res_fifo_in              ),
    .push_i     (result_xreg_valid_i && result_xreg_ready_o),
    .data_o     (xreg_res_fifo_out             ),
    .pop_i      (pop_xreg_id                   ),
    .empty_o    (xreg_res_fifo_empty           ),
    .full_o     (xreg_res_fifo_full            )
  );

  assign xreg_res_fifo_in.id = result_xreg_id_i;
  assign xreg_res_fifo_in.data = result_xreg_data_i;
  assign xreg_res_fifo_in.rd = result_xreg_addr_i;

  assign xreg_res_valid = !res_id_fifo_empty && !xreg_res_fifo_empty &&
                            (xreg_res_fifo_out.id == res_id_fifo_out);
  assign pop_xreg_id = xreg_res_valid && result_fire;

  assign result_xreg_ready_o = !xreg_res_fifo_full;

  // FIFO for VLSU result signalling
  logic                vlsu_res_valid;
  logic                pop_vlsu_id;
  logic                vlsu_res_fifo_empty;
  logic                vlsu_res_fifo_full;

  typedef struct packed {
    logic [XIF_ID_W -     1:0] id;
    logic                      exc;
    logic [               5:0] exccode;
  } res_vlsu_fifo_data;

  res_vlsu_fifo_data vlsu_res_fifo_in, vlsu_res_fifo_out;
  fifo_v3 #(
    .FALL_THROUGH (1'b0        ),
    .dtype        (res_vlsu_fifo_data),
    .DEPTH        (XIF_ID_CNT)
  ) res_vlsu_fifo (
    .clk_i,
    .rst_ni     (sync_rst_ni),
    .flush_i    (1'b0                          ),
    .data_i     (vlsu_res_fifo_in              ),
    .push_i     (result_lsu_valid_i && result_lsu_ready_o),
    .data_o     (vlsu_res_fifo_out             ),
    .pop_i      (pop_vlsu_id                   ),
    .empty_o    (vlsu_res_fifo_empty           ),
    .full_o     (vlsu_res_fifo_full            )
  );

  assign vlsu_res_fifo_in.id = result_lsu_id_i;
  assign vlsu_res_fifo_in.exc = result_lsu_exc_i;
  assign vlsu_res_fifo_in.exccode = result_lsu_exccode_i;

  assign vlsu_res_valid = !res_id_fifo_empty && !vlsu_res_fifo_empty &&
                            (vlsu_res_fifo_out.id == res_id_fifo_out);
  assign pop_vlsu_id = vlsu_res_valid && result_fire;

  assign result_lsu_ready_o = !vlsu_res_fifo_full;

  // Fifo for CSR signalling results.  Fall Through mode disabled here, since csr results must be buffered for at least one cycle
  logic                csr_res_valid;
  logic                pop_csr_id;
  logic                csr_res_fifo_empty;
  logic                csr_res_fifo_full;

  logic                csr_fifo_push;

  typedef struct packed {
    logic [XIF_ID_W -     1:0] id;
    logic [              31:0] data;
    logic [               4:0] addr;
  } res_csr_fifo_data;

  res_csr_fifo_data csr_res_fifo_in, csr_res_fifo_out;
  fifo_v3 #(
    .FALL_THROUGH (1'b0        ),
    .dtype        (res_csr_fifo_data),
    .DEPTH        (XIF_ID_CNT)
  ) res_csr_fifo (
    .clk_i,
    .rst_ni     (sync_rst_ni),
    .flush_i    (1'b0                          ),
    .data_i     (csr_res_fifo_in               ),
    .push_i     (csr_fifo_push                 ),
    .data_o     (csr_res_fifo_out              ),
    .pop_i      (pop_csr_id                    ),
    .empty_o    (csr_res_fifo_empty            ),
    .full_o     (csr_res_fifo_full             )
  );

  assign csr_fifo_push = result_csr_valid_i && result_csr_ready_o;

  assign csr_res_fifo_in.id = result_csr_id_i;
  assign csr_res_fifo_in.data = result_csr_data_i;
  assign csr_res_fifo_in.addr = result_csr_addr_i;

  assign csr_res_valid = !res_id_fifo_empty && !csr_res_fifo_empty &&
                            (csr_res_fifo_out.id == res_id_fifo_out);
  assign pop_csr_id = csr_res_valid && result_fire;

  assign result_csr_ready_o = !csr_res_fifo_full;

  /////////////
  // Mux FIFO outputs to XIF_RESULT
  ////////////

  always_comb begin
    xif_result_if.result_valid = 1'b0;
    xif_result_if.result.id = res_id_fifo_out;
    xif_result_if.result.data = '0;
    xif_result_if.result.rd = '0;
    xif_result_if.result.we = '0;
    xif_result_if.result.exc = '0;
    xif_result_if.result.exccode = '0;
    xif_result_if.result.err = '0;
    xif_result_if.result.dbg = '0;
    xif_result_if.result_valid = empty_res_valid || xreg_res_valid ||
                                 vlsu_res_valid || csr_res_valid;

    if (xreg_res_valid) begin

        xif_result_if.result.data = xreg_res_fifo_out.data;
        xif_result_if.result.rd = xreg_res_fifo_out.rd;
        xif_result_if.result.we = 1'b1;

    end else if (vlsu_res_valid) begin

        xif_result_if.result.exc = vlsu_res_fifo_out.exc;
        xif_result_if.result.exccode = vlsu_res_fifo_out.exccode;

    end else if (csr_res_valid) begin

        xif_result_if.result.data = csr_res_fifo_out.data;
        xif_result_if.result.rd = csr_res_fifo_out.addr;
        xif_result_if.result.we = 1'b1;
    end
  end



`ifndef SYNTHESIS
  // fifo_v3 rejects writes while full, including simultaneous pop/push cycles.
  always @(posedge clk_i) begin
    if (async_rst_ni && sync_rst_ni) begin
      if (xif_commit_if.commit_valid && !xif_commit_if.commit.commit_kill &&
          res_id_fifo_full)
        $fatal(1, "Vicuna2 committed-result FIFO overflow");
      if (result_empty_valid_i && empty_res_fifo_full)
        $fatal(1, "Vicuna2 empty-result FIFO overflow");
      if (csr_fifo_push && csr_res_fifo_full)
        $fatal(1, "Vicuna2 CSR-result FIFO overflow");
    end
  end
`endif

`ifdef VPROC_SVA
`include "vproc_result_sva.svh"
`endif

endmodule
