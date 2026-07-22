version 1.0

# OICR NOTICE: Multiple tasks were modified to use docker containers via Apptainer (former Singularity) developed by Berkeley National Lab
# Some of the tasks were switched to use modules rather than docker containers 
# Other optimizations were introduced to make the code work in SLURM cluster environment

import "structs.wdl" as Structs
task UGMakeExamples{
  input{
    Array[File] cram_files
    Array[File] cram_index_files
    File interval
    Float total_number_of_shards
    Float overall_calling_regions_length
    Float genome_length
    References references

    # Background sample inputs
    Array[File] background_cram_files
    Array[File] background_cram_index_files

    File? germline_vcf
    File? pangenome_haplotypes
    File? pangenome_haplotypes_index

    Int min_base_quality
    Int pileup_min_mapping_quality
    Int min_read_count_snps
    Int min_read_count_hmer_indels
    Int min_read_count_non_hmer_indels
    Float min_fraction_snps
    Float min_fraction_hmer_indels
    Float min_fraction_non_hmer_indels
    Float min_fraction_single_strand_non_snps
    Int? min_hmer_plus_one_candidate
    Int candidate_min_mapping_quality
    Int max_reads_per_partition
    Int assembly_min_base_quality
    Boolean make_gvcf
    Float p_error = 0
    Int gq_resolution = 5
    Array[Int]? gq_bins
    Boolean prioritize_alt_supporting_reads    
    Array[Int] optimal_coverages
    Boolean cap_at_optimal_coverage
    Boolean is_somatic
    Boolean output_realignment = false
    Boolean single_strand_filter = false
    Boolean keep_duplicates = true
    Boolean add_ins_size_channel = true
    String? extra_args
    Boolean log_progress = false
    Boolean count_candidates_with_dvtools = false
    Boolean normalize_strand_bias = false
    Array[Float]? strand_bias_normalization_thresholds

    # Pre-calculated median coverage values
    Int median_coverage
    Int background_median_coverage

    String docker
    String modules = "gatk/4.6.2.0 samtools/1.14 apptainer/1.4.5"
    File monitoring_script
    Float jobMemory
    Int threads
    Int timeout = 24
    Int preemptible_tries
    String cloud_provider = "gcp"
    Boolean no_address = true
  }
  # Estimate output_size that fits candidate generated parameters (assuming constant image size)
  #   More sensitive thresholds (such as used for somatic variant detection) yield more examples (images)
  #   which consume more disk-space, regardless of the input-size.
  Float min_fraction_hmer_indels_trimmed = if (min_fraction_hmer_indels < 0.12) then min_fraction_hmer_indels else 0.12
  Float min_fraction_non_hmer_indels_trimmed = if (min_fraction_non_hmer_indels < 0.12) then min_fraction_non_hmer_indels else 0.12
  Float min_fraction_snps_trimmed  = if (min_fraction_snps < 0.12) then min_fraction_snps else 0.12
  # We calculate the disk_size additivly on the 3 thresholds we have

  # min_fraction_hmer_indels
  Array[Float] min_fraction_hmer_indels_values = [15786, 7659, 3597, 2169, 1266, 879, 627, 487, 381, 306, 283, 243]
  Float min_fraction_hmer_indels_value = min_fraction_hmer_indels_values[
          if (min_fraction_hmer_indels_trimmed*100)-1 < 0
          then 0 else floor(min_fraction_hmer_indels_trimmed*100)-1]/1.5

  # min_fraction_hmer_indels
  Array[Float] min_fraction_snps_values = [9531, 5067, 2358, 1776, 1380, 1134, 948, 817, 708, 672, 650, 626]
  Float min_fraction_snps_value = min_fraction_snps_values[
        if (min_fraction_snps_trimmed*100)-1 < 0
        then 0 else floor(min_fraction_snps_trimmed*100)-1]/1.5

  # min_fraction_hmer_indels
  Array[Float] min_fraction_non_hmer_values = [5244, 2829, 1446, 1074, 798, 624, 483, 392, 314, 251, 217, 182]
  Float min_fraction_non_hmer_value = min_fraction_non_hmer_values[
        if (min_fraction_non_hmer_indels_trimmed*100)-1 < 0
        then 0 else floor(min_fraction_non_hmer_indels_trimmed*100)-1]/1.5

  Float expected_genome_wide_output_size = min_fraction_hmer_indels_value +
                                            min_fraction_snps_value +
                                            min_fraction_non_hmer_value
  Float shard_region_length = overall_calling_regions_length / total_number_of_shards
  Float shard_region_fraction_of_genome = shard_region_length / genome_length
  Int realigned_bam_size = if output_realignment then
                           7 * ceil(size(cram_files, "GB") / total_number_of_shards) else 0
  Int expected_output_size = ceil(expected_genome_wide_output_size * shard_region_fraction_of_genome + realigned_bam_size)
  Int inputs_size =  ceil(size(cram_files, "GB") / total_number_of_shards + size(references.ref_fasta, "GB"))

  Float c_i = 1.3  # inputs safety factor
  Float c_o = 1.3 # outputs safety factor
  Int disk_size = ceil(c_i * inputs_size + c_o * expected_output_size)

  String output_prefix = basename(interval, ".interval_list")
  Boolean defined_background = length(background_cram_files) > 0

  Array[Float] strand_bias_normalization_thresholds_defined = select_first([strand_bias_normalization_thresholds, [0.5,0.5]])
  Array[Int] gq_bins_defined = select_first([gq_bins, []])
  
  parameter_meta {
      cram_files: {
          localization_optional: true
      }
      background_cram_files: {
          localization_optional: true
      }
  }

  command <<<
    set -xeo pipefail

    bash ~{monitoring_script} | tee monitoring.log >&2 &

    if [[ "~{cloud_provider}" != "aws" ]]; then
      gatk --java-options "-Xms2G" PrintReads \
          -I ~{sep=' -I ' cram_files} \
          -O /dev/stdout \
          -L ~{interval} \
          -R ~{references.ref_fasta} |\
      samtools view -C -T ~{references.ref_fasta} -o input.cram --output-fmt-option embed_ref=1 -

      samtools index input.cram -@ ~{threads}
      input=input.cram
      input_index=input.cram.crai

      background=''
      background_index=''
      if [[ "~{defined_background}" == "true" ]]; then
        gatk --java-options "-Xms2G" PrintReads \
            -I  ~{sep=' -I ' background_cram_files} \
            -O /dev/stdout \
            -L ~{interval} \
            -R ~{references.ref_fasta} |\
        samtools view -C -T ~{references.ref_fasta} -o background.cram --output-fmt-option embed_ref=1 -

        samtools index background.cram -@ ~{threads}
        background=background.cram
        background_index=background.cram.crai
      fi

    else
      input=~{sep=',' cram_files}
      input_index=~{sep=',' cram_index_files}
      background=~{sep=',' background_cram_files}
      background_index=~{sep=',' background_cram_index_files}
    fi

    echo 'Input files are:'
    echo $input
    echo $input_index
    echo $background
    echo $background_index

    input_string="~{true='$input;$background' false='$input' defined_background}"
    input_index_string="~{true='$input_index;$background_index' false='$input_index' defined_background}"

    echo 'Input strings are:'
    echo $input_string
    echo $input_index_string

    # Create empty files such that outputs will still be valid even if cloud is aws
    touch input.cram
    touch input.cram.crai
    touch background.cram
    touch background.cram.crai

    # Link the haplotypes cram and index into the same directory, as the tool expects the haplotypes cram and index to be in the same directory with the same prefix as the input cram
    if [ "~{defined(pangenome_haplotypes)}" == "true" ]
    then
      ln -s "~{pangenome_haplotypes}" "$(basename ~{pangenome_haplotypes})"
      ln -s "~{pangenome_haplotypes_index}" "$(basename ~{pangenome_haplotypes_index})"
    fi

    # Process interval file
    grep -v @ ~{interval} | awk 'BEGIN{OFS="\t"}{print $1,$2-1,$3}' >> interval.bed

    # split the interval file into parts for parallel processing (number of parts as number of cpus)
    echo 'splitting interval into ~{threads} parts'
    total_lines=$(wc -l < interval.bed)
    lines_per_file=$((total_lines / ~{threads}))
    remainder=$((total_lines % ~{threads}))
    if [ $remainder -ne 0 ]; then
      lines_per_file=$((lines_per_file + 1))
    fi

    split -l $lines_per_file -d --additional-suffix .bed interval.bed interval_ #should create files: interval_00.bed, interval_01.bed, etc.

    echo 'Splited interval.bed content:'
    for file in interval_*.bed; do
      echo "$file content:"
      cat "$file"
      echo -n "interval size is: "
      awk '{sum += $3 - $2} END {print sum}' "$file"
    done
    
    #shellcheck disable=SC2034
    st_bias_norm_thresholds_string="--strand-bias-threshold-to-normalize ~{sep=',' strand_bias_normalization_thresholds_defined}"

    gq_bins_str=' --gq-thresholds "~{sep=',' gq_bins_defined}"'
    gq_resolution_str="--gq-resolution ~{gq_resolution}"
    if ~{make_gvcf}; then
      if "~{defined(gq_bins)}" ; then
        gvcf_extra_args="$gq_bins_str"
      else
        gvcf_extra_args="$gq_resolution_str"
      fi
    else
      gvcf_extra_args=""
    fi

    # parallel processing: run the tool in different process, each on a different interval part
    pids=()
    export APPTAINER_TMPDIR=/tmp
    REF=$(readlink -f ~{references.ref_fasta})
    REFDIR=${REF%/*}
    for interval_part in $(find . -name "interval_*.bed" | sort); do
      part_number=$(echo "$interval_part" | grep -o -E '[0-9]+') #extract the part number from the file name
      apptainer exec \
        --bind ${PWD}:${PWD},${REFDIR}:${REFDIR} \
        --userns \
        ~{docker} \
        tool \
        --input "$input_string" \
        --cram-index "$input_index_string" \
        --output "~{output_prefix}_$part_number" \
        --reference ${REF} \
        --bed "$interval_part" \
        --median-coverage ~{median_coverage} \
        --background-median-coverage ~{background_median_coverage} \
        --min-base-quality ~{min_base_quality} \
        --min-mapq ~{pileup_min_mapping_quality} \
        --cgp-min-count-snps ~{min_read_count_snps} \
        --cgp-min-count-hmer-indels ~{min_read_count_hmer_indels} \
        --cgp-min-count-non-hmer-indels ~{min_read_count_non_hmer_indels} \
        --cgp-min-fraction-snps ~{min_fraction_snps} \
        --cgp-min-fraction-hmer-indels ~{min_fraction_hmer_indels} \
        --cgp-min-fraction-non-hmer-indels ~{min_fraction_non_hmer_indels} \
        --cgp-min-fraction-single-strand-non-snps ~{min_fraction_single_strand_non_snps} \
        --cgp-min-mapping-quality ~{candidate_min_mapping_quality} \
        --cgp-min-hmer-plus-one-candidate ~{if defined(min_hmer_plus_one_candidate) then min_hmer_plus_one_candidate else 7} \
        --max-reads-per-region ~{max_reads_per_partition} \
        --assembly-min-base-quality ~{assembly_min_base_quality} \
        ~{true="--realigned-sam" false="" output_realignment} \
        ~{true="--somatic" false="" is_somatic} \
        ~{if make_gvcf then "--gvcf --p-error ~{p_error} $gvcf_extra_args" else ""} \
        --optimal-coverages "~{sep=";" optimal_coverages}" \
        ~{true="--cap-at-optimal-coverage " false="" cap_at_optimal_coverage} \
        ~{true="--prioritize-alt-supporting-reads " false="" prioritize_alt_supporting_reads} \
        ~{true="--normalize-strand-bias" false="" normalize_strand_bias} \
        ~{true="$st_bias_norm_thresholds_string" false="" normalize_strand_bias } \
        --cycle-examples-min 100000 \
        --prefix-logging-with "${part_number}>> " \
        ~{true="--single-strand-filter" false="" single_strand_filter} \
        ~{true="--keep-duplicates" false="" keep_duplicates} \
        ~{true="--add-ins-size-channel" false="" add_ins_size_channel} \
        ~{extra_args} \
        ~{true="--progress" false="" log_progress} \
        ~{if defined(germline_vcf) then "--region-haplotypes-vcf ~{germline_vcf}" else ""} \
        ~{if defined(pangenome_haplotypes) then "--exp-pangenome-haps $(basename ~{pangenome_haplotypes})" else ""} \
         &
      # Save the PID of the process
      pids+=($!)
    done

  # Wait for the process running the tool to finish (don't wait for the process running the monitor log)
  # if one process is failed, kill all the other processes and exit with error
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      echo "ERROR occurred. View error using: *** for prefix in \"00>>\" \"01>>\"; do cat log | grep \"^\$prefix\" | tail; done; *** Killing all other processes and exiting."
      for other_pid in "${pids[@]}"; do
        if [ "$other_pid" != "$pid" ]; then
          kill "$other_pid"
        fi
      done
      exit 1
    fi
  done

  if [ ~{output_realignment} == "true" ]
  then
      # merge the output ~{output_prefix}_hap_out.sam files into one CRAM file
      samtools merge -@ ~{threads} ~{output_prefix}_unsorted.bam ~{output_prefix}_*_hap_out.sam
      samtools sort -@ ~{threads} -o ~{output_prefix}_realign.bam ~{output_prefix}_unsorted.bam
      samtools index ~{output_prefix}_realign.bam -@ ~{threads}
      ls -lh ~{output_prefix}_realign.bam
  fi
  touch "~{output_prefix}_realign.bam"
  touch "~{output_prefix}_realign.bam.bai"

  ls -lh -- *tfrecord*

  if [ ~{count_candidates_with_dvtools} == "true" ]
  then
    for tfrec in $(find . -name '*tfrecord*' | sort); do
      dvtools --infile "$tfrec" --filetype dv --op vcf --outfile "$tfrec.vcf"
      echo "$tfrec: $(wc -l < "$tfrec.vcf")"
      rm "$tfrec.vcf"
    done
  fi

  find . -type f -name "~{output_prefix}*[0-9].tfrecord.gz" | sort > output_files.list
  find . -type f -name "~{output_prefix}*.gvcf.tfrecord.gz" | sort > output_gvcf_files.list
  find . -type f -name "~{output_prefix}*.json" | sort > output_json_files.list
  find . -type f -name "~{output_prefix}*.gatk" | sort > output_gatk_files.list

  >>>
  runtime {
    memory: "~{jobMemory} GB"
    cpu: "~{threads}"
    modules: "~{modules}"
    timeout: "~{timeout}"
  }
  output {
    File monitoring_log = "monitoring.log"
    File input_cram = "input.cram"
    File input_cram_index = "input.cram.crai"
    File background_cram  = "background.cram"
    File background_cram_index = "background.cram.crai"
    File realigned_cram = "~{output_prefix}_realign.bam"
    File realigned_cram_index = "~{output_prefix}_realign.bam.bai"
    Array[File] output_examples = read_lines("output_files.list") 
    Array[File?] gvcf_records = read_lines("output_gvcf_files.list") 
    Array[File] output_jsons = read_lines("output_json_files.list") 
    Array[File] output_gatk = read_lines("output_gatk_files.list") 
  }
}


task UGCallVariants{
  input{
    Array[File] examples
    File model_onnx
    File? model_serialized
    Boolean is_somatic
    String docker
    Int call_variants_uncompr_buf_size_gb
    String gpu_type
    String modules = "apptainer/1.4.5"
    Int num_gpus
    Int num_cpus
    Int num_threads
    Int timeout = 24
    File monitoring_script
    Int? call_variants_extra_mem
    Int? optimization_level
    Boolean no_address = true
    
    # Ensemble parameters
    Int ensemble_size = 0
    Int random_seed = 42
    Int reference_rows = 5
    
    # Multi-sample parameters
    Array[Int] sample_heights  # Height of each sample (e.g., [100,100] or [100])
    Boolean shuffle_all_samples = false
  }

  Int disk_size = ceil(1.05*size(examples, 'GB') + 10)
  Int num_examples = length(examples)
  Int extra_mem = select_first([call_variants_extra_mem, 8])
  Int builder_optimization_level  = select_first([optimization_level, if is_somatic then 5 else 1])
  Int mem = num_threads * call_variants_uncompr_buf_size_gb + extra_mem
  String onnx_base_name = basename(model_onnx)
  command <<<
    set -eo pipefail

    bash ~{monitoring_script} | tee monitoring.log >&2 &

    nvidia-smi --query-gpu=timestamp,name,driver_version,temperature.gpu,utilization.gpu,utilization.memory,memory.used --format=csv -l 60 -f  ./nvidia-smi.log & #todo change from old

    cp ~{model_onnx} ~{onnx_base_name}
    # Rename the serialized model to fit the onnx file (allow various versions of serialized model files with different file names)        
    if [ "~{defined(model_serialized)}" == "true" ] && [ "~{model_serialized}" != "~{model_onnx}.serialized" ]
    then
      echo 'Renaming serialized model to fit onnx file'
      cp ~{model_serialized} ~{onnx_base_name}.serialized
    fi

    printf "%b\n" "[RT classification]" \
      "onnxFileName = ~{onnx_base_name}" \
      "builderOptimizationLevel = ~{builder_optimization_level}" \
      "useSerializedModel = 1" \
      "trtWorkspaceSizeMB = 2000" \
      "numInferTreadsPerGpu = 2" \
      "useGPUs = ~{num_gpus}" \
      "gpuid = 0\n" \
      "[debug]" \
      "logFileFolder = .\n" \
      "[ensemble]" \
      "ensembleSize = ~{ensemble_size}" \
      "randomSeed = ~{random_seed}" \
      "referenceRows = ~{reference_rows}" \
      "sampleHeights = ~{sep=',' sample_heights}" \
      "shuffleAllSamples = ~{true='true' false='false' shuffle_all_samples}\n" \
      "[general]" \
      "tfrecord = 1" \
      "compressed = 1" \
      "outputInOneFile = 0" \
      "numUncomprThreads = ~{num_threads}" \
      "uncomprBufSizeGB = ~{call_variants_uncompr_buf_size_gb}" \
      "outputFileName = call_variants" \
      "numConversionThreads = 2" \
      "numExampleFiles = ~{num_examples}\n" > params.ini

    
    i=1
    EXDIR=""
    
    for f in ~{sep=' ' examples}; do
      real=$(readlink -f "$f")
      printf "exampleFile%d = %s\n" "$i" "$real" >> params.ini
      # only for the first file
      if [[ $i -eq 1 ]]; then
        dir=$(dirname "$real")
        EXDIR=$(echo "$dir" | sed 's|\(.*UGMakeExamples\).*|\1|')
      fi
      ((i++))
    done

    export APPTAINER_TMPDIR=/tmp
    apptainer exec \
        --bind ${PWD}:${PWD},${EXDIR}:${EXDIR} \
        --userns \
        --nv \
        ~{docker} \
        call_variants --param params.ini --fp16

    num_candidates_val=$(grep -oP 'total batch size \K\d+(?= vectors)' call_variants*.log)
    echo "$num_candidates_val" > "num_candidates_${num_candidates_val}"
    echo "$num_candidates_val" > nc.txt
    find . -type f -name "call_variants*.log" > log_files.txt
    find . -type f -name "call_variants*.gz" > callvariants_files.txt
    find . -type f -name "num_candidates_*" > candidates_files.txt
  >>>
  runtime {
    memory: "~{mem} GB"
    queue: "gpu.q"
    gpuCount: "~{num_gpus}"
    modules: "~{modules}"
    timeout: "~{timeout}"
  }
output {
    File monitoring_log = "monitoring.log"
    File nvidia_smi_log = "nvidia-smi.log"
    File params = "params.ini"
    Array[File] log = read_lines("log_files.txt") 
    Array[File] output_records = read_lines("callvariants_files.txt") 
    Array[File] num_candidates = read_lines("candidates_files.txt") 
    Int num_candidates_as_int = read_int("nc.txt")
    File output_model_serialized = "~{onnx_base_name}.serialized"
  }
}

task UGSplitBoundaryCalls {
  input {
    Array[File] examples
    Array[File] calls
    Float boundary_threshold
    String docker
    String modules = "apptainer/1.4.5"
    Int timeout = 12
    File monitoring_script
    Int preemptible_tries
    Boolean no_address
  }
  Int disk_size = ceil(1.1*size(examples, 'GB') + 1.1*size(calls, 'GB') + 10)
  command <<<
    set -exo pipefail
    examples_file=~{write_lines(examples)}
    calls_file=~{write_lines(calls)}
    export APPTAINER_TMPDIR=/tmp
    bash ~{monitoring_script} | tee monitoring.log >&2 &
    mkdir boundary_examples
    mkdir strong_calls
    sort -t "." -k2,2n $calls_file > sorted_calls.txt
    paste -d "\t" $examples_file sorted_calls.txt > input_pairs.txt
    cat input_pairs.txt
    while IFS=$'\t' read -r example call; do
      example_basename=$(basename "$example")
      echo "[$(date +%T)] Processing line $((++line_count)) of $(wc -l < input_pairs.txt)"
      call_basename=$(basename "$call")
      apptainer exec \
        --bind ${PWD}:${PWD} \
        --userns \
        ~{docker} \
      dvtools --infile "$call" --op ensembleSplit --filetype cvo \
      --ensembleSplitThreshold ~{boundary_threshold} \
      --ensembleSplitInputDV "$example" \
      --outfile "strong_calls/${call_basename}" \
      --ensembleSplitOutputDV "boundary_examples/${example_basename}"
    done < input_pairs.txt

    find . -type f -name "strong_calls/*.gz" > strong_calls.txt
    find . -type f -name "boundary_examples/*.tfrecord.gz" > boundary_examples.txt

  >>>
  runtime {
    memory: "8 GB"
    modules: "~{modules}"
    timeout: "~{timeout}"
    cpu: 2
  }
  output {
    Array[File] strong_calls = read_lines("strong_calls.txt") 
    Array[File] boundary_examples = read_lines("boundary_examples.txt") 
    File monitoring_log = "monitoring.log"
  } 
}

task UGPostProcessing{
  input{
    Array[File] called_records
    Array[File] cram_files
    Array[File] cram_index_files

    # Background sample inputs
    Array[File] background_cram_files
    Array[File] background_cram_index_files

    File ref
    File ref_index
    String docker
    String output_prefix
    File exome_intervals
    Array[File]? annotation_intervals
    File? dbsnp
    File? dbsnp_index
    String flow_order
    String modules = "apptainer/1.4.5 bcftools/1.9"
    Int qual_filter
    Int timeout = 12
    Array[File]? gvcf_records
    Boolean make_gvcf
    Boolean recalibrate_vaf
    Boolean is_somatic
    Int min_variant_quality_hmer_indels
    Int min_variant_quality_exome_hmer_indels
    Int min_variant_quality_non_hmer_indels
    Int min_variant_quality_snps
    Boolean show_bg_fields
    String extra_args = ""

    File monitoring_script

    Int disk_size = ceil(48 * size(called_records, "GB") +
                         size(ref, "GB") +
                         (if defined(dbsnp) then size(dbsnp, "GB") else 0) +
                         (if make_gvcf then size(select_first([gvcf_records]), "GB") else 0) +
                         4 + (if make_gvcf then 5 else 0)) +
                         ceil(size(background_cram_files, "GB")) +
                         ceil(size(cram_files, "GB")) +
                         ceil(size(cram_index_files, "GB")) +
                         ceil(size(background_cram_index_files, "GB"))
    Boolean no_address = true
  }

  Int indel_threshold_for_recalibration = 30000

  String gvcf_args = if make_gvcf then "--gvcf_outfile ~{output_prefix}.g.vcf.gz --nonvariant_site_tfrecord_path @gvcf_records.txt --hcr_bed_file ~{output_prefix}.hcr.bed " else ""
  Array[File] gvcf_records_not_opt = select_first([gvcf_records, []])
  Array[File] empty_array_of_files = []
  Array[File] annotation_intervals_or_empty = select_first([annotation_intervals, empty_array_of_files])
  Array[File] exome_and_annotations = flatten([[exome_intervals], annotation_intervals_or_empty])
  Boolean defined_background = length(background_cram_files) > 0

  command <<<
      bash ~{monitoring_script} | tee monitoring.log >&2 &
      set -xeo pipefail

      echo 'Defining filters...'
      printf "%b\n" "LowQualInExome" \
        "QUAL < ~{min_variant_quality_exome_hmer_indels} and VARIANT_TYPE=='h-indel' and not vc.isFiltered() and vc.hasAttribute('EXOME')" \
        "LowQual" \
        "QUAL < ~{min_variant_quality_hmer_indels} and VARIANT_TYPE=='h-indel' and not vc.isFiltered() and not vc.hasAttribute('EXOME')" \
        "LowQual" \
        "QUAL < ~{min_variant_quality_non_hmer_indels} and VARIANT_TYPE=='non-h-indel' and not vc.isFiltered()" \
        "LowQual" \
        "QUAL < ~{min_variant_quality_snps} and VARIANT_TYPE=='snp' and not vc.isFiltered()" \
        "LargeDeletion" \
        "REFLEN > 220 and vc.isFiltered()" \
        > filters.txt

      if [ ~{make_gvcf} == "true" ]
      then
        cp ~{write_lines(gvcf_records_not_opt)} gvcf_records.txt
      fi


      declare -A seen_dirs

      # shellcheck disable=SC2034
      # Resolve all files and collect directories (foreground)
      for f in ~{sep=' ' cram_files}; do
        real_f=$(readlink -f "$f")
        resolved_files_f+=("$real_f")
        parent_dir=$(dirname "$real_f")
        seen_dirs["$parent_dir"]=1
      done

      foreground_files_csv=$(IFS=, ; echo "${resolved_files_f[*]}")      
      # shellcheck disable=SC2034
      # Resolve all files and collect directories (background, if we have them)
      for f in ~{sep=' ' background_cram_files}; do
        real_f=$(readlink -f "$f")
        resolved_files_b+=("$real_f")
        parent_dir=$(dirname "$real_f")
        seen_dirs["$parent_dir"]=1
      done

      background_files_csv=$(IFS=, ; echo "${resolved_files_b[*]}")      
      cram_string="~{true='$foreground_files_csv;$background_files_csv' false='$foreground_files_csv' defined_background}"

      echo "Calculating approximate INDEL variant count"
      export APPTAINER_TMPDIR=/tmp
      REF=$(readlink -f ~{ref})
      REFDIR=${REF%/*}

      # readlink the calls, we need the paths of real files, not symlinks, also CALLDIR needs to be bound 
      i=1
      CALLDIR=""
      for f in ~{sep=' ' called_records}; do
        real=$(readlink -f "$f")
        echo $real >> called_records.txt
        # only for the first file
        if [[ $i -eq 1 ]]; then
          dir=$(dirname "$real")
          CALLDIR=$(echo "$dir" | sed 's|\(.*CallVariantNoEnsemble\).*|\1|')
        fi
        ((i++))
      done

      # readlink exon files
      for f in ~{sep=' ' exome_and_annotations}; do
        real=$(readlink -f "$f")
        files_real+=("$real")
        dir=$(dirname "$real")
        seen_dirs["$dir"]=1
      done

      # build bind arguments (we also use dirs for input crams retrieved earlier)
      BIND_ARGS=""

      for d in "${!seen_dirs[@]}"; do
        BIND_ARGS+=" --bind $d:$d"
      done

      files_csv=$(IFS=,; echo "${files_real[*]}")

      apptainer exec \
        --bind ${PWD}:${PWD} \
        --bind ${REFDIR}:${REFDIR} \
        --bind ${CALLDIR}:${CALLDIR} \
        $BIND_ARGS \
        --userns \
        ~{docker} \
        ug_postproc \
          --infile @called_records.txt \
          --ref ${REF} \
          --outfile "~{output_prefix}.vcf.gz" \
          --qual_filter ~{qual_filter} \
          --count_indels --group_variants false |& tee indel.count.log

      indel_count=$( grep indel_count indel.count.log | cut -d " " -f 4 )
      echo "Approximate INDEL variant count: $indel_count"
      if [ "$indel_count" -gt ~{indel_threshold_for_recalibration} ]
      then
        echo "INDEL variant count is too high, skipping post-processing"
        recalibration_string=""
      else 
        echo "INDEL variant count is low, recalibrating VAF"
        # shellcheck disable=SC2034
        recalibration_string="--fix_allele_coverage --fix_allele_indels_only --fix_allele_crams $cram_string"
      fi
     

      echo 'Running UG post-processing...'
      apptainer exec \
        --bind ${PWD}:${PWD} \
        --bind ${REFDIR}:${REFDIR} \
        --bind ${CALLDIR}:${CALLDIR} \
        $BIND_ARGS \
        --userns \
        ~{docker} \
        ug_postproc \
          --infile @called_records.txt \
          --ref ${REF} \
          --outfile "~{output_prefix}.vcf.gz" \
          ~{gvcf_args} \
          --consider_strand_bias \
          --flow_order ~{flow_order} \
          --annotate \
          --bed_annotation_files "$files_real" \
          --qual_filter ~{qual_filter} \
          --filter \
          --filters_file filters.txt \
          ~{if defined(dbsnp) then "--dbsnp " + dbsnp else ""} \
          ~{if show_bg_fields then "--consider_bg_fields" else ""} \
          ~{if recalibrate_vaf then '$recalibration_string' else ""} \
          ~{if is_somatic then "--ignore_multi_allelic_cvos" else ""} \
          ~{extra_args}

      bcftools index -t "~{output_prefix}.vcf.gz"
      if [ ~{make_gvcf} == "true" ]
      then
        bcftools index -t "~{output_prefix}.g.vcf.gz"
      fi

      touch "~{output_prefix}.g.vcf.gz"
      touch "~{output_prefix}.g.vcf.gz.tbi"
      touch "~{output_prefix}.hcr.bed"

    echo 'Saving header IDs to a file...'
    export header_file=header.hdr
    export id_file=header.ID
    export all_ids=all_ids.txt

    for f in ~{sep=" " exome_and_annotations}
    do
      head -1 $f > $header_file
      sed 's/[<>]/ /' "$header_file" | sed 's/[=]/ /' | sed 's/[=]/ /' | sed 's/[,]/ /' | awk '{print $3}' > $id_file
      cat $id_file >> $all_ids
    done

  >>>
  runtime {
    memory: "8 GB"
    cpu: "1"
    modules: "~{modules}"
    timeout: "~{timeout}"
  }
  output {
    File monitoring_log = "monitoring.log"
    File vcf_file  = '~{output_prefix}.vcf.gz'
    File vcf_index = '~{output_prefix}.vcf.gz.tbi'
    File gvcf_file = '~{output_prefix}.g.vcf.gz'
    File gvcf_file_index = '~{output_prefix}.g.vcf.gz.tbi'
    File gvcf_hcr = '~{output_prefix}.hcr.bed'
    Array[String] interval_annotation_names = read_lines('all_ids.txt')
  }
}


task QCReport{
  input{
    File input_vcf
    File input_vcf_index
    File? callable_bed
    String output_prefix
    File ref
    File monitoring_script
    String modules = "bcftools/1.9 apptainer/1.4.5"
    String docker
    Int jobMemory = 8
  }

  command <<<
      set -eo pipefail
      bash ~{monitoring_script} | tee monitoring.log >&2 &

      echo 'Filtering PASS variants...'
      bcftools view -f PASS -O z ~{input_vcf} -o ~{output_prefix}.pass.vcf.gz
      bcftools index -t ~{output_prefix}.pass.vcf.gz

      REF=$(readlink -f ~{ref})
      REFDIR=${REF%/*}
      BIND_ARGS=" --bind $REFDIR:$REFDIR"

      if [ -f callable_bed ]; then
       CBED=$(readlink -f ~{callable_bed})
       CBDIR=${CBED%/*}
       HCRBED="--hcr_bed $CBED"
       BIND_ARGS+=" --bind $CBDIR:$CBDIR"
      fi


      echo 'Running QC reprort...'
      export APPTAINER_TMPDIR=/tmp
      apptainer exec \
        --bind ${PWD}:${PWD} \
        ${BIND_ARGS} \
        --userns \
        ~{docker} \
          python /opt/deepvariant/qc_report/run_no_gt_report.py \
          --input_file "~{output_prefix}.pass.vcf.gz" \
          --reference ${REF} \
          ${HCRBED} \
          --output_prefix "~{output_prefix}" \
          --output_metrics_h5
  >>>
  runtime {
    memory: "~{jobMemory} GB"
    modules: "~{modules}"
  }
  output {
    File monitoring_log = "monitoring.log"
    File qc_h5     = '~{output_prefix}.h5'
    File qc_report = '~{output_prefix}_report.html'
    File qc_metrics_h5 = '~{output_prefix}_metrics.h5'
  }
}

task GenerateQuickCoverageBed {
  input {
    File target_intervals
    File ref_dict
    String modules = "gatk/4.6.2.0"
    File monitoring_script
    Int num_points = 2000
  }

  Int disk_size = 10

  command <<<
    set -xeo pipefail
    bash ~{monitoring_script} | tee monitoring.log >&2 &

    # Convert interval list to BED format
    gatk IntervalListToBed -I ~{target_intervals} -O target_intervals.bed

    # Calculate total length of intervals
    total_length=$(awk '{sum += $3 - $2} END {printf "%.0f\n", sum}' target_intervals.bed)
    echo "Total interval length: $total_length"
    
    # Calculate average distance between points
    if [[ $total_length -eq 0 ]]; then
      echo "Error: No intervals found"
      exit 1
    fi
    
    avg_distance=$(echo "scale=0; $total_length / ~{num_points}" | bc -l)
    if [[ $avg_distance -eq 0 ]]; then
      avg_distance=1
    fi
    echo "Average distance between points: $avg_distance"
    
    # Generate uniformly distributed points
    export AVG_DISTANCE=$avg_distance
    export NUM_POINTS=~{num_points}
    
    python3 << 'EOF'
import os

avg_distance = max(1, int(os.environ['AVG_DISTANCE']))
num_points = int(os.environ['NUM_POINTS'])

points_generated = 0
with open('target_intervals.bed', 'r') as f, open('quick_coverage.bed', 'w') as out:
    for line in f:
        if line.strip():
            parts = line.strip().split('\t')
            chrom = parts[0]
            start = int(parts[1])
            end = int(parts[2])
            
            # Generate points at avg_distance intervals within this interval
            current_pos = start
            while current_pos < end and points_generated < num_points:
                # Write bed format: chr start end (where start = end - 1 for single position)
                out.write(f"{chrom}\t{current_pos}\t{current_pos + 1}\n")
                points_generated += 1
                current_pos += avg_distance
            
            if points_generated >= num_points:
                break

print(f"Generated {points_generated} coverage points")
EOF

    # Ensure we have a valid output file
    if [[ ! -s quick_coverage.bed ]]; then
      echo "Error: Failed to generate coverage bed file"
      exit 1
    fi
    
    echo "Successfully generated $(wc -l < quick_coverage.bed) coverage points"
  >>>

  runtime {
    memory: "2 GB"
    cpu: 1
    modules: "~{modules}"
  }

  output {
    File quick_coverage_bed = "quick_coverage.bed"
    File monitoring_log = "monitoring.log"
  }
}
