#!/usr/bin/env python3
"""
Identify task-driven ICA components among those labelled as Signal by ICA-FIX.

Reads the MELODIC mixing matrix and the BIDS events file, convolves the task
design with a canonical double-gamma HRF, then reports the Pearson correlation
between each Signal component's time course and the task regressor.

Usage:
    python identify_task_components.py <ica_dir> <events_tsv>

Example:
    python identify_task_components.py \
        ~/Documents/Data/ucl/gos_ich/verb_gen_krishnan/processed/sub-509BT/MNINonLinear/Results/rfMRI_VERBGEN_AP/rfMRI_VERBGEN_AP_hp2000.ica \
        ~/Documents/Data/ucl/gos_ich/verb_gen_krishnan/other/task-verbgen_events.tsv
"""

import sys
import os
import numpy as np
from scipy.stats import pearsonr
from scipy.special import gamma


def double_gamma_hrf(t):
    """Canonical double-gamma HRF (SPM default parameters)."""
    a1, a2 = 6.0, 16.0
    b1, b2 = 1.0, 1.0
    c = 1.0 / 6.0
    h = (t ** (a1 - 1) * np.exp(-t / b1) / (gamma(a1) * b1 ** a1)
         - c * t ** (a2 - 1) * np.exp(-t / b2) / (gamma(a2) * b2 ** a2))
    h[t < 0] = 0.0
    return h


def build_task_regressor(events_file, n_vols, tr, trial_type="verbgen"):
    """Convolve the task design with the canonical HRF and downsample to TR."""
    dt = 0.1  # HRF resolution in seconds
    total_sec = n_vols * tr
    t_fine = np.arange(0, total_sec, dt)
    hrf_t = np.arange(0, 32, dt)
    hrf = double_gamma_hrf(hrf_t)

    # Build neural boxcar at high resolution
    neural = np.zeros(len(t_fine))
    with open(events_file) as f:
        header = f.readline()
        for line in f:
            parts = line.strip().split('\t')
            if len(parts) < 3:
                continue
            onset, duration, ttype = float(parts[0]), float(parts[1]), parts[2]
            if ttype == trial_type:
                i_on = int(round(onset / dt))
                i_off = int(round((onset + duration) / dt))
                neural[i_on:i_off] = 1.0

    # Convolve and downsample to TR
    bold_fine = np.convolve(neural, hrf)[:len(t_fine)]
    tr_indices = np.arange(0, n_vols) * int(round(tr / dt))
    regressor = bold_fine[tr_indices]
    regressor = (regressor - regressor.mean()) / regressor.std()
    return regressor


def load_fix_labels(ica_dir):
    """Return (signal_components, noise_components) as 1-indexed sets."""
    fix_files = [f for f in os.listdir(ica_dir) if f.startswith("fix4melview") and f.endswith(".txt")]
    if not fix_files:
        raise FileNotFoundError(f"No fix4melview*.txt found in {ica_dir}")
    fix_file = os.path.join(ica_dir, fix_files[0])

    signal = set()
    noise = set()
    with open(fix_file) as f:
        for line in f:
            parts = [p.strip() for p in line.split(',')]
            if len(parts) >= 2:
                try:
                    comp_id = int(parts[0])
                    label = parts[1]
                    if label == "Signal":
                        signal.add(comp_id)
                    elif label == "Noise":
                        noise.add(comp_id)
                except ValueError:
                    pass  # header or noise list line
    return signal, noise


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    ica_dir = os.path.expanduser(sys.argv[1])
    events_file = os.path.expanduser(sys.argv[2])
    threshold = float(sys.argv[3]) if len(sys.argv) > 3 else 0.3

    mix_file = os.path.join(ica_dir, "filtered_func_data.ica", "melodic_mix")
    if not os.path.exists(mix_file):
        raise FileNotFoundError(f"melodic_mix not found: {mix_file}")

    mixing = np.loadtxt(mix_file)  # shape: (n_vols, n_components)
    n_vols, n_components = mixing.shape
    tr = 0.8  # hardcoded for this dataset

    print(f"Mixing matrix: {n_vols} volumes x {n_components} components, TR={tr}s")

    signal_comps, _ = load_fix_labels(ica_dir)
    print(f"Signal components (kept by ICA-FIX): {sorted(signal_comps)}\n")

    regressor = build_task_regressor(events_file, n_vols, tr, trial_type="verbgen")

    print(f"{'Comp':>6}  {'r':>7}  {'p':>10}  {'Interpretation'}")
    print("-" * 55)

    task_driven = []
    for comp_id in sorted(signal_comps):
        tc = mixing[:, comp_id - 1]  # 0-indexed
        tc_z = (tc - tc.mean()) / tc.std()
        r, p = pearsonr(tc_z, regressor)
        flag = " <-- task-driven" if abs(r) >= threshold else ""
        print(f"{comp_id:>6}  {r:>7.3f}  {p:>10.4f}{flag}")
        if abs(r) >= threshold:
            task_driven.append(comp_id)

    print()
    if task_driven:
        print(f"Task-driven signal components (|r| >= {threshold}): {task_driven}")
        print("These components contribute task-related variance to the rest blocks.")
        print("For rest-only FC analysis, regress them out using:")
        print(f"  wb_command -cifti-regressors ...")
        print(f"  or extract their columns from the mixing matrix and use fsl_glm.")
    else:
        print(f"No signal components show |r| >= {threshold} with the task regressor.")
        print("Task contamination in the rest blocks is likely minimal.")


if __name__ == "__main__":
    main()
