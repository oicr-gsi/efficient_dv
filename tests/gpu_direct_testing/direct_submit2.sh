#!/bin/bash
qsub \
-terse \
-V \
-b y \
-N directGPU2 \
-cwd \
-o stdout2.qsub \
-e stderr2.qsub \
-l h_vmem=6.0g \
-l h_rt=5:00:00 \
-l os=20.04 \
-l gpu=1 \
-P gsi \
-q gpu.q \
"/usr/bin/env bash ./gpu_test.sh"
