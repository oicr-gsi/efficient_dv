version 1.0

import "structs.wdl" as Structs

# OICR NOTICE: Multiple tasks were modified to use docker containers via Apptainer (former Singularity) developed by Berkeley National Lab
# Some of the tasks were switched to use modules rather than docker containers
# Other optimizations were introduced to make the code work in SLURM cluster environment
task ApplyQualFilters {
  input{
    File input_vcf
    File input_vcf_index
    Int min_variant_quality_hmer_indels
    Int min_variant_quality_exome_hmer_indels
    Int min_variant_quality_non_hmer_indels
    Int min_variant_quality_snps
    String final_vcf_base_name
    File monitoring_script
    String gatk_docker
    String gitc_path
    String modules = "apptainer/1.4.5"
    Int jobMemory = 15
    Int timeout = 12
  }
  Int disk_size = ceil(3 * size(input_vcf, "GB") + 1 )
  String output_file = "~{final_vcf_base_name}.annotated.qual_filters.vcf.gz"
  command <<<
    bash ~{monitoring_script} | tee monitoring.log >&2 &

    set -xeo pipefail

    export APPTAINER_TMPDIR=/tmp
    INPUT=$(readlink -f ~{input_vcf})
    INPUITDIR=${INPUT%/*}
    apptainer exec \
      --bind ${PWD}:${PWD},${INPUTDIR}:${INPUTDIR} \
      --userns \
      ~{gatk_docker} \
      java -XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -Xms10000m \
      -jar ~{gitc_path}/GATK_ultima.jar VariantFiltration \
      -V ${INPUT} \
      -O ~{output_file} \
      -filter "QUAL < ~{min_variant_quality_exome_hmer_indels} and VARIANT_TYPE=='h-indel' and not vc.isFiltered() and vc.hasAttribute('EXOME')" \
      --filter-name LowQualHmerIndelsInExome \
      -filter "QUAL < ~{min_variant_quality_hmer_indels} and VARIANT_TYPE=='h-indel' and not vc.isFiltered() and not vc.hasAttribute('EXOME')" \
      --filter-name LowQualHmerIndels \
      -filter "QUAL < ~{min_variant_quality_non_hmer_indels} and VARIANT_TYPE=='non-h-indel' and not vc.isFiltered()" \
      --filter-name LowQualNonHmerIndels \
      -filter "QUAL < ~{min_variant_quality_snps} and VARIANT_TYPE=='snp' and not vc.isFiltered()" \
      --filter-name LowQualSNVs 

  >>>
  runtime {
    memory: "~{jobMemory} GB"
    modules: "~{modules}"
    timeout: "~{timeout}"
  }
   output {
    File monitoring_log = "monitoring.log"
    File output_vcf = output_file
    File output_vcf_index = "~{output_file}.tbi"
  }
}

task ApplyAlleleFrequencyRatioFilter {
  input{
    File input_vcf
    Float af_ratio
    Float? h_indel_vaf_to_pass
    Float? h_indel_vaf_ratio_to_pass
    String final_vcf_base_name
    String modules = "apptainer/1.4.5"
    File monitoring_script
    Int jobMemory = 8
    Int timeout = 12
    String ugbio_filtering_docker
    Boolean no_address = true
  }
  Int disk_size = ceil(3 * size(input_vcf, "GB") + 1 )
  String output_file = "~{final_vcf_base_name}.annotated.filt.afRatio.vcf.gz"
  command <<<
    bash ~{monitoring_script} | tee monitoring.log >&2 &
 
    set -xeo pipefail
    export APPTAINER_TMPDIR=/tmp
    INPUT=$(readlink -f ~{input_vcf})
    INPUTDIR=${INPUT%/*}
    apptainer exec \
      --bind ${PWD}:${PWD},${INPUTDIR}:${INPUTDIR} \
      --userns \
      ~{ugbio_filtering_docker} \
      filter_low_af_ratio_to_background --af_ratio_threshold ~{af_ratio} \
                                        --new_filter "LowAFRatioToBackground"  \
                                        ~{"--af_ratio_threshold_h_indels " + h_indel_vaf_ratio_to_pass} \
                                        ~{"--tumor_vaf_threshold_h_indels " + h_indel_vaf_to_pass} \
                                        ${INPUT} ~{output_file}
    
   >>>
  runtime {
    memory: "~{jobMemory} GB"
    timeout: "~{timeout}"
    modules: "~{modules}"
  }
   output {
    File monitoring_log = "monitoring.log"
    File output_vcf = output_file
    File output_vcf_index = "~{output_file}.tbi"
  }
}

task RemoveRefCalls {
  input{
    File input_vcf
    String final_vcf_base_name
    File monitoring_script
    String modules = "bcftools/1.9"
    Int jobMemory = 4
    Int timeout = 10
  }
  Int disk_size = ceil(3 * size(input_vcf, "GB") + 1 )
  String output_file = "~{final_vcf_base_name}.annotated.filt.vcf.gz"

  command <<<
    bash ~{monitoring_script} | tee monitoring.log >&2 &

    set -xeo pipefail

    bcftools view -i 'FILTER!="RefCall"' ~{input_vcf} -Oz -o ~{output_file}
    bcftools index -t ~{output_file}

  >>>
  runtime {
    memory: "~{jobMemory} GB"
    modules: "~{modules}"
    timeout: "~{timeout}"
  }
   output {
    File monitoring_log = "monitoring.log"
    File output_vcf = output_file
    File output_vcf_index = "~{output_file}.tbi"
  }
}

task CalibrateBridgingSnvs { 
    input{
        File input_vcf
        File input_vcf_index
        References references
        String final_vcf_base_name
        File monitoring_script
        String ugvc_docker
    }

    String output_file = "~{final_vcf_base_name}.fix_bridge_snvs.vcf.gz"
    
    command <<<
      bash ~{monitoring_script} | tee monitoring.log >&2 &
      source ~/.bashrc
      conda activate genomics.py3
      set -xeo pipefail
      
      python /VariantCalling/ugvc calibrate_bridging_snvs \
      --vcf ~{input_vcf} \
      --reference ~{references.ref_fasta} \
      --output ~{output_file} 

    >>>
    runtime {
      memory: "4 GB"
      docker: ugvc_docker
    }
    output {
      File monitoring_log = "monitoring.log"
      File output_vcf = output_file
      File output_vcf_index = "~{output_file}.tbi"
  }
}
