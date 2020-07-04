#!/run/current-system/sw/bin/bash
TICKET=Bug
ERROR=error.txt
RELEASE_OR_COMMIT=18.03
GHC_VERSION=ghc822
echo "with import (fetchTarball https://github.com/NixOS/nixpkgs/archive/${RELEASE_OR_COMMIT}.tar.gz) {};" > $GHC_VERSION.nix
echo "let ghc = haskell.compiler.${GHC_VERSION}; in mkShell { inherit ghc; name = \"myEnv\"; buildInputs = [ ghc ]; }" >> $GHC_VERSION.nix
COMMAND="ghc ${TICKET}.hs"

nix-shell $GHC_VERSION.nix --run "${COMMAND}" 2> $ERROR

grep "error:ghc: panic! (the 'impossible' happened)" error.txt &&
grep "No skolem info:" error.txt &&
grep "pprPanic, called at compiler/typecheck/TcErrors.hs" error.txt
