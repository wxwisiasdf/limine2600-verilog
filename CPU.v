`ifndef LIMN2600_EXECUTOR_H
`define LIMN2600_EXECUTOR_H

///////////////////////////////////////////////////////////////////////////////
//
// Limn2600 Core
//
// Executes an instruction, multiple instances of this module are used
// for executing the whole instruction queue
//
///////////////////////////////////////////////////////////////////////////////
module limn2600_CPU(
    input rst,
    input clk,
    input irq,
    output reg [31:0] addr,
    input [31:0] data_in,
    output reg [31:0] data_out,
    input rdy, // Whetever we can fetch instructions
    output reg we, // Write-Enable (1 = we want to write, 0 = we want to read)
    output reg cs // Command-State (1 = memory commands active, 0 = memory commands ignored)
);
    reg [31:0] tmp32; // Temporal value
    reg [31:0] regs[0:32]; // Limnstation has 32 registers
    reg [31:0] ctl_regs[0:32];
    reg [31:0] pc; // Program counter
    reg [2:0] state;

    reg [2:0] trans_size; // Memory transfer size
    reg [31:0] write_value; // Write value
    reg [4:0] read_regno; // Register to place the read of memory into
    reg [31:0] rw_addr; // Read-Write address

    reg stall_execute;
    reg stall_fetch;

    localparam S_FETCH = 0;
    localparam S_EXECUTE = 1;
    localparam S_PREWRITE = 2;
    localparam S_WRITE = 3;
    localparam S_READ = 4;
    localparam S_HALT = 5;
    localparam S_BRANCHED = 6;
    
    // Instruction decoder
    reg [31:0] fetch_inst_queue[0:16]; // Instruction fetched
    reg [31:0] fetch_addr; // Address to fetch on, reset on JAL/J/BR
    reg [3:0] fetch_inst_queue_num;
    reg [3:0] execute_inst_queue_num;

    reg [31:0] execute_inst; // Instruction to execute
    wire [28:0] imm29 = execute_inst[31:3];
    wire [22:0] imm21 = execute_inst[31:9];
    wire [23:0] imm22 = execute_inst[25:6]; // BRK and SYS
    wire [4:0] imm5 = execute_inst[31:27];
    wire [15:0] imm16 = execute_inst[31:24];
    wire [5:0] inst_lo = execute_inst[5:0];
    wire [4:0] opreg1 = execute_inst[10:6];
    wire [4:0] opreg2 = execute_inst[15:11];
    wire [4:0] opreg3 = execute_inst[20:16];
    wire [4:0] opreg4 = execute_inst[25:21];
    wire [5:0] inst_hi = execute_inst[31:26];
    wire [1:0] opg1_instmode = execute_inst[27:26];
    parameter
        OP_JALR = 6'b11_1000,
        OP_J_OR_JAL = 6'b??_?11?,
        OP_BEQ = 6'b11_1101,
        OP_BNE = 6'b11_0101,
        OP_BLT = 6'b10_1101,
        OP_ADDI = 6'b11_1100,
        OP_SUBI = 6'b11_0100,
        OP_SLTI = 6'b10_1100,
        OP_SLTIS = 6'b10_0100,
        OP_ANDI = 6'b01_1100,
        OP_XORI = 6'b01_0100,
        OP_ORI = 6'b00_1100,
        OP_LUI = 6'b00_0100,
        OP_MOV16 = 6'b1?_?010,
        OP_MOV5 = 6'b0?_?010; // Advanced arithmethic, atomics, etc
    // Group 1
    // Move's length
    parameter
        OP_G1_MV_BYTE = 2'b11,
        OP_G1_MV_INT = 2'b10,
        OP_G1_MV_LONG = 2'b01,
        OP_G1_MV_BITMASK = 2'b11;
    // Opcodes
    parameter
        OP_G1_MOV_TR = 4'b11??,
        OP_G1_MOV_FR = 4'b10??,
        OP_G1_NOP = 4'b1000,
        OP_G1_SLT = 4'b0101,
        OP_G1_SLTS = 4'b0100,
        OP_G1_ADD = 4'b0111,
        OP_G1_SUB = 4'b0110,
        OP_G1_AND = 4'b0011,
        OP_G1_XOR = 4'b0010,
        OP_G1_OR = 4'b0001,
        OP_G1_NOR = 4'b0000;
    // Opcode modes
    parameter
        OPM_G1_LHS = 2'b00,
        OPM_G1_RHS = 2'b01,
        OPM_G1_ASH = 2'b10,
        OPM_G1_ROR = 2'b11;
    // Group 2
    parameter
        OP_G2_MFCR = 4'b1111,
        OP_G2_MTCR = 4'b1110, // If opreg1 is zero then CR=REG, otherwise REG=CR
        OP_G2_CACHEI = 4'b1000,
        OP_G2_HLT = 4'b1100; // Halt until IRQ
    // Group 3
    parameter
        OP_G3_MUL = 4'b1111,
        OP_G3_DIV = 4'b1101,
        OP_G3_DIVS = 4'b1100,
        OP_G3_MOD = 4'b1011,
        OP_G3_LL = 4'b1001,
        OP_G3_SC = 4'b1000,
        OP_G3_BRK = 4'b0001,
        OP_G3_SYS = 4'b0000;
    // Register numbers
    parameter
        REG_LR = 31;
    parameter
        CREG_RS = 0, // Processor status
        CREG_ERS = 1, // TODO: This isn't standard on Limn2600
        CREG_TBLO = 2, // TLB entry
        CREG_EPC = 3, // PC before except
        CREG_EVEC = 4,
        CREG_PGTB = 5,
        CREG_TBINDEX = 6,
        CREG_EBADADDR = 7,
        CREG_TBVEC = 8,
        CREG_FWVEC = 9,
        CREG_TBSCRATCH = 10,
        CREG_TBHI = 11;
    // MMU and exceptions
    parameter
        ECAUSE_INTERRUPT = 2,
        ECAUSE_SYSCALL = 3,
        ECAUSE_BUS_ERROR = 4,
        ECAUSE_BREAKPOINT = 6,
        ECAUSE_INVALID_INST = 7,
        ECAUSE_PRIV_VIOLAT = 8,
        ECAUSE_UNALIGNED = 9,
        ECAUSE_PAGE_FAULT = 12,
        ECAUSE_PAGE_FAULT_WR = 13,
        ECAUSE_TLB_REFILL = 15;
    // NOTE: While the Limn2600 spec says this is not a vlid opcode
    // we say otherwise, and this is only used internally, so hopefully
    // nothing bad happens from this!
    parameter OP_TRULY_NOP = 32'b0;

    always @(rst) begin
        pc <= 32'hFFFE0000;
        state <= S_FETCH;
        for(integer i = 0; i < 16; i++) begin
            fetch_inst_queue[i] <= OP_TRULY_NOP;
        end
        fetch_inst_queue_num = 4'd14;
        execute_inst_queue_num = 4'd15;
        execute_inst <= OP_TRULY_NOP;
        stall_execute <= 0;
        stall_fetch <= 0;
        fetch_addr <= 32'hFFFE0000;
    end

    always @(posedge irq) begin
        ctl_regs[CREG_EBADADDR] <= pc;
        pc <= ctl_regs[CREG_EVEC];
        ctl_regs[CREG_RS][31:28] = ECAUSE_INTERRUPT;
        if(state == S_HALT) begin
            // Re-stall
            stall_fetch <= 1;
            state <= S_BRANCHED;
        end else begin
            stall_fetch <= 1;
            state <= S_BRANCHED;
        end
    end

    always @(posedge clk) begin
        regs[0] <= 32'h0;
        write_value <= 32'h0;
    end

    // Fetch
    always @(posedge clk) begin
        cs <= 1;
        addr <= rw_addr;
        if(stall_fetch) begin
            $display("cpu: STALLED FETCH!");
        end

        if(!stall_fetch) begin
            $display("cpu: Fetching,num=%d", fetch_inst_queue_num);
            addr <= fetch_addr;
            we <= 0; // Read from memory
            // Once we can fetch instructions we save the state, but only if
            // we aren't overwriting something being used by the executor!
            if(rdy && (fetch_inst_queue_num + 1) != execute_inst_queue_num) begin
                $display("cpu: Fetched inst=%b,fetch-num=%d,exec-num=%d", data_in, fetch_inst_queue_num, execute_inst_queue_num);
                // We "clean-path" the element after the one we just placed
                // this ensures there aren't any left-overs from fetching
                fetch_inst_queue[fetch_inst_queue_num] <= data_in;
                fetch_inst_queue[fetch_inst_queue_num + 1] <= OP_TRULY_NOP;
                fetch_inst_queue_num <= fetch_inst_queue_num + 1;
                fetch_addr <= fetch_addr + 4; // Advance to next op
            end
        end else if(state == S_READ) begin
            $display("cpu: S_READ");
            stall_fetch <= 1;
            we <= 0; // Read value and emplace on register
            if(rdy) begin // Appropriately apply masks
                casez(trans_size)
                OP_G1_MV_BYTE: begin // 1-bytes, 4-per-cell
                    regs[read_regno] <= (data_in & 32'hFF) << ((rw_addr & 32'd3) << 32'd3);
                    end
                OP_G1_MV_INT: begin // 2-bytes, 2-per-cell
                    regs[read_regno] <= (data_in & 32'hFFFF) << ((rw_addr & 32'd1) << 32'd4);
                    end
                OP_G1_MV_LONG: begin // 4-bytes, 1-per-cell
                    regs[read_regno] <= (data_in & 32'hFFFFFFFF);
                    end
                endcase
                state <= S_FETCH;
                stall_fetch <= 0;
            end
        end else if(state == S_PREWRITE) begin
            // Prewrite is in charge of reading the value and then writting it back with the desired offset
            // so we can support unaligned accesses
            $display("cpu: S_PREWRITE");
            stall_fetch <= 1;
            we <= 0; // Read the value first
            if(rdy) begin
                // Appropriately apply masks
                casez(trans_size)
                OP_G1_MV_BYTE: begin // 1-bytes, 4-per-cell
                    write_value <= data_in | ((write_value & 32'hFF) << ((rw_addr & 32'd3) << 32'd2));
                    end
                OP_G1_MV_INT: begin // 2-bytes, 2-per-cell
                    write_value <= data_in | ((write_value & 32'hFFFF) << ((rw_addr & 32'd1) << 32'd4));
                    end
                OP_G1_MV_LONG: begin // 4-bytes, 1-per-cell
                    write_value <= data_in | (write_value & 32'hFFFFFFFF);
                    end
                endcase
                state <= S_WRITE;
                $display("cpu: write_value=0x%h,rw_addr=0x%h,data_in=0x%h", write_value, rw_addr, data_in);
            end
        end else if(state == S_WRITE) begin
            $display("cpu: S_WRITE");
            stall_fetch <= 1;
            we <= 1; // Write the value, then return to fetching
            data_out <= write_value;
            if(rdy) begin
                $display("cpu: data_out=0x%h,write_value=0x%h,addr=0x%h", data_out, write_value, addr);
                state <= S_FETCH;
                stall_fetch <= 0;
            end
        end
    end

    // Execution thread
    always @(posedge clk) begin
        if(!stall_execute) begin
            $display("cpu: Execution,num=%d", execute_inst_queue_num);
            execute_inst <= fetch_inst_queue[execute_inst_queue_num];
            execute_inst_queue_num <= execute_inst_queue_num + 1;
            state <= S_FETCH;
            casez(inst_lo)
                // This is an invalid opcode, but used internally as a "true no-op", no PC is modified
                // no anything is modified, good for continuing the executor without stanling
                6'b00_0000: begin
                    $display("cpu: tnop");
                    end
                // JALR [rd], [ra], [imm29]
                OP_JALR: begin
                    $display("cpu: jalr r%d,r%d,[%h]", opreg1, opreg2, { 8'h0, imm16 } << 2);
                    regs[opreg1] <= pc + 4;
                    pc <= regs[opreg2] + ({ 8'h0, imm16 } << 2); // TODO: Sign extend
                    stall_fetch <= 1;
                    state <= S_BRANCHED;
                    end
                // JAL [imm29]
                OP_J_OR_JAL: begin
                    $display("cpu: jal [0x%8h],lr=0x%8h", { 3'h0, imm29 } << 2, pc + 4);
                    if(execute_inst[0] == 1) begin
                        regs[REG_LR] <= pc + 4;
                    end
                    pc <= (pc & 32'h80000000) | ({ 3'h0, imm29 } << 2);
                    stall_fetch <= 1;
                    state <= S_BRANCHED;
                    end
                // BEQ ra, [imm21]
                OP_BEQ: begin
                    $display("cpu: beq r%d,[%h]", opreg1, imm21);
                    if(regs[opreg1] == 32'h0) begin
                        pc <= pc + ({ 9'h0, imm21 } << 2);
                        stall_fetch <= 1;
                        state <= S_BRANCHED;
                    end else begin
                        pc <= pc + 4;
                    end
                    end
                // BNE ra, [imm21]
                OP_BNE: begin
                    $display("cpu: bne r%d,[%h]", opreg1, imm21);
                    if(regs[opreg1] != 32'h0) begin
                        pc <= pc + ({ 9'h0, imm21 } << 2);
                        stall_fetch <= 1;
                        state <= S_BRANCHED;
                    end else begin
                        pc <= pc + 4;
                    end
                    end
                // BLT ra, [imm21]
                OP_BLT: begin
                    $display("cpu: blt r%d,[%h]", opreg1, imm21);
                    if((regs[opreg1] & 32'h80000000) == 0) begin
                        pc <= pc + ({ 9'h0, imm21 } << 2);
                        stall_fetch <= 1;
                        state <= S_BRANCHED;
                    end else begin
                        pc <= pc + 4;
                    end
                    end
                // ADDI [rd], [rd], [imm16]
                OP_ADDI: begin
                    $display("cpu: addi r%d,r%d,[%h]", opreg1, opreg2, imm16);
                    regs[opreg1] = regs[opreg2] + imm16;
                    pc <= pc + 4;
                    end
                // SUBI [rd], [rd], [imm16]
                OP_SUBI: begin
                    $display("cpu: subi r%d,r%d,[%h]", opreg1, opreg2, imm16);
                    regs[opreg1] = regs[opreg2] - imm16;
                    pc <= pc + 4;
                    end
                // SLTI [rd], [rd], [imm16]
                OP_SLTI: begin
                    $display("cpu: slti r%d,r%d,[%h]", opreg1, opreg2, imm16);
                    regs[opreg1] = { 31'h0, regs[opreg2] < imm16 };
                    pc <= pc + 4;
                    end
                // SLTIS [rd], [rd], [imm16]
                OP_SLTIS: begin
                    $display("cpu: sltis r%d,r%d,[%h]", opreg1, opreg2, imm16);
                    // imm16 is positive, register is negative
                    if((regs[opreg2] & 32'h80000000) != 0 && imm16 & 32'h80000000 == 0) begin
                        regs[opreg1] <= 1;
                    // imm16 is negative, register is positive
                    end else if((regs[opreg2] & 32'h80000000) == 0 && imm16 & 32'h80000000 != 0) begin
                        regs[opreg1] <= 0;
                    end else begin
                        regs[opreg1] = { 31'h0, regs[opreg2] < imm16 };
                    end
                    pc <= pc + 4;
                    end
                // ANDI [rd], [rd], [imm16]
                OP_ANDI: begin
                    $display("cpu: andi r%d,r%d,[%h]", opreg1, opreg2, imm16);
                    regs[opreg1] = regs[opreg2] & imm16;
                    pc <= pc + 4;
                    end
                // XORI [rd], [rd], [imm16]
                OP_XORI: begin
                    $display("cpu: xori r%d,r%d,[%h]", opreg1, opreg2, imm16);
                    regs[opreg1] = regs[opreg2] ^ imm16;
                    pc <= pc + 4;
                    end
                // ORI [rd], [rd], [imm16]
                OP_ORI: begin
                    $display("cpu: ori r%d,r%d,[%h]", opreg1, opreg2, imm16);
                    regs[opreg1] = regs[opreg2] | imm16;
                    pc <= pc + 4;
                    end
                // LUI [rd], [rd], [imm16]
                OP_LUI: begin
                    $display("cpu: lui r%d,r%d,[%h]", opreg1, opreg2, imm16);
                    regs[opreg1] = regs[opreg2] | (imm16 << 16);
                    pc <= pc + 4;
                    end
                6'b1?_?011: begin // MOV rd, [ra + imm16]
                    $display("cpu: mov(16) [r%d+%h],r%d,sz=%b", opreg1, { 8'h0, imm16 }, opreg2, inst_lo[4:3]);
                    trans_size <= inst_lo[4:3]; // Check OP_G1_MV_BITMASK
                    read_regno <= opreg1;
                    rw_addr <= regs[opreg2] + { 16'h0, imm16 };
                    state <= S_READ;
                    stall_fetch <= 1;
                    pc <= pc + 4;
                    end
                6'b??_?010: begin // MOV [ra + imm16], rd
                    $display("cpu: mov(5) [r%d+%h],[%d],sz=%b", opreg1, { 8'h0, imm16 }, imm5, inst_lo[4:3]);
                    trans_size <= inst_lo[4:3]; // Check OP_G1_MV_BITMASK
                    if(inst_lo[5] == 0) begin // Write immediate
                        write_value <= { 27'h0, imm5 };
                    end else begin // Write register rb
                        write_value <= regs[opreg2];
                    end
                    rw_addr <= regs[opreg1] + { 16'h0, imm16 };
                    state <= S_PREWRITE;
                    stall_fetch <= 1;
                    pc <= pc + 4;
                    end
                // Instructions starting with 111001
                6'b11_1001: begin
                    $display("cpu: alu_inst r%d,r%d,r%d,instmode=%b,op=%b", opreg1, opreg2, opreg3, opg1_instmode, inst_hi);
                    // Instmode
                    casez(opg1_instmode)
                        OPM_G1_LHS: tmp32 <= regs[opreg3] >> { 26'h0, imm5};
                        OPM_G1_RHS: tmp32 <= regs[opreg3] << { 26'h0, imm5};
                        OPM_G1_ASH: tmp32 <= regs[opreg3] >>> { 26'h0, imm5}; // TODO: What is ASH?
                        OPM_G1_ROR: tmp32 <= regs[opreg3] >>> { 26'h0, imm5};
                    endcase

                    casez(inst_hi[5:2])
                        OP_G1_NOP: begin
                            $display("cpu: nop");
                            regs[opreg1] <= tmp32;
                            end
                        OP_G1_ADD: begin
                            $display("cpu: add");
                            regs[opreg1] <= regs[opreg2] + tmp32;
                            end
                        OP_G1_SUB: begin
                            $display("cpu: sub");
                            regs[opreg1] <= regs[opreg2] - tmp32;
                            end
                        OP_G1_AND: begin
                            $display("cpu: and");
                            regs[opreg1] <= regs[opreg2] & tmp32;
                            end
                        OP_G1_XOR: begin
                            $display("cpu: xor");
                            regs[opreg1] <= regs[opreg2] ^ tmp32;
                            end
                        OP_G1_OR: begin
                            $display("cpu: or");
                            regs[opreg1] <= regs[opreg2] | tmp32;
                            end
                        OP_G1_NOR: begin
                            $display("cpu: nor");
                            regs[opreg1] <= ~(regs[opreg2] | tmp32);
                            end
                        OP_G1_SLT: begin
                            $display("cpu: slti");
                            regs[opreg1] = { 31'h0, regs[opreg2] < tmp32 };
                            end
                        OP_G1_SLTS: begin
                            $display("cpu: sltis");
                            // tmp32 is positive, register is negative
                            if((regs[opreg2] & 32'h80000000) != 0 && tmp32 & 32'h80000000 == 0) begin
                                regs[opreg1] <= 1;
                            // tmp32 is negative, register is positive
                            end else if((regs[opreg2] & 32'h80000000) == 0 && tmp32 & 32'h80000000 != 0) begin
                                regs[opreg1] <= 0;
                            end else begin
                                regs[opreg1] = { 31'h0, regs[opreg2] < tmp32 };
                            end
                            end
                        default: begin end
                    endcase

                    // These high 1 bit is indicative of a MOV, the following 3 bytes MUST have atleast one set
                    if(inst_hi[5] == 1 && (inst_hi[4:2] & 3'b111) != 0) begin
                        casez(inst_hi[5:2])
                            OP_G1_MOV_FR: begin // Move-From-Registers
                                $display("cpu: mov [r%d+r%d+%d],r%d,sz=%b", opreg2, opreg3, imm5, opreg1, inst_hi[3:2]);
                                trans_size <= inst_hi[3:2]; // Check OP_G1_MV_BITMASK
                                write_value <= regs[opreg1];
                                rw_addr <= regs[opreg2] + tmp32;
                                state <= S_PREWRITE;
                                stall_fetch <= 1;
                                end
                            OP_G1_MOV_TR: begin // Move-To-Register
                                $display("cpu: mov r%d,[r%d+r%d+%d],sz=%b", opreg1, opreg2, opreg3, imm5, inst_hi[3:2]);
                                trans_size <= inst_hi[3:2]; // Check OP_G1_MV_BITMASK
                                read_regno <= opreg1;
                                rw_addr <= regs[opreg2] + tmp32;
                                state <= S_READ;
                                stall_fetch <= 1;
                                end
                            default: begin end
                        endcase
                    end
                    pc <= pc + 4;
                    end
                6'b10_1001: begin
                    $display("cpu: privileged_inst");
                    casez(inst_hi[5:2])
                    OP_G2_MFCR: begin
                        $display("cpu: mtcr r%d,cr%d", opreg1, opreg3);
                        regs[opreg1] <= ctl_regs[opreg3];
                        pc <= pc + 4;
                        end
                    OP_G2_MTCR: begin
                        $display("cpu: mtcr cr%d,r%d", opreg3, opreg2);
                        ctl_regs[opreg3] <= regs[opreg2];
                        pc <= pc + 4;
                        end
                    OP_G2_CACHEI: begin
                        $display("cpu: cachei [%h]", imm22);
                        pc <= pc + 4;
                        end
                    OP_G2_HLT: begin
                        $display("cpu: hlt [%h]", imm22);
                        pc <= pc + 4;
                        state <= S_HALT;
                        end
                    default: begin // Invalid instruction
                        $display("cpu: invalid_grp2=0b%b", inst_hi[5:2]);
                        ctl_regs[CREG_EBADADDR] <= pc;
                        pc <= ctl_regs[CREG_EVEC];
                        ctl_regs[CREG_RS][31:28] = ECAUSE_INVALID_INST;
                        end
                    endcase
                    end
                6'b11_0001: begin
                    $display("cpu: advanced_cohost_alu");
                    casez(inst_hi[5:2])
                        OP_G3_BRK: begin
                            $display("cpu: brk [%h]", imm22);
                            // TODO: Is imm22 used at all?
                            ctl_regs[CREG_EBADADDR] <= pc;
                            pc <= ctl_regs[CREG_EVEC];
                            ctl_regs[CREG_RS][31:28] = ECAUSE_BREAKPOINT;
                            stall_fetch <= 1;
                            state <= S_BRANCHED;
                            end
                        OP_G3_DIV: begin
                            if(opreg4 != 5'b0) begin
                                // Raise UD
                                ctl_regs[CREG_EBADADDR] <= pc;
                                pc <= ctl_regs[CREG_EVEC];
                                ctl_regs[CREG_RS][31:28] <= ECAUSE_INVALID_INST;
                                stall_fetch <= 1;
                                state <= S_BRANCHED;
                            end else begin
                                regs[opreg1] = regs[opreg2] / regs[opreg3];
                                pc <= pc + 4;
                            end
                            end
                        OP_G3_DIVS: begin
                            if(opreg4 != 5'b0) begin
                                // Raise UD
                                ctl_regs[CREG_EBADADDR] <= pc;
                                pc <= ctl_regs[CREG_EVEC];
                                ctl_regs[CREG_RS][31:28] <= ECAUSE_INVALID_INST;
                                stall_fetch <= 1;
                                state <= S_BRANCHED;
                            end else begin
                                // TODO: Properly perform signed division
                                regs[opreg1] = { (regs[opreg2][31] | regs[opreg3][31]), (regs[opreg2] / regs[opreg3]) };
                                pc <= pc + 4;
                            end
                            end
                        OP_G3_LL: begin
                            // TODO: Is this a memory access?
                            pc <= pc + 4;
                            end
                        OP_G3_MOD: begin
                            if(opreg4 != 5'b0) begin
                                // Raise UD
                                ctl_regs[CREG_EBADADDR] <= pc;
                                pc <= ctl_regs[CREG_EVEC];
                                ctl_regs[CREG_RS][31:28] <= ECAUSE_INVALID_INST;
                                stall_fetch <= 1;
                                state <= S_BRANCHED;
                            end else begin
                                regs[opreg1] = regs[opreg2] % regs[opreg3];
                                pc <= pc + 4;
                            end
                            end
                        OP_G3_MUL: begin
                            if(opreg4 != 5'b0) begin
                                // Raise UD
                                ctl_regs[CREG_EBADADDR] <= pc;
                                pc <= ctl_regs[CREG_EVEC];
                                ctl_regs[CREG_RS][31:28] <= ECAUSE_INVALID_INST;
                                stall_fetch <= 1;
                                state <= S_BRANCHED;
                            end else begin
                                regs[opreg1] = regs[opreg2] * regs[opreg3];
                                pc <= pc + 4;
                            end
                            end
                        OP_G3_SC: begin
                            // TODO: Is this a memory access?
                            pc <= pc + 4;
                            end
                        OP_G3_SYS: begin
                            $display("cpu: sys [%h]", imm22);
                            // TODO: Is imm22 used at all?
                            ctl_regs[CREG_EBADADDR] <= pc;
                            pc <= ctl_regs[CREG_EVEC];
                            ctl_regs[CREG_RS][31:28] <= ECAUSE_SYSCALL;
                            stall_fetch <= 1;
                            state <= S_BRANCHED;
                            end
                        default: begin
                            end
                    endcase
                    end
                default: begin
                    $display("cpu: invalid_opcode,inst=%b", execute_inst);
                    ctl_regs[CREG_EBADADDR] <= pc;
                    pc <= ctl_regs[CREG_EVEC];
                    ctl_regs[CREG_RS][31:28] <= ECAUSE_INVALID_INST;
                    stall_fetch <= 1;
                    state <= S_BRANCHED;
                end
            endcase

            $display("cpu: state=%d,pc=0x%8h,data_in=0x%8h,data_out=0x%8h,addr=0x%8h", state, pc, data_in, data_out, addr);
            for(integer i = 0; i < 32; i = i + 8) begin
                $display("cpu: %2d=0x%8h,%2d=0x%8h,%2d=0x%8h,%2d=0x%8h,%2d=0x%8h,%2d=0x%8h,%2d=0x%8h,%2d=0x%8h", i, regs[i], i + 1, regs[i + 1], i + 2, regs[i + 2], i + 3, regs[i + 3], i + 4, regs[i + 4], i + 5, regs[i + 5], i + 6, regs[i + 6], i + 7, regs[i + 7]);
            end
        end else if(state == S_BRANCHED) begin
            // This is used to update the fetch address after an exception or PC, meaning we have to stall
            // so let's unstall fetcher
            fetch_addr <= pc;
            stall_fetch <= 0;
        end
    end

    // Fetch the element from SRAM with 32-bits per unit of data
    // rememeber that we also need to write bytes so unaligned accesses
    // are allowed by the CPU because fuck you
    always @(posedge clk) begin

    end
endmodule

`endif
