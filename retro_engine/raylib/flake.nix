{
  description = "PoiRetro Minimal Raylib Headless Proof-of-Concept Renderer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          gcc
          gnumake
          raylib
          xorg.libX11
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXinerama
          libGL
          xvfb-run
        ];
      };
    };
}
