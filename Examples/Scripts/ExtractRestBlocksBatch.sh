#!/bin/bash

# ExtractRestBlocksBatch.sh
#
# Extracts rest/fixation-period timepoints from ICA-FIX-cleaned fMRI CIFTI files
# and concatenates them into a rest-only dtseries file for functional connectivity
# analysis. No pipeline stages need to be re-run; extraction is applied directly to
# the fully preprocessed and denoised output.
#
# Strategy: post-processing extraction from rfMRI_VERBGEN_AP_Atlas_hp2000_clean.dtseries.nii
#   - Motion correction and ICA-FIX denoising remain applied on the full run (better quality)
#   - Only rest-block timepoints are retained in the output
#   - Optional HRF trim: skip the first N seconds of each rest block to reduce hemodynamic
#     spillover from the preceding task block (the HRF takes ~6-10s to decay after task offset)
#
# Output: rfMRI_VERBGEN_AP_rest_Atlas_hp2000_clean.dtseries.nii
#         (placed in MNINonLinear/Results/rfMRI_VERBGEN_AP_rest/)

get_batch_options() {
    local arguments=("$@")

    command_line_specified_study_folder=""
    command_line_specified_subj=""
    command_line_specified_hrf_trim="0"

    local index=0
    local numArgs=${#arguments[@]}
    local argument

    while [ ${index} -lt ${numArgs} ]; do
        argument=${arguments[index]}

        case ${argument} in
            --StudyFolder=*)
                command_line_specified_study_folder=${argument#*=}
                index=$(( index + 1 ))
                ;;
            --Subject=*)
                command_line_specified_subj=${argument#*=}
                index=$(( index + 1 ))
                ;;
            --hrf-trim=*)
                # Seconds to trim from the start of each rest block (to reduce HRF spillover).
                # Default 0. Recommended: 6 (approx one HRF peak) or 10 (conservative).
                command_line_specified_hrf_trim=${argument#*=}
                index=$(( index + 1 ))
                ;;
            *)
                echo ""
                echo "ERROR: Unrecognized Option: ${argument}"
                echo ""
                exit 1
                ;;
        esac
    done
}

get_batch_options "$@"

RawDataFolder="${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/raw"
StudyFolder="${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/processed"
EventsFile="${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/other/task-verbgen_events.tsv"
EnvironmentScript="${HOME}/Apps/Programming/matlab-proj/HCPpipelines_MHVerbGen/Examples/Scripts/SetUpHCPPipeline.sh"

Subjlist=$(ls "${RawDataFolder}" | grep -v '^\.' | sort | tr '\n' ' ')

if [ -n "${command_line_specified_study_folder}" ]; then
    StudyFolder="${command_line_specified_study_folder}"
fi

if [ -n "${command_line_specified_subj}" ]; then
    Subjlist="${command_line_specified_subj}"
fi

HRFTrimSec="${command_line_specified_hrf_trim}"

source "$EnvironmentScript"

fMRIName="rfMRI_VERBGEN_AP"
RestfMRIName="rfMRI_VERBGEN_AP_rest"
TR=0.8

# ---------------------------------------------------------------------------
# Parse events file to find rest/fixation block column ranges.
# Returns space-separated "start_col:end_col" pairs (1-indexed, for wb_command).
#
# Column n (1-indexed) represents time t = (n-1) * TR.
# For a block starting at onset O and ending at O+D:
#   start_col = floor(O / TR) + 1    (first volume whose nominal time >= O - TR/2)
#   end_col   = floor((O+D) / TR)    (last volume whose nominal time < O+D)
# ---------------------------------------------------------------------------
get_rest_block_ranges() {
    local events_file="$1"
    local tr="$2"
    local hrf_trim_sec="$3"

    awk -v TR="$tr" -v HRF="$hrf_trim_sec" '
    NR > 1 && $3 == "fixation" {
        onset    = $1 + HRF
        end_time = $1 + $2
        start_col = int(onset / TR) + 1
        end_col   = int(end_time / TR)
        if (start_col <= end_col) {
            printf "%d:%d ", start_col, end_col
        }
    }
    ' "$events_file"
}

REST_RANGES=$(get_rest_block_ranges "$EventsFile" "$TR" "$HRFTrimSec")

if [ -z "$REST_RANGES" ]; then
    echo "ERROR: No fixation blocks found in ${EventsFile}"
    exit 1
fi

echo "TR: ${TR}s  |  HRF trim: ${HRFTrimSec}s"
echo "Rest block ranges (1-indexed CIFTI columns): ${REST_RANGES}"

# Count total rest volumes
total_rest=0
for range in $REST_RANGES; do
    s="${range%%:*}"
    e="${range##*:}"
    total_rest=$(( total_rest + e - s + 1 ))
done
echo "Total rest volumes to extract: ${total_rest}"
echo ""

# ---------------------------------------------------------------------------
# Process each subject
# ---------------------------------------------------------------------------
for Subject in $Subjlist; do
    echo "${Subject}"

    ResultsDir="${StudyFolder}/${Subject}/MNINonLinear/Results"
    InputFile="${ResultsDir}/${fMRIName}/${fMRIName}_Atlas_hp2000_clean.dtseries.nii"

    if [ ! -f "${InputFile}" ]; then
        echo "  WARNING: Input file not found, skipping: ${InputFile}"
        continue
    fi

    OutputDir="${ResultsDir}/${RestfMRIName}"
    OutputFile="${OutputDir}/${RestfMRIName}_Atlas_hp2000_clean.dtseries.nii"

    mkdir -p "${OutputDir}"

    # Build wb_command -cifti-merge call
    merge_cmd=(wb_command -cifti-merge "${OutputFile}")
    for range in $REST_RANGES; do
        start_col="${range%%:*}"
        end_col="${range##*:}"
        merge_cmd+=(-cifti "${InputFile}" -column "${start_col}" -up-to "${end_col}")
    done

    echo "  Running: ${merge_cmd[*]}"
    "${merge_cmd[@]}"

    if [ $? -eq 0 ]; then
        n_cols=$(wb_command -file-information "${OutputFile}" 2>&1 | grep "Number of Maps" | awk '{print $NF}')
        echo "  Done. Output: ${OutputFile} (${n_cols} volumes)"
    else
        echo "  ERROR: wb_command -cifti-merge failed for ${Subject}"
    fi
done
