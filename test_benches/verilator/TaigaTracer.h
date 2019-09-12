/*
 * Copyright © 2019 Eric Matthews,  Lesley Shannon
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
 *             Eric Matthews <ematthew@sfu.ca>
 */

#ifndef TaigaTracer_H
#define TaigaTracer_H
#include <stdlib.h>
#include <iostream>
#include <iterator>
#include "SimMem.h"

//#define TRACE_ON

#define COMPLIANCE_SIG_PHASE_NOP 0x00B00013U
#define ERROR_TERMINATION_NOP 0x00F00013U
#define SUCCESS_TERMINATION_NOP 0x00A00013U

template <typename T, int N>
constexpr int arraySize(T(&)[N]) { return N; }

static const char * const eventNames[] = {
    "operand_stall",
    "unit_stall",
    "no_id_stall",
    "no_instruction_stall",
    "other_stall",
    "instruction_issued_dec",
    "branch_misspredict",
    "return_misspredict",
    "wb_mux_contention",
    "rs1_forwarding_needed",
    "rs2_forwarding_needed",
    "rs1_and_rs2_forwarding_needed"
};
static const int numEvents = arraySize(eventNames);

//Testbench with Taiga trace outputs on toplevel
template <class TB>
class TaigaTracer {
public:
  TaigaTracer(std::ifstream& programFile);
  ~TaigaTracer();
  bool check_instruction_issued(uint32_t inst);
  bool has_terminated();
  bool has_stalled();
  void print_stats();
  void reset_stats();
  void reset();
  void tick();
  void set_log_file(std::ofstream* logFile);
  void start_tracer(const char *trace_file);
  uint64_t get_cycle_count();
private:
  TB *tb;
  SimMem *mem;
#ifdef TRACE_ON
		VerilatedVcdC	*verilatorWaveformTracer;
#endif
  std::ofstream* logFile;
  int reset_length = 64;
  int stall_limit = 2000;
  int stall_count = 0;
  uint64_t cycle_count = 0;
  uint64_t event_counters[numEvents];

  void update_stats();
  void update_UART();
  void update_memory();
  uint32_t instruction_r;
  uint32_t data_out_r;
};

#include "TaigaTracer.cc"

#endif
