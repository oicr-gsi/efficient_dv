version 1.0

task gpu_test {
 input {  
   String message = "Test message"
 }

  command <<<
    echo "Running on GPU node"
    echo "~{message}"
    nvidia-smi || echo "No GPU detected"
  >>>

  runtime {
    memory: "6 GB"
    queue: "gpu.q"
    gpuCount: 1
  }

  output {
    String out = read_string(stdout())
  }
}

workflow test_gpu {
  input { 
    String? optionalMessage
  }

  call gpu_test {input: message = optionalMessage}
}
