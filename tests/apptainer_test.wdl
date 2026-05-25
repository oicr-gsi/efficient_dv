version 1.0


task apptainer_test {
  String modules = "apptainer/1.4.5"
  String dockerImage = "/.mounts/labs/gsi/testdata/efficient_dv/docker_images/ubuntu.sif"
  Int jobMemory = 8

  command <<<
    export APPTAINER_TMPDIR=/tmp
    apptainer exec \
      --bind ${PWD}:${PWD} \
      ~{dockerImage} \
      echo "Hello from inside container"
      uname -a
  >>>

  runtime {
    memory:  "~{jobMemory} GB"
    modules: "~{modules}"
  }

  output {
    String msg = read_string(stdout())
  }
}

workflow apptainer_test {
  
  meta {
    author: "Peter Ruzanov"
    email: "peter.ruzanov@oicr.on.ca"
    description: "A workflow testing apptainer module abilities to load and work with docker containers"
  }


  call apptainer_test

  output {
    String out = apptainer_test.msg
  }
}
