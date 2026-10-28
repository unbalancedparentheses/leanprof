#!/bin/sh
# The project's modules: all of Mathlib imported, and copies of three of
# Mathlib's most expensive files (Radar's ranking, docs/case-studies/mathlib.md),
# compiled here against Mathlib's cached build, with Mathlib's leanOptions.
set -e
D=cm
M=mathlib4
cd $D/mlp
REV=$(cd $M && git rev-parse HEAD)
cat > lakefile.toml <<EOF
name = "mlp"
defaultTargets = ["Mlp"]

[leanOptions]
autoImplicit = false
maxSynthPendingDepth = 3

[[require]]
name = "mathlib"
git = "$M"
rev = "$REV"

[[lean_lib]]
name = "Mlp"
globs = ["Mlp.+"]
EOF
rm -f Mlp/Placeholder.lean
printf 'import Mathlib\n\nexample : 2 + 2 = 4 := rfl\n' > Mlp/All.lean
cp $M/Mathlib/AlgebraicGeometry/Modules/Tilde.lean Mlp/Tilde.lean
cp $M/Mathlib/Analysis/Fourier/FourierTransform.lean Mlp/FourierTransform.lean
cp $M/Mathlib/CategoryTheory/Sites/SheafCohomology/MayerVietoris.lean Mlp/MayerVietoris.lean
ls Mlp
