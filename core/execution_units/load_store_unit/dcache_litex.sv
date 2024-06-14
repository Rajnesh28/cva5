/*
 * Copyright © 2024 Chris Keilbart
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Initial code developed under the supervision of Dr. Lesley Shannon,
 * Reconfigurable Computing Lab, Simon Fraser University.
 *
 * Author(s):
 *             Chris Keilbart <ckeilbar@sfu.ca>
 */

module dcache_litex

    import cva5_config::*;
    import riscv_types::*;
    import cva5_types::*;

    # (
        parameter cpu_config_t CONFIG = EXAMPLE_CONFIG
    )
    (
        input logic clk,
        input logic rst,
        l1_arbiter_request_interface.master l1_request,
        l1_arbiter_return_interface.master l1_response,
        output logic write_outstanding,
        input logic amo,
        input amo_t amo_type,
        amo_interface.subunit amo_unit,
        input logic cbo,
        input logic uncacheable,
        memory_sub_unit_interface.responder ls,
        input logic load_peek, //If the next request may be a load
        input logic[31:0] load_addr_peek //The address in that case
    );

    localparam derived_cache_config_t SCONFIG = get_derived_cache_params(CONFIG, CONFIG.DCACHE, CONFIG.DCACHE_ADDR);
    localparam DB_ADDR_LEN = SCONFIG.LINE_ADDR_W + SCONFIG.SUB_LINE_ADDR_W;
    
    cache_functions_interface # (.TAG_W(SCONFIG.TAG_W), .LINE_W(SCONFIG.LINE_ADDR_W), .SUB_LINE_W(SCONFIG.SUB_LINE_ADDR_W)) addr_utils ();

    typedef logic[SCONFIG.TAG_W-1:0] tag_t;

    typedef struct packed {
        logic valid;
        tag_t tag;
    } tb_entry_t;

    typedef struct packed {
        logic[31:0] addr;
        logic[31:0] data;
        logic[3:0] be;
        logic rnw;
        logic uncacheable;
        logic amo;
        amo_t amo_type;
        logic cbo;
    } req_t;

    //Implementation
    req_t stage0;
    req_t stage1;
    logic stage1_done;
    logic stage0_advance_r;

    assign write_outstanding = (current_state != IDLE) & (~stage1.rnw | stage1.amo);

    //Peeking avoids circular logic
    assign ls.ready = (current_state == IDLE) | (stage1_done & ~stage1.cbo & ~(db_wen & load_peek & load_addr_peek[31:DB_ADDR_LEN+2] == stage1.addr[31:DB_ADDR_LEN+2] & load_addr_peek[2+:DB_ADDR_LEN] == db_addr));

    always_ff @(posedge clk) begin
        if (rst)
            stage0_advance_r <= 0;
        else
            stage0_advance_r <= ls.new_request;
        if (ls.new_request)
            stage1 <= stage0;
    end

    assign stage0 = '{
        addr : ls.addr,
        data : ls.data_in,
        be : ls.be,
        rnw : ls.re,
        uncacheable : uncacheable,
        amo : amo,
        amo_type : amo_type,
        cbo : cbo
    };
    
    //Replacement policy
    logic[CONFIG.DCACHE.WAYS-1:0] replacement_way;
    cycler #(CONFIG.DCACHE.WAYS) replacement_policy (
        .en(ls.new_request), 
        .one_hot(replacement_way),
    .*);

    //Tagbank
    tb_entry_t[CONFIG.DCACHE.WAYS-1:0] tb_entries;
    tb_entry_t new_entry;
    logic[CONFIG.DCACHE.WAYS-1:0] hit_ohot;
    logic[CONFIG.DCACHE.WAYS-1:0] hit_ohot_r;
    logic hit;
    logic hit_r;
    logic tb_write;

    assign tb_write = stage0_advance_r & ~stage1.uncacheable & ((~hit & stage1.rnw & ~stage1_is_sc) | (stage1.cbo & hit));

    assign new_entry = '{
        valid : ~stage1.cbo,
        tag : addr_utils.getTag(stage1.addr)
    };

    sdp_ram_padded #(
        .ADDR_WIDTH(SCONFIG.LINE_ADDR_W),
        .NUM_COL(CONFIG.DCACHE.WAYS),
        .COL_WIDTH($bits(tb_entry_t)),
        .PIPELINE_DEPTH(0)
    ) tagbank (
        .a_en(tb_write),
        .a_wbe(replacement_way),
        .a_wdata({CONFIG.DCACHE.WAYS{new_entry}}),
        .a_addr(addr_utils.getTagLineAddr(stage1.addr)),
        .b_en(ls.new_request),
        .b_addr(addr_utils.getTagLineAddr(stage0.addr)),
        .b_rdata(tb_entries),
    .*);

    //Hit detection
    always_comb begin
        hit_ohot = '0;
        for (int i = 0; i < CONFIG.DCACHE.WAYS; i++)
            hit_ohot[i] = tb_entries[i].valid & (tb_entries[i].tag == addr_utils.getTag(stage1.addr));
    end
    assign hit = |hit_ohot;
    always_ff @(posedge clk) begin
        if (stage0_advance_r) begin
            hit_r <= hit;
            hit_ohot_r <= hit_ohot;
        end
    end

    //Databank
    logic[CONFIG.DCACHE.WAYS-1:0][31:0] db_entries;
    logic[31:0] db_hit_entry;
    logic db_wen;
    logic[CONFIG.DCACHE.WAYS-1:0] db_way;
    logic[CONFIG.DCACHE.WAYS-1:0][3:0] db_wbe_full;
    logic[31:0] db_wdata;

    always_comb begin
        for (int i = 0; i < CONFIG.DCACHE.WAYS; i++)
            db_wbe_full[i] = {4{db_way[i]}} & stage1.be;
    end

    logic[DB_ADDR_LEN-1:0] db_addr;
    assign db_addr = current_state == FILLING ? {addr_utils.getTagLineAddr(stage1.addr), word_counter} : addr_utils.getDataLineAddr(stage1.addr);

    sdp_ram #(
        .ADDR_WIDTH(DB_ADDR_LEN),
        .NUM_COL(4*CONFIG.DCACHE.WAYS),
        .COL_WIDTH(8),
        .PIPELINE_DEPTH(0)
    ) databank (
        .a_en(db_wen),
        .a_wbe(db_wbe_full),
        .a_wdata({CONFIG.DCACHE.WAYS{db_wdata}}),
        .a_addr(db_addr),
        .b_en(ls.new_request),
        .b_addr(addr_utils.getDataLineAddr(stage0.addr)),
        .b_rdata(db_entries),
    .*);

    always_comb begin
        db_hit_entry = 'x;
        for (int i = 0; i < CONFIG.DCACHE.WAYS; i++) begin
            if (hit_ohot[i])
                db_hit_entry = db_entries[i];
        end
    end

    //Arbiter response
    logic correct_word;
    logic return_done;
    logic[SCONFIG.SUB_LINE_ADDR_W-1:0] word_counter;
    assign return_done = l1_response.data_valid & word_counter == SCONFIG.SUB_LINE_ADDR_W'(CONFIG.DCACHE.LINE_W-1);
    assign correct_word = l1_response.data_valid & word_counter == stage1.addr[2+:SCONFIG.SUB_LINE_ADDR_W];
    always_ff @(posedge clk) begin
        if (l1_response.data_valid)
            word_counter <= word_counter+1;
        if (ls.new_request)
            word_counter <= 0;
    end

    typedef enum {
        IDLE,
        FIRST_CYCLE,
        REQUESTING_READ,
        FILLING,
        UNCACHEABLE_WAITING_READ,
        AMO_WRITE
    } stage1_t;
    stage1_t current_state;
    stage1_t next_state;

    always_ff @(posedge clk) begin
        if (rst)
            current_state <= IDLE;
        else
            current_state <= next_state;
    end

    //Have to pull this into its own block to prevent a verilator circular dependency
    always_comb begin
        unique case (current_state)
            IDLE : stage1_done = 0;
            FIRST_CYCLE : stage1_done = ((~stage1.rnw | (stage1_is_sc & amo_unit.reservation_valid)) & l1_request.ack) | (stage1_is_sc & ~amo_unit.reservation_valid) | (stage1.rnw & hit & (~stage1.amo | stage1_is_lr) & ~stage1.uncacheable) | stage1.cbo;
            REQUESTING_READ : stage1_done = 0;
            FILLING : stage1_done = return_done & (stage1_is_lr | ~stage1.amo);
            UNCACHEABLE_WAITING_READ : stage1_done = l1_response.data_valid & (stage1_is_lr | ~stage1.amo);
            AMO_WRITE : stage1_done = l1_request.ack;
        endcase
    end

    always_comb begin
        unique case (current_state)
            IDLE : begin
                l1_request.request = 0;
                l1_request.addr = 'x;
                l1_request.data = 'x;
                l1_request.rnw = 'x;
                l1_request.size = 'x;
                db_wen = 0;
                db_wdata = 'x;
                db_way = 'x;
                ls.data_valid = 0;
                ls.data_out = 'x;
                next_state = ls.new_request ? FIRST_CYCLE : IDLE;
            end
            FIRST_CYCLE : begin //Handles writes, read hits, uncacheable reads, and SC
                l1_request.request = ~stage1.cbo & (~stage1.rnw | (stage1.uncacheable & ~stage1_is_sc) | (stage1_is_sc & amo_unit.reservation_valid));
                l1_request.addr = stage1.addr;
                l1_request.data = stage1.data;
                l1_request.rnw = stage1.rnw & ~stage1_is_sc;
                l1_request.size = '0;
                db_wen = ~stage1.cbo & hit & ~stage1.uncacheable & (~stage1.rnw | (stage1_is_sc & amo_unit.reservation_valid));
                db_wdata = stage1.data;
                db_way = hit_ohot;
                ls.data_valid = (stage0_advance_r & stage1_is_sc) | (stage1.rnw & ~stage1.uncacheable & hit & ~stage1_is_sc);
                ls.data_out = stage1_is_sc ? {31'b0, ~amo_unit.reservation_valid} : db_hit_entry;
                if (stage1_done)
                    next_state = ls.new_request ? FIRST_CYCLE : IDLE;
                else if (stage1.uncacheable & l1_request.ack)
                    next_state = UNCACHEABLE_WAITING_READ;
                else if (stage1.rnw & ~stage1.uncacheable & ~hit & ~stage1_is_sc)
                    next_state = REQUESTING_READ;
                else if (stage1.amo & hit & ~stage1.uncacheable & ~stage1_is_sc)
                    next_state = AMO_WRITE;
                else
                    next_state = FIRST_CYCLE;
            end
            REQUESTING_READ : begin
                l1_request.request = 1;
                l1_request.addr = stage1.addr;
                l1_request.data = 'x;
                l1_request.rnw = 1;
                l1_request.size = 5'(CONFIG.DCACHE.LINE_W-1);
                db_wen = 0;
                db_wdata = 'x;
                db_way = 'x;
                ls.data_valid = 0;
                ls.data_out = 'x;
                next_state = l1_request.ack ? FILLING : REQUESTING_READ;
            end
            FILLING : begin
                l1_request.request = 0;
                l1_request.addr = 'x;
                l1_request.data = 'x;
                l1_request.rnw = 'x;
                l1_request.size = 'x;
                db_wen = l1_response.data_valid;
                db_wdata = l1_response.data;
                db_way = replacement_way;
                ls.data_valid = correct_word;
                ls.data_out = l1_response.data;
                if (return_done) begin
                    if (stage1.amo & ~stage1_is_lr)
                        next_state = AMO_WRITE;
                    else
                        next_state = ls.new_request ? FIRST_CYCLE : IDLE;
                end
                else
                    next_state = FILLING;
            end
            UNCACHEABLE_WAITING_READ : begin
                l1_request.request = 0;
                l1_request.addr = 'x;
                l1_request.data = 'x;
                l1_request.rnw = 'x;
                l1_request.size = 'x;
                db_wen = 0;
                db_wdata = 'x;
                db_way = 'x;
                ls.data_valid = l1_response.data_valid;
                ls.data_out = l1_response.data;
                if (l1_response.data_valid) begin
                    if (stage1.amo & ~stage1_is_lr)
                        next_state = AMO_WRITE;
                    else
                        next_state = ls.new_request ? FIRST_CYCLE : IDLE;
                end
                else
                    next_state = UNCACHEABLE_WAITING_READ;  
            end
            AMO_WRITE : begin
                l1_request.request = 1;
                l1_request.addr = stage1.addr;
                l1_request.data = amo_unit.rd;
                l1_request.rnw = 0;
                l1_request.size = '0;
                db_wen = ~stage1.uncacheable;
                db_wdata = amo_unit.rd;
                db_way = hit_r ? hit_ohot_r : replacement_way;
                ls.data_valid = 0;
                ls.data_out = 'x;
                if (l1_request.ack)
                    next_state = ls.new_request ? FIRST_CYCLE : IDLE;
                else
                    next_state = AMO_WRITE;  
            end
        endcase
    end

    //AMO
    logic stage1_is_lr;
    logic stage1_is_sc;

    assign stage1_is_lr = stage1.amo & stage1.amo_type == AMO_LR_FN5;
    assign stage1_is_sc = stage1.amo & stage1.amo_type == AMO_SC_FN5;

    assign amo_unit.reservation = stage1.addr;
    assign amo_unit.rs2 = stage1.data;
    assign amo_unit.rmw_valid = (current_state != IDLE) & stage1.amo;
    assign amo_unit.set_reservation = stage1_is_lr & stage1_done;
    assign amo_unit.clear_reservation = stage1_done;

    always_ff @(posedge clk) begin
        if (stage0_advance_r)
            amo_unit.rs1 <= db_hit_entry;
        else if (correct_word | (l1_response.data_valid & stage1.uncacheable))
            amo_unit.rs1 <= l1_response.data;
    end

    assign l1_request.be = stage1.be;
    assign l1_request.is_amo = 0;
    assign l1_request.amo = '0;

endmodule
