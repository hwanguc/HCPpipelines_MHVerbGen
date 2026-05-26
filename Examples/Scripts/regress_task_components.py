#!/usr/bin/env python3
"""
Regress task-driven ICA components out of an ICA-FIX-cleaned CIFTI dtseries.

For each specified component, its time course is used as a confound regressor.
OLS is applied across all grayordinates simultaneously; the residuals are saved
as a new dtseries file with identical header/axes.

Usage:
    python regress_task_components.py <ica_dir> <input_cifti> <output_cifti> <comp_id> [comp_id ...]

Example:
    python regress_task_components.py \
        .../rfMRI_VERBGEN_AP_hp2000.ica \
        .../rfMRI_VERBGEN_AP_Atlas_hp2000_clean.dtseries.nii \
        .../rfMRI_VERBGEN_AP_Atlas_hp2000_clean_taskregressed.dtseries.nii \
        27
"""

import sys
import os
import numpy as np
import nibabel as nib


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        sys.exit(1)

    ica_dir     = os.path.expanduser(sys.argv[1])
    input_cifti = os.path.expanduser(sys.argv[2])
    output_cifti = os.path.expanduser(sys.argv[3])
    comp_ids    = [int(x) for x in sys.argv[4:]]  # 1-indexed

    mix_file = os.path.join(ica_dir, "filtered_func_data.ica", "melodic_mix")
    mixing = np.loadtxt(mix_file)                        # (n_vols, n_components)
    n_vols = mixing.shape[0]

    regressors = mixing[:, [c - 1 for c in comp_ids]]   # (n_vols, n_regressors)
    print(f"Regressing out component(s): {comp_ids}")
    print(f"Regressor(s) shape: {regressors.shape}")

    # Design matrix: intercept + regressors
    X = np.column_stack([np.ones(n_vols), regressors])  # (n_vols, 1 + n_regressors)

    print(f"Loading {input_cifti} ...")
    img  = nib.load(input_cifti)
    data = img.get_fdata(dtype=np.float32)               # (n_vols, n_grayordinates)

    # OLS: beta = (X'X)^{-1} X' Y,  residuals = Y - X @ beta
    beta      = np.linalg.lstsq(X, data, rcond=None)[0] # (1 + n_regressors, n_grayordinates)
    residuals = data - X @ beta                          # (n_vols, n_grayordinates)

    residuals = residuals.astype(np.float32)

    print(f"Saving residuals to {output_cifti} ...")
    new_img = nib.Cifti2Image(residuals, header=img.header, nifti_header=img.nifti_header)
    nib.save(new_img, output_cifti)
    print("Done.")


if __name__ == "__main__":
    main()
