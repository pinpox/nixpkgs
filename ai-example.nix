{ pkgs ? import ./. { } }:

let
  # Simple example that generates a Hello World script
  helloScript = pkgs.writers.writeAIBin "hello-script" {
    prompt = "Write a simple bash script that prints 'Hello, World!'";
    # This is a placeholder hash that will be replaced after the first build attempt
    outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    outputHashAlgo = "sha256";
  };
in
  helloScript