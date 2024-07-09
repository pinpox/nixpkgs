{ lib
, stdenv
, fetchFromGitHub
, fetchYarnDeps
, nodejs
, yarnConfigHook
, yarnBuildHook

}: stdenv.mkDerivation (finalAttrs: rec {


  pname = "ente-web";
  version = "photos-v0.9.5";

  src =
    let
      repo = fetchFromGitHub {
        owner = "ente-io";
        repo = "ente";
        sparseCheckout = [ "web" ];
        rev = version;
        fetchSubmodules = true;
        hash = "sha256-YJuhdMrgOQW4+LaxEvZNmFZDlFRBmPZot8oUdACdhhE=";
      };
    in
    "${repo}/web";

  offlineCache = fetchYarnDeps {
    yarnLock = "${finalAttrs.src}/yarn.lock";
    hash = "sha256-ZGZkpHZD2LoMIXzpQRAO4Fh9Jf4WxosgykKnn7I1+2g=";
  };

  nativeBuildInputs = [
    yarnConfigHook
    yarnBuildHook
    nodejs
  ];

  installPhase = ''
    cp -r apps/photos/out $out
  '';

  meta = with lib; {
    description = "Web client for Ente Photos";
    homepage = "https://ente.io/";
    license = licenses.agpl3Only;
    maintainers = with maintainers; [ surfaceflinger pinpox ];
    mainProgram = "web";
    platforms = platforms.linux;
  };
})
