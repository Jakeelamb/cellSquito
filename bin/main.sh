#!/bin/bash


# main.sh - Master control script for mosquito RNA-seq pipeline
# This script identifies input files, sets up directories, and manages job dependencies

#SBATCH --job-name=main
#SBATCH --output=./logs/main_%j.out
#SBATCH --error=./logs/main_%j.err

# Source conda
source ~/.bashrc

# Default values - use current directory as base
current_dir=$(pwd)
raw_reads_dir="${current_dir}/data/raw_reads"
result_base="${current_dir}/results"
logs_base="${current_dir}/logs"  # Changed to be at the same level as results
draft_transcriptome=""

# Parse command line arguments
while getopts ":R:h" opt; do
  case ${opt} in
    R )
      draft_transcriptome=$OPTARG
      ;;
    h )
      echo "Usage: $0 [-R /path/to/reference/transcriptome] [raw_reads_dir] [result_base] [logs_base]"
      echo "  -R: Path to reference transcriptome (optional)"
      echo "  raw_reads_dir: Directory with raw fastq files (default: ./data/raw_reads)"
      echo "  result_base: Base directory for all results (default: ./results)"
      echo "  logs_base: Base directory for all logs (default: ./logs)"
      exit 0
      ;;
    \? )
      echo "Invalid option: -$OPTARG" 1>&2
      exit 1
      ;;
    : )
      echo "Option -$OPTARG requires an argument." 1>&2
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))

# Override defaults with positional arguments if provided
if [ "$1" != "" ]; then
  raw_reads_dir=$1
fi
if [ "$2" != "" ]; then
  result_base=$2
fi
if [ "$3" != "" ]; then
  logs_base=$3
fi

# Create logs directory before sourcing parameters to ensure SLURM output has a place to go
mkdir -p "${logs_base}"

# Source parameters file
source config/parameters.txt

# Check if the conda environment exists and create it only if needed
if ! conda info --envs | grep -q "cellSquito"; then
    echo "Creating cellSquito conda environment..."
    conda env create -f config/cellSquito.yml -n cellSquito
else
    echo "cellSquito conda environment already exists"
fi

# Create more specific output directories
trimmed_dir="${result_base}/01_trimmed"         # Directory for fastp output
merged_dir="${result_base}/02_merged"           # Directory for merged reads
assembly_dir="${result_base}/03_assembly"       # Output directory for rnaSpades
quality_dir="${result_base}/04_quality"         # Parent directory for quality results
busco_dir="${quality_dir}/busco"                # Output directory for busco
rnaquast_dir="${quality_dir}/rnaquast"          # Output directory for rnaquast
draft_busco_dir="${quality_dir}/draft_busco"    # BUSCO results for draft transcriptome
draft_rnaquast_dir="${quality_dir}/draft_rnaquast"  # rnaQuast results for draft
viz_dir="${result_base}/05_visualization"       # Output directory for visualizations

# Create improved log directory structure
trim_logs="${logs_base}/01_trimming"          # Logs for trimming
merge_logs="${logs_base}/02_merge"            # Logs for merging
assembly_logs="${logs_base}/03_assembly"      # Logs for assembly
busco_logs="${logs_base}/04_busco"            # Logs for BUSCO
rnaquast_logs="${logs_base}/04_rnaquast"      # Logs for rnaQuast
viz_logs="${logs_base}/05_visualization"      # Logs for visualization
summary_logs="${logs_base}/summaries"         # Logs for summary reports

# Create output and log directories
mkdir -p "$trimmed_dir" "$merged_dir" "$assembly_dir" "$busco_dir" "$rnaquast_dir" \
         "$draft_busco_dir" "$draft_rnaquast_dir" "$viz_dir"
mkdir -p "$trim_logs" "$merge_logs" "$assembly_logs" "$busco_logs" "$rnaquast_logs" \
         "$viz_logs" "$summary_logs"

# Create temporary directory for file lists
temp_dir="${result_base}/temp"
mkdir -p "$temp_dir"
r1_trimmed_list="${temp_dir}/r1_trimmed_files.txt"
r2_trimmed_list="${temp_dir}/r2_trimmed_files.txt"
> "$r1_trimmed_list"  # Clear contents
> "$r2_trimmed_list"  # Clear contents

# Print pipeline information
echo "===== Mosquito RNA-Seq Pipeline ====="
echo "Raw reads directory: $raw_reads_dir"
echo "Results directory: $result_base"
echo "Log files: $logs_base"
echo "======================================="

# Step 1: Identify read pairs
echo "Identifying read pairs..."
if [[ ! -d "$raw_reads_dir" ]]; then
    echo "Error: Raw reads directory $raw_reads_dir does not exist!"
    exit 1
fi

# Check if directory is empty
if [[ -z "$(ls -A $raw_reads_dir)" ]]; then
    echo "Error: Raw reads directory $raw_reads_dir is empty!"
    exit 1
fi

# Function to check job status
check_job_status() {
    local job_id=$1
    local job_name=$2
    
    # Wait a moment for the job to be registered in the system
    sleep 2
    
    # Check if job exists
    if ! scontrol show job $job_id &>/dev/null; then
        echo "Error: Job $job_id ($job_name) does not exist or was cancelled!"
        return 1
    fi
    
    # Check job state
    local state=$(scontrol show job $job_id | grep JobState | awk '{print $1}' | cut -d= -f2)
    if [[ "$state" == "FAILED" ]]; then
        echo "Error: Job $job_id ($job_name) failed!"
        return 1
    fi
    
    return 0
}

# Pairing read files based on naming patterns
echo "Pairing read files based on naming patterns..."
samples=()
r1_files_array=()
r2_files_array=()
paired_found=0

# Common naming patterns for paired-end reads
patterns=(
    "_R1_001.fastq.gz:_R2_001.fastq.gz"
    "_R1.fastq.gz:_R2.fastq.gz"
    "_1.fastq.gz:_2.fastq.gz"
    "_1.fq.gz:_2.fq.gz"
    "_R1.fq.gz:_R2.fq.gz"
)

# Find all potential R1 files
r1_files=$(find "$raw_reads_dir" -type f -name "*R1*.fastq.gz" -o -name "*_1.fastq.gz" -o -name "*_1.fq.gz" -o -name "*R1*.fq.gz")

for r1_file in $r1_files; do
    for pattern in "${patterns[@]}"; do
        r1_suffix=$(echo $pattern | cut -d: -f1)
        r2_suffix=$(echo $pattern | cut -d: -f2)
        
        if [[ "$r1_file" == *"$r1_suffix" ]]; then
            # Construct the expected R2 filename
            r2_file="${r1_file/$r1_suffix/$r2_suffix}"
            
            # Check if the R2 file exists
            if [[ -f "$r2_file" ]]; then
                # Extract sample name from filename
                base_name=$(basename "$r1_file" "$r1_suffix")
                samples+=("$base_name")
                r1_files_array+=("$r1_file")
                r2_files_array+=("$r2_file")
                paired_found=$((paired_found + 1))
                break  # Found a matching pattern, move to the next file
            fi
        fi
    done
done

echo "Found $paired_found paired read files:"
for ((i=0; i<${#samples[@]}; i++)); do
    echo "  Sample: ${samples[$i]}"
    echo "    R1: ${r1_files_array[$i]}"
    echo "    R2: ${r2_files_array[$i]}"
done

if [[ $paired_found -eq 0 ]]; then
    echo "Error: No read pairs found in $raw_reads_dir"
    exit 1
fi

# Step 2: Submit jobs in sequence with dependencies
# Step 2.1: Submit trimming jobs for each pair
echo "Submitting trimming jobs..."
trim_job_ids=()
for ((i=0; i<${#samples[@]}; i++)); do
    sample="${samples[$i]}"
    r1="${r1_files_array[$i]}"
    r2="${r2_files_array[$i]}"
    
    # Set output files for trimming
    trim_r1="${trimmed_dir}/${sample}_R1_trimmed.fastq"
    trim_r2="${trimmed_dir}/${sample}_R2_trimmed.fastq"
    
    # Add to the list of trimmed files for merging
    echo "$trim_r1" >> $r1_trimmed_list
    echo "$trim_r2" >> $r2_trimmed_list
    
    echo "Submitting trimming job for sample $sample"
    # Submit trimming job with specific log directory and files
    job_id=$(sbatch --parsable \
             --partition="${fastp_partition}" \
             --time="${fastp_time}" \
             --nodes=${fastp_nodes} \
             --cpus-per-task=${fastp_cpu_cores_per_task} \
             --mem="${fastp_mem}" \
             --output="${trim_logs}/trim_${sample}_%j.out" \
             --error="${trim_logs}/trim_${sample}_%j.err" \
             bin/01_trimming.sh "$r1" "$r2" "$trim_r1" "$trim_r2" "$sample" "$trim_logs")
    
    # Check if job submission was successful
    if [[ $? -ne 0 || -z "$job_id" ]]; then
        echo "Error: Failed to submit trimming job for sample $sample"
        exit 1
    fi
    
    # Verify job was submitted correctly
    if ! check_job_status "$job_id" "trim_${sample}"; then
        echo "Warning: Job verification failed for trimming job $job_id"
        # Continue anyway, as the job might still be in queue
    fi
    
    trim_job_ids+=($job_id)
    echo "  Job ID: $job_id"
done

# Wait a moment to ensure all jobs are registered
sleep 5

# Step 2.2: Submit merging job (depends on all trimming jobs)
echo "Preparing to submit merging job..."
# Create dependency string for merge job to wait for all trimming jobs
if [[ ${#trim_job_ids[@]} -gt 0 ]]; then
    # Join job IDs with colons
    trim_dependency="afterok"
    for job_id in "${trim_job_ids[@]}"; do
        trim_dependency+=":$job_id"
    done
    
    echo "Dependency string: $trim_dependency"
    
    # Set output for merged files
    merged_r1="${merged_dir}/merged_R1.fastq"
    merged_r2="${merged_dir}/merged_R2.fastq"
    
    echo "Submitting merging job with dependency: $trim_dependency"
    merge_job_id=$(sbatch --parsable \
                  --partition="${cat_partition}" \
                  --time="${cat_time}" \
                  --nodes=${cat_nodes} \
                  --cpus-per-task=${cat_cpu_cores_per_task} \
                  --mem="${cat_mem}" \
                  --dependency=$trim_dependency \
                  --output="${merge_logs}/merge_%j.out" \
                  --error="${merge_logs}/merge_%j.err" \
                  bin/02_merge.sh "$r1_trimmed_list" "$r2_trimmed_list" "$merged_r1" "$merged_r2" "$merge_logs")
    
    # Check if job submission was successful
    if [[ $? -ne 0 || -z "$merge_job_id" ]]; then
        echo "Error: Failed to submit merge job"
        exit 1
    fi
    
    # Verify job was submitted correctly
    if ! check_job_status "$merge_job_id" "merge"; then
        echo "Warning: Job verification failed for merge job $merge_job_id"
        # Continue anyway, as the job might still be in queue
    fi
    
    echo "  Merge job ID: $merge_job_id"
else
    echo "Error: No trimming jobs were submitted successfully"
    exit 1
fi

# Step 2.3: Submit assembly job (depends on merge job)
echo "Preparing to submit assembly job..."
echo "Submitting assembly job with dependency: afterok:$merge_job_id"
assembly_job_id=$(sbatch --parsable \
                 --partition="${rnaSpades_partition}" \
                 --time="${rnaSpades_time}" \
                 --nodes=${rnaSpades_nodes} \
                 --cpus-per-task=${rnaSpades_cpu_cores_per_task} \
                 --mem="${rnaSpades_mem}" \
                 --dependency=afterok:$merge_job_id \
                 --output="${assembly_logs}/assembly_%j.out" \
                 --error="${assembly_logs}/assembly_%j.err" \
                 bin/03_assembly.sh "$merged_r1" "$merged_r2" "$assembly_dir" "${rnaSpades_opts}" "$assembly_logs")

# Check if job submission was successful
if [[ $? -ne 0 || -z "$assembly_job_id" ]]; then
    echo "Error: Failed to submit assembly job"
    exit 1
fi

# Verify job was submitted correctly
if ! check_job_status "$assembly_job_id" "assembly"; then
    echo "Warning: Job verification failed for assembly job $assembly_job_id"
    # Continue anyway, as the job might still be in queue
fi

echo "  Assembly job ID: $assembly_job_id"

# Step 2.4: Submit quality assessment jobs (depend on assembly job)
echo "Preparing to submit quality assessment jobs..."
# Set assembly output file
assembly_fasta="${assembly_dir}/transcripts.fasta"

# Submit BUSCO job
echo "Submitting BUSCO job with dependency: afterok:$assembly_job_id"
busco_job_id=$(sbatch --parsable \
              --partition="${busco_partition}" \
              --time="${busco_time}" \
              --nodes=${busco_nodes} \
              --cpus-per-task=${busco_cpu_cores_per_task} \
              --mem="${busco_mem}" \
              --dependency=afterok:$assembly_job_id \
              --output="${busco_logs}/busco_%j.out" \
              --error="${busco_logs}/busco_%j.err" \
              bin/04_busco.sh "$assembly_fasta" "$busco_dir" "./busco_downloads" "new_assembly" "$busco_logs")

# Check if job submission was successful
if [[ $? -ne 0 || -z "$busco_job_id" ]]; then
    echo "Error: Failed to submit BUSCO job"
    exit 1
fi

# Verify job was submitted correctly
if ! check_job_status "$busco_job_id" "busco"; then
    echo "Warning: Job verification failed for BUSCO job $busco_job_id"
    # Continue anyway, as the job might still be in queue
fi

echo "  BUSCO job ID: $busco_job_id"

# Submit rnaQuast job
echo "Submitting rnaQuast job with dependency: afterok:$assembly_job_id"
rnaquast_job_id=$(sbatch --parsable \
                 --partition="${rnaQuast_partition}" \
                 --time="${rnaQuast_time}" \
                 --nodes=${rnaQuast_nodes} \
                 --cpus-per-task=${rnaQuast_cpu_cores_per_task} \
                 --mem="${rnaQuast_mem}" \
                 --dependency=afterok:$assembly_job_id \
                 --output="${rnaquast_logs}/rnaquast_%j.out" \
                 --error="${rnaquast_logs}/rnaquast_%j.err" \
                 bin/04_rnaquast.sh "$assembly_fasta" "$rnaquast_dir" "$merged_r1" "$merged_r2" "${rnaQuast_opts}" "$rnaquast_logs")

# Check if job submission was successful
if [[ $? -ne 0 || -z "$rnaquast_job_id" ]]; then
    echo "Error: Failed to submit rnaQuast job"
    exit 1
fi

# Verify job was submitted correctly
if ! check_job_status "$rnaquast_job_id" "rnaquast"; then
    echo "Warning: Job verification failed for rnaQuast job $rnaquast_job_id"
    # Continue anyway, as the job might still be in queue
fi

echo "  rnaQuast job ID: $rnaquast_job_id"

# Draft transcriptome analysis (if available)
draft_busco_job_id=""
draft_rnaquast_job_id=""
if [[ -n "$draft_transcriptome" && -f "$draft_transcriptome" ]]; then
    echo "Found draft transcriptome: $draft_transcriptome"
    echo "Submitting BUSCO job for draft transcriptome"
    draft_busco_job_id=$(sbatch --parsable \
                        --partition="${busco_partition}" \
                        --time="${busco_time}" \
                        --nodes=${busco_nodes} \
                        --cpus-per-task=${busco_cpu_cores_per_task} \
                        --mem="${busco_mem}" \
                        --output="${busco_logs}/draft_busco_%j.out" \
                        --error="${busco_logs}/draft_busco_%j.err" \
                        bin/04_busco.sh "$draft_transcriptome" "$draft_busco_dir" "./busco_downloads" "draft_assembly" "$busco_logs")
    
    # Check if job submission was successful
    if [[ $? -ne 0 || -z "$draft_busco_job_id" ]]; then
        echo "Error: Failed to submit draft BUSCO job"
        # Continue anyway, as this is optional
    else
        echo "  Draft BUSCO job ID: $draft_busco_job_id"
    fi

    echo "Submitting rnaQuast job for draft transcriptome"
    draft_rnaquast_job_id=$(sbatch --parsable \
                           --partition="${rnaQuast_partition}" \
                           --time="${rnaQuast_time}" \
                           --nodes=${rnaQuast_nodes} \
                           --cpus-per-task=${rnaQuast_cpu_cores_per_task} \
                           --mem="${rnaQuast_mem}" \
                           --output="${rnaquast_logs}/draft_rnaquast_%j.out" \
                           --error="${rnaquast_logs}/draft_rnaquast_%j.err" \
                           bin/04_rnaquast.sh "$draft_transcriptome" "$draft_rnaquast_dir" "$merged_r1" "$merged_r2" "${rnaQuast_opts}" "$rnaquast_logs")
    
    # Check if job submission was successful
    if [[ $? -ne 0 || -z "$draft_rnaquast_job_id" ]]; then
        echo "Error: Failed to submit draft rnaQuast job"
        # Continue anyway, as this is optional
    else
        echo "  Draft rnaQuast job ID: $draft_rnaquast_job_id"
    fi
fi

# Step 2.5: Submit visualization job (depends on all quality assessment jobs)
echo "Preparing to submit visualization job..."
# Create dependency string for visualization - include draft jobs if they exist
viz_dependency="afterok:$busco_job_id:$rnaquast_job_id"
if [[ -n "$draft_transcriptome" && -f "$draft_transcriptome" && -n "$draft_busco_job_id" && -n "$draft_rnaquast_job_id" ]]; then
    viz_dependency="$viz_dependency:$draft_busco_job_id:$draft_rnaquast_job_id"
    # Pass both new and draft directories
    viz_job_id=$(sbatch --parsable \
                --partition="${visualize_partition}" \
                --time="${visualize_time}" \
                --nodes=${visualize_nodes} \
                --cpus-per-task=${visualize_cpu_cores_per_task} \
                --mem="${visualize_mem}" \
                --dependency=$viz_dependency \
                --output="${viz_logs}/visualize_%j.out" \
                --error="${viz_logs}/visualize_%j.err" \
                bin/05_visualize.sh "$busco_dir" "$rnaquast_dir" "$viz_dir" "$draft_busco_dir" "$draft_rnaquast_dir" "$viz_logs")
else
    viz_job_id=$(sbatch --parsable \
                --partition="${visualize_partition}" \
                --time="${visualize_time}" \
                --nodes=${visualize_nodes} \
                --cpus-per-task=${visualize_cpu_cores_per_task} \
                --mem="${visualize_mem}" \
                --dependency=$viz_dependency \
                --output="${viz_logs}/visualize_%j.out" \
                --error="${viz_logs}/visualize_%j.err" \
                bin/05_visualize.sh "$busco_dir" "$rnaquast_dir" "$viz_dir" "" "" "$viz_logs")
fi

# Check if job submission was successful
if [[ $? -ne 0 || -z "$viz_job_id" ]]; then
    echo "Error: Failed to submit visualization job"
    exit 1
fi

# Verify job was submitted correctly
if ! check_job_status "$viz_job_id" "visualize"; then
    echo "Warning: Job verification failed for visualization job $viz_job_id"
    # Continue anyway, as the job might still be in queue
fi

echo "  Visualization job ID: $viz_job_id"

# Print summary of submitted jobs
echo "======================="
echo "Job submission summary:"
echo "======================="
echo "Trimming jobs: ${trim_job_ids[*]}"
echo "Merge job: $merge_job_id"
echo "Assembly job: $assembly_job_id"
echo "BUSCO job: $busco_job_id"
echo "rnaQuast job: $rnaquast_job_id"
if [[ -n "$draft_busco_job_id" ]]; then
    echo "Draft BUSCO job: $draft_busco_job_id"
fi
if [[ -n "$draft_rnaquast_job_id" ]]; then
    echo "Draft rnaQuast job: $draft_rnaquast_job_id"
fi
echo "Visualization job: $viz_job_id"
echo "======================="

echo "Pipeline submitted successfully. Check job status with 'squeue -u $USER'"
echo "Results will be available in: $result_base"
echo "Log files will be in: $logs_base"

# Create a helper script to cancel all jobs if needed
cancel_script="${logs_base}/cancel_all_jobs.sh"
echo "#!/bin/bash" > $cancel_script
echo "# Script to cancel all pipeline jobs" >> $cancel_script
echo "echo 'Cancelling all pipeline jobs...'" >> $cancel_script
for job_id in "${trim_job_ids[@]}" "$merge_job_id" "$assembly_job_id" "$busco_job_id" "$rnaquast_job_id" "$draft_busco_job_id" "$draft_rnaquast_job_id" "$viz_job_id"; do
    if [[ -n "$job_id" ]]; then
        echo "scancel $job_id" >> $cancel_script
    fi
done
echo "echo 'All jobs cancelled.'" >> $cancel_script
chmod +x $cancel_script
echo "To cancel all jobs, run: $cancel_script"
