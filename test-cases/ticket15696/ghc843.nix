with import (fetchTarball https://github.com/NixOS/nixpkgs/archive/18.09.tar.gz) {};
let ghc = haskell.compiler.ghc843;
in haskell.lib.buildStackProject {
    inherit ghc;
    name = "myEnv";
    buildInputs = [ ];
}
