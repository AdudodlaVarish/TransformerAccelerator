VERILATOR ?= verilator
PYTHON ?= python3
VFLAGS = --binary --timing --assert -Wall -Wno-fatal
GEMM_RTL = rtl/requantize.sv rtl/systolic_array.sv rtl/tiled_gemm.sv
STREAM_RTL = $(GEMM_RTL) rtl/transformer_gemm_accelerator.sv
DMA_RTL = $(STREAM_RTL) rtl/transformer_axi_dma.sv
TOP_RTL = $(DMA_RTL) rtl/accelerator_control.sv rtl/transformer_accelerator_top.sv
TINY_RTL = $(STREAM_RTL) rtl/attention_score.sv rtl/attention_softmax.sv \
	rtl/layer_norm.sv rtl/transformer_activation.sv
RTL_TESTS = test-systolic test-tiled test-stream test-softmax test-layernorm \
	test-activation test-attention test-control test-dma8 test-dma4 test-tiny test-top

.PHONY: test benchmark clean \
	test-systolic test-tiled test-stream test-softmax test-layernorm \
	test-activation test-attention test-control test-dma8 test-dma4 test-python \
	test-tiny test-top

test: test-systolic test-tiled test-stream test-softmax test-layernorm \
	test-activation test-attention test-control test-dma8 test-dma4 test-python \
	test-tiny test-top

$(RTL_TESTS) benchmark: | obj_dir

obj_dir:
	mkdir -p $@

test-systolic:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/systolic --top-module tb_systolic_array rtl/systolic_array.sv sim/tb_systolic_array.sv
	./obj_dir/systolic/Vtb_systolic_array

test-tiled:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/tiled --top-module tb_tiled_gemm $(GEMM_RTL) sim/tb_tiled_gemm.sv
	./obj_dir/tiled/Vtb_tiled_gemm

test-stream:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/stream --top-module tb_transformer_gemm_accelerator $(STREAM_RTL) sim/tb_transformer_gemm_accelerator.sv
	./obj_dir/stream/Vtb_transformer_gemm_accelerator

test-softmax:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/softmax --top-module tb_attention_softmax rtl/attention_softmax.sv sim/tb_attention_softmax.sv
	./obj_dir/softmax/Vtb_attention_softmax

test-layernorm:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/layernorm --top-module tb_layer_norm rtl/layer_norm.sv sim/tb_layer_norm.sv
	./obj_dir/layernorm/Vtb_layer_norm

test-activation:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/activation --top-module tb_transformer_activation rtl/transformer_activation.sv sim/tb_transformer_activation.sv
	./obj_dir/activation/Vtb_transformer_activation

test-attention:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/attention --top-module tb_attention_pipeline rtl/requantize.sv rtl/attention_score.sv rtl/attention_softmax.sv sim/tb_attention_pipeline.sv
	./obj_dir/attention/Vtb_attention_pipeline

test-control:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/control --top-module tb_accelerator_control rtl/accelerator_control.sv sim/tb_accelerator_control.sv
	./obj_dir/control/Vtb_accelerator_control

test-dma8:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/dma8 --top-module tb_transformer_axi_dma $(DMA_RTL) sim/tb_transformer_axi_dma.sv
	./obj_dir/dma8/Vtb_transformer_axi_dma

test-dma4:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/dma4 -GDATA_WIDTH=4 --top-module tb_transformer_axi_dma $(DMA_RTL) sim/tb_transformer_axi_dma.sv
	./obj_dir/dma4/Vtb_transformer_axi_dma

test-tiny:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/tiny --top-module tb_tiny_transformer $(TINY_RTL) sim/tb_tiny_transformer.sv
	./obj_dir/tiny/Vtb_tiny_transformer

test-top:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/top --top-module tb_transformer_accelerator_top $(TOP_RTL) sim/tb_transformer_accelerator_top.sv
	./obj_dir/top/Vtb_transformer_accelerator_top

test-python:
	$(PYTHON) -B sw/test_runtime.py
	$(PYTHON) -B sw/tiny_transformer_demo.py
	$(PYTHON) -B sw/benchmark.py --functional --rows 4 --cols 4 --k-tile 4 --m 4 --n 4 --k 4 --iterations 1

benchmark:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/benchmark -GROWS=16 -GCOLS=16 -GK=16 -GK_TILES=1 --top-module tb_transformer_axi_dma $(DMA_RTL) sim/tb_transformer_axi_dma.sv
	./obj_dir/benchmark/Vtb_transformer_axi_dma

clean:
	rm -rf obj_dir
