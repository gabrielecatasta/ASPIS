#!/bin/bash

cmake --build build

echo "=== saxpy ==="
./aspis_cuda_cuspis.sh --no-cleanup --eddi --no-cfc -g -o saxpy_out testing/tests/cuda/saxpy.cu 2>&1 | tail -3
./saxpy_out

echo "=== axpy ==="
./aspis_cuda_cuspis.sh --no-cleanup --eddi --no-cfc -g -o axpy_out examples/cuda/axpy/axpy.cu 2>&1 | tail -3
grep -c "cuspis.replica1" host_linked.ll
grep -c "cuspisMemcpyToHostEPvS0_PKvm(ptr" host_linked.ll
grep -c "^_ZN6CUSPIS" compiled_eddi_functions.csv
./axpy_out 2>&1 | grep -iE "mismatch|avg"

echo "=== conv ==="
./aspis_cuda_cuspis.sh --no-cleanup --eddi --no-cfc -g -o conv_out examples/cuda/conv/conv.cu 2>&1 | tail -3
grep -c "invoke.*cuspisMalloc" host_linked.ll
./conv_out gpu 2>&1 | grep -E "Mean|Policy"