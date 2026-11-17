#!/bin/sh
# Mac GPU checks for the on-device 3DGS trainer (ios/PocketWorld/Training). Run on an Apple-silicon Mac:
#   1. forward render vs a CPU reference, 2. analytic gradients vs finite differences,
#   3. convergence on a synthetic scene, 4. the app's package → dataset → train → PLY pipeline.
set -eu
here=$(cd "$(dirname "$0")" && pwd); app="$here/../PocketWorld"; out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun -sdk macosx metal -std=metal3.1 -c "$app/Training/GaussianTraining.metal" -o "$out/training.air"
xcrun -sdk macosx metallib "$out/training.air" -o "$out/training.metallib"
swiftc -O -o "$out/checks" "$here/Checks/main.swift" "$app/Training/GaussianTrainer.swift"
swiftc -O -o "$out/quality" "$here/Quality/main.swift" "$app/Training/GaussianTrainer.swift"
swiftc -O -o "$out/e2e" "$here/EndToEnd/main.swift" "$app/Training/GaussianTrainer.swift" "$app/Training/TrainingDataset.swift" "$app/Models/ReconstructionStudy.swift" "$app/Viewer/SceneCameraPath.swift"
swiftc -O -o "$out/resume" "$here/Resume/main.swift" "$app/Training/TrainingCheckpoint.swift" "$app/Training/GaussianTrainer.swift" "$app/Training/TrainingDataset.swift" "$app/Models/ReconstructionStudy.swift" "$app/Viewer/SceneCameraPath.swift"
"$out/resume" "$out/training.metallib"
"$out/checks" "$out/training.metallib"
"$out/quality" "$out/training.metallib"
mkdir -p "$out/e2e-data" && "$out/e2e" "$out/training.metallib" "$out/e2e-data"
rm -rf "$out"
