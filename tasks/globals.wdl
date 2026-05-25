version 1.0

# OICR NOTICE: Multiple tasks were modified to use docker containers via Apptainer (former Singularity) developed by Berkeley National Lab
# This particular file was to modified so that configuration tells us where pre-loaded docker images reside
# the paths are and should be absolute, no symlinks here

struct GlobalVariables {
  String ubuntu_docker
  String broad_gatk_docker
  String ug_call_variants_docker
  String ug_make_examples_docker
  String bcftools_docker
  String monitoring_script
  String ugbio_filtering_docker
}
workflow Globals {
  input {
  GlobalVariables glob ={
        "ubuntu_docker": "/.mounts/labs/gsi/testdata/efficient_dv/docker_images/ubuntu.sif",
        "broad_gatk_docker": "broadinstitute/gatk:4.6.0.0",
        "ug_call_variants_docker": "/.mounts/labs/gsi/testdata/efficient_dv/docker_images/call_variants.sif",
        "ug_make_examples_docker": "/.mounts/labs/gsi/testdata/efficient_dv/docker_images/make_examples.sif",
        "bcftools_docker": "staphb/bcftools:1.19",
        "monitoring_script": "/.mounts/labs/gsi/testdata/efficient_dv/docker_images/load_images.sh",
        "ugbio_filtering_docker": "/.mounts/labs/gsi/testdata/efficient_dv/docker_images/ugbio_filtering.sif"
}
}

  output {
    GlobalVariables global_dockers = glob
  }
}

