#!/bin/bash

echo "Running on GPU node"
echo "My Other message"
nvidia-smi || echo "No GPU detected"
