version 1.0

task docker_test {
  command <<<
    echo "Hello from inside container"
    uname -a
  >>>

  runtime {
    docker: "ubuntu:22.04"
    cpu: 1
    memory_mb: 1000
  }

  output {
    String msg = read_string(stdout())
  }
}

workflow test_docker {
  call docker_test
}
