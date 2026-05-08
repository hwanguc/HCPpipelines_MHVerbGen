#!/bin/bash

# Reorganise Krishnan et al. (2021) BIDS-format data into the directory structure
# expected by the HCP pipeline batch scripts. Run this once before running any
# pipeline batch scripts.
#
# For each subject this script:
#   - Creates symlinks for T1w and fMRI NIfTI files using HCP naming conventions
#   - Merges the two gradient-echo magnitude images into a single 4D NIfTI
#     (required by the HCP SiemensFieldMap fieldmap correction method)
#   - Creates a symlink for the phasediff fieldmap
#
# Requires FSL (fslmerge) to be available on the PATH.
#
# Output directory structure per subject:
#   ${StudyFolder}/${Subject}/unprocessed/3T/T1w_MPR1/
#       ${Subject}_3T_T1w_MPR1.nii.gz
#       ${Subject}_3T_FieldMap_Magnitude.nii.gz   (4D: magnitude1 + magnitude2)
#       ${Subject}_3T_FieldMap_Phase.nii.gz        (phasediff, symlink)
#   ${StudyFolder}/${Subject}/unprocessed/3T/rfMRI_VERBGEN_AP/
#       ${Subject}_3T_rfMRI_VERBGEN_AP.nii.gz      (BOLD time series, symlink)
#       ${Subject}_3T_rfMRI_VERBGEN_AP_SBRef.nii.gz (single-band reference, symlink)
#       ${Subject}_3T_FieldMap_Magnitude.nii.gz   (symlink to T1w_MPR1 copy)
#       ${Subject}_3T_FieldMap_Phase.nii.gz        (phasediff, symlink)

RawDataFolder="${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/raw"
StudyFolder="${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/processed"
EnvironmentScript="${HOME}/Apps/Programming/matlab-proj/HCPpipelines_MHVerbGen/Examples/Scripts/SetUpHCPPipeline.sh"

source "${EnvironmentScript}"

if ! command -v fslmerge &>/dev/null; then
    echo "ERROR: fslmerge not found. Ensure FSL is installed and on PATH."
    exit 1
fi

mkdir -p "${StudyFolder}"

for Subject in $(ls "${RawDataFolder}" | grep -v '^\.' | sort); do
    echo "Reorganising ${Subject}..."

    T1wDir="${StudyFolder}/${Subject}/unprocessed/3T/T1w_MPR1"
    fMRIDir="${StudyFolder}/${Subject}/unprocessed/3T/rfMRI_VERBGEN_AP"
    mkdir -p "${T1wDir}" "${fMRIDir}"

    # T1w structural
    ln -sf "${RawDataFolder}/${Subject}/anat/${Subject}_T1w.nii.gz" \
        "${T1wDir}/${Subject}_3T_T1w_MPR1.nii.gz"

    # Siemens gradient-echo fieldmap: merge the two magnitude echoes into a 4D volume.
    # fslmerge is skipped if the output already exists so the script is safe to re-run.
    if [ ! -f "${T1wDir}/${Subject}_3T_FieldMap_Magnitude.nii.gz" ]; then
        fslmerge -t "${T1wDir}/${Subject}_3T_FieldMap_Magnitude.nii.gz" \
            "${RawDataFolder}/${Subject}/fmap/${Subject}_magnitude1.nii.gz" \
            "${RawDataFolder}/${Subject}/fmap/${Subject}_magnitude2.nii.gz"
    fi

    # Phase difference image
    ln -sf "${RawDataFolder}/${Subject}/fmap/${Subject}_phasediff.nii.gz" \
        "${T1wDir}/${Subject}_3T_FieldMap_Phase.nii.gz"

    # fMRI time series and single-band reference (treat task-verbgen as resting-state)
    ln -sf "${RawDataFolder}/${Subject}/func/${Subject}_task-verbgen_bold.nii.gz" \
        "${fMRIDir}/${Subject}_3T_rfMRI_VERBGEN_AP.nii.gz"
    ln -sf "${RawDataFolder}/${Subject}/func/${Subject}_task-verbgen_sbref.nii.gz" \
        "${fMRIDir}/${Subject}_3T_rfMRI_VERBGEN_AP_SBRef.nii.gz"

    # Fieldmap symlinks in fMRI directory (point back to the T1w_MPR1 copies)
    ln -sf "${T1wDir}/${Subject}_3T_FieldMap_Magnitude.nii.gz" \
        "${fMRIDir}/${Subject}_3T_FieldMap_Magnitude.nii.gz"
    ln -sf "${RawDataFolder}/${Subject}/fmap/${Subject}_phasediff.nii.gz" \
        "${fMRIDir}/${Subject}_3T_FieldMap_Phase.nii.gz"

done

echo "Done. Data reorganised in ${StudyFolder}"
