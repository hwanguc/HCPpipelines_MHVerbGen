#!/bin/bash 

get_batch_options() {
    local arguments=("$@")

    command_line_specified_study_folder=""
    command_line_specified_subj=""
    command_line_specified_run_local="FALSE"

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
            --runlocal)
                command_line_specified_run_local="TRUE"
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
StudyFolder="${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/processed" #Location of Subject folders (named by subjectID)
Subjlist=$(ls "${RawDataFolder}" | grep -v '^\.' | sort | tr '\n' ' ')  #All Krishnan subjects
EnvironmentScript="${HOME}/Apps/Programming/matlab-proj/HCPpipelines_MHVerbGen/Examples/Scripts/SetUpHCPPipeline.sh" #Pipeline environment script

if [ -n "${command_line_specified_study_folder}" ]; then
    StudyFolder="${command_line_specified_study_folder}"
fi

if [ -n "${command_line_specified_subj}" ]; then
    Subjlist="${command_line_specified_subj}"
fi

# Requirements for this script
#  installed versions of: FSL, FreeSurfer, Connectome Workbench (wb_command), gradunwarp (HCP version)
#  environment: HCPPIPEDIR, FSLDIR, FREESURFER_HOME, CARET7DIR, PATH for gradient_unwarp.py

#Set up pipeline environment variables and software
source "$EnvironmentScript"

# Log the originating call
echo "$@"

#NOTE: syntax for QUEUE has changed compared to earlier pipeline releases,
#DO NOT include "-q " at the beginning
#default to no queue, implying run local
QUEUE=""
#QUEUE="hcp_priority.q"

if [[ -n $HCPPIPEDEBUG ]]
then
    set -x
fi


########################################## INPUTS ########################################## 

# Scripts called by this script do NOT assume anything about the form of the input names or paths.
# This batch script assumes the HCP raw data naming convention.
#
# For example, if phase encoding directions are LR and RL, for tfMRI_EMOTION_LR and tfMRI_EMOTION_RL:
#
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_LR/${Subject}_3T_tfMRI_EMOTION_LR.nii.gz
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_LR/${Subject}_3T_tfMRI_EMOTION_LR_SBRef.nii.gz
#
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_RL/${Subject}_3T_tfMRI_EMOTION_RL.nii.gz
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_RL/${Subject}_3T_tfMRI_EMOTION_RL_SBRef.nii.gz
#
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_LR/${Subject}_3T_SpinEchoFieldMap_LR.nii.gz
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_LR/${Subject}_3T_SpinEchoFieldMap_RL.nii.gz
#
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_RL/${Subject}_3T_SpinEchoFieldMap_LR.nii.gz
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_RL/${Subject}_3T_SpinEchoFieldMap_RL.nii.gz
#
# If phase encoding directions are PA and AP:
#
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_PA/${Subject}_3T_tfMRI_EMOTION_PA.nii.gz
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_PA/${Subject}_3T_tfMRI_EMOTION_PA_SBRef.nii.gz
#
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_AP/${Subject}_3T_tfMRI_EMOTION_AP.nii.gz
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_AP/${Subject}_3T_tfMRI_EMOTION_AP_SBRef.nii.gz
#
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_PA/${Subject}_3T_SpinEchoFieldMap_PA.nii.gz
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_PA/${Subject}_3T_SpinEchoFieldMap_AP.nii.gz
#
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_AP/${Subject}_3T_SpinEchoFieldMap_PA.nii.gz
#   ${StudyFolder}/${Subject}/unprocessed/3T/tfMRI_EMOTION_AP/${Subject}_3T_SpinEchoFieldMap_AP.nii.gz
#
#
# Change Scan Settings: EchoSpacing, FieldMap DeltaTE (if not using TOPUP),
# and $TaskList to match your acquisitions
#
# If using gradient distortion correction, use the coefficents from your scanner.
# The HCP gradient distortion coefficents are only available through Siemens.
# Gradient distortion in standard scanners like the Trio is much less than for the HCP 'Connectom' scanner.
#
# To get accurate EPI distortion correction with TOPUP, the phase encoding direction
# encoded as part of the ${TaskList} name must accurately reflect the PE direction of
# the EPI scan, and you must have used the correct images in the
# SpinEchoPhaseEncode{Negative,Positive} variables.  If the distortion is twice as
# bad as in the original images, either swap the
# SpinEchoPhaseEncode{Negative,Positive} definition or reverse the polarity in the
# logic for setting UnwarpDir.
# NOTE: The pipeline expects you to have used the same phase encoding axis and echo
# spacing in the fMRI data as in the spin echo field map acquisitions.

######################################### DO WORK ##########################################

SCRIPT_NAME=`basename "$0"`
echo $SCRIPT_NAME

TaskList=()
TaskList+=(rfMRI_VERBGEN_AP)  # Single run; PE direction j- (AP/y-); treated as resting-state

# Start or launch pipeline processing for each subject
for Subject in $Subjlist ; do
    echo "${SCRIPT_NAME}: Processing Subject: ${Subject}"

    for fMRIName in "${TaskList[@]}" ; do
        echo "  ${SCRIPT_NAME}: Processing Scan: ${fMRIName}"

        TaskName=`echo ${fMRIName} | sed 's/_[APLR]\+$//'`
        echo "  ${SCRIPT_NAME}: TaskName: ${TaskName}"

        len=${#fMRIName}
        echo "  ${SCRIPT_NAME}: len: $len"
        start=$(( len - 2 ))

        PhaseEncodingDir=${fMRIName:start:2}
        echo "  ${SCRIPT_NAME}: PhaseEncodingDir: ${PhaseEncodingDir}"

        case ${PhaseEncodingDir} in
            "PA")
                UnwarpDir="y"
                ;;
            "AP")
                UnwarpDir="y-"
                ;;
            "RL")
                UnwarpDir="x"
                ;;
            "LR")
                UnwarpDir="x-"
                ;;
            *)
                echo "${SCRIPT_NAME}: Unrecognized Phase Encoding Direction: ${PhaseEncodingDir}"
                exit 1
                ;;
        esac

        echo "  ${SCRIPT_NAME}: UnwarpDir: ${UnwarpDir}"

        fMRITimeSeries="${StudyFolder}/${Subject}/unprocessed/3T/${fMRIName}/${Subject}_3T_${fMRIName}.nii.gz"

        # A single band reference image (SBRef) is recommended if available
        # Set to NONE if you want to use the first volume of the timeseries for motion correction
        fMRISBRef="${StudyFolder}/${Subject}/unprocessed/3T/${fMRIName}/${Subject}_3T_${fMRIName}_SBRef.nii.gz"

        # EffectiveEchoSpacing from fMRI JSON: 1 / (BandwidthPerPixelPhaseEncode * ReconMatrixPE)
        # = 1 / (21.786 * 90) = 0.000510012 s
        EchoSpacing="0.000510012"

        # Susceptibility distortion correction method
        # Krishnan data has Siemens gradient echo fieldmaps (no spin echo / TOPUP)
        DistortionCorrection="SiemensFieldMap"

        # Receive coil bias field correction method
        # SEBASED requires TOPUP spin echo fieldmaps; use LEGACY (T1w-based) instead
        BiasCorrection="LEGACY"

        # No spin echo field maps in Krishnan data
        SpinEchoPhaseEncodeNegative="NONE"
        SpinEchoPhaseEncodePositive="NONE"
        TopUpConfig="NONE"

        # Siemens gradient echo fieldmap files (created by ReorganiseKrishnanData.sh)
        MagnitudeInputName="${StudyFolder}/${Subject}/unprocessed/3T/T1w_MPR1/${Subject}_3T_FieldMap_Magnitude.nii.gz"
        PhaseInputName="${StudyFolder}/${Subject}/unprocessed/3T/T1w_MPR1/${Subject}_3T_FieldMap_Phase.nii.gz"
        # DeltaTE = (EchoTime2 - EchoTime1) * 1000 = (7.38 - 4.92) ms = 2.46 ms
        DeltaTE="2.46"

        # Path to GE HealthCare Legacy style B0 fieldmap with two volumes
        #   1. field map in hertz
        #   2. magnitude image
        # Set to "NONE" if not using "GEHealthCareLegacyFieldMap" as the value for the DistortionCorrection variable
        #
        # Example Value: 
        #  GEB0InputName="${StudyFolder}/${Subject}/unprocessed/3T/${fMRIName}/${Subject}_3T_GradientEchoFieldMap.nii.gz" 
        #  DeltaTE=2.272 # ms 
        GEB0InputName="NONE"

        # Target final resolution of fMRI data
        # 2mm is recommended for 3T HCP data, 1.6mm for 7T HCP data (i.e. should match acquisition resolution)
        # Use 2.0 or 1.0 to avoid standard FSL templates
        FinalFMRIResolution="2"

        # Gradient distortion correction
        # Set to NONE to skip gradient distortion correction
        # (These files are considered proprietary and therefore not provided as part of the HCP Pipelines -- contact Siemens to obtain)
        # GradientDistortionCoeffs="${HCPPIPEDIR_Config}/coeff_SC72C_Skyra.grad"
        GradientDistortionCoeffs="NONE"

        # Type of motion correction
        # Values: MCFLIRT (default), FLIRT
        # (3T HCP-YA processing used 'FLIRT', but 'MCFLIRT' now recommended)
        MCType="MCFLIRT"

        if [[ "${command_line_specified_run_local}" == "TRUE" || "$QUEUE" == "" ]] ; then
            echo "About to locally run ${HCPPIPEDIR}/fMRIVolume/GenericfMRIVolumeProcessingPipeline.sh"
            queuing_command=("$HCPPIPEDIR"/global/scripts/captureoutput.sh)
        else
            echo "About to use fsl_sub to queue ${HCPPIPEDIR}/fMRIVolume/GenericfMRIVolumeProcessingPipeline.sh"
            queuing_command=("$FSLDIR/bin/fsl_sub" -q "$QUEUE")
        fi

        "${queuing_command[@]}" "$HCPPIPEDIR"/fMRIVolume/GenericfMRIVolumeProcessingPipeline.sh \
            --path="$StudyFolder" \
            --subject="$Subject" \
            --fmriname="$fMRIName" \
            --fmritcs="$fMRITimeSeries" \
            --fmriscout="$fMRISBRef" \
            --SEPhaseNeg="$SpinEchoPhaseEncodeNegative" \
            --SEPhasePos="$SpinEchoPhaseEncodePositive" \
            --fmapmag="$MagnitudeInputName" \
            --fmapphase="$PhaseInputName" \
            --fmapcombined="$GEB0InputName" \
            --echospacing="$EchoSpacing" \
            --echodiff="$DeltaTE" \
            --unwarpdir="$UnwarpDir" \
            --fmrires="$FinalFMRIResolution" \
            --dcmethod="$DistortionCorrection" \
            --gdcoeffs="$GradientDistortionCoeffs" \
            --topupconfig="$TopUpConfig" \
            --biascorrection="$BiasCorrection" \
            --mctype="$MCType" \
            --processing-mode=LegacyStyleData

        # The following lines are used for interactive debugging to set the positional parameters: $1 $2 $3 ...

        echo "set -- --path=$StudyFolder \
            --subject=$Subject \
            --fmriname=$fMRIName \
            --fmritcs=$fMRITimeSeries \
            --fmriscout=$fMRISBRef \
            --SEPhaseNeg=$SpinEchoPhaseEncodeNegative \
            --SEPhasePos=$SpinEchoPhaseEncodePositive \
            --fmapmag=$MagnitudeInputName \
            --fmapphase=$PhaseInputName \
            --fmapcombined=$GEB0InputName \
            --echospacing=$EchoSpacing \
            --echodiff=$DeltaTE \
            --unwarpdir=$UnwarpDir \
            --fmrires=$FinalFMRIResolution \
            --dcmethod=$DistortionCorrection \
            --gdcoeffs=$GradientDistortionCoeffs \
            --topupconfig=$TopUpConfig \
            --biascorrection=$BiasCorrection \
            --mctype=$MCType"

        echo ". ${EnvironmentScript}"

    done
done
