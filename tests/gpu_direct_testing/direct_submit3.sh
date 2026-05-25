#!/bin/bash
qsub \
-terse \
-V \
-b y \
-N directGPU3 \
-cwd \
-o stdout3.qsub \
-e stderr3.qsub \
-l h_rt=1:00:00 \
-l gpu=1 \
-l cuda.0.name=Tesla* \
-P gsi \
-q gpu.q \
"/usr/bin/env bash ./gpu_test.sh"
