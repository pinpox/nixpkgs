{ lib
, mkYarnPackage
, fetchFromGitHub
, fetchYarnDeps
, nodejs
, fixup-yarn-lock
, yarn

}: mkYarnPackage rec {


  pname = "ente-web";
  version = "photos-v0.9.5";

  src = fetchFromGitHub {
    owner = "ente-io";
    repo = "ente";
    sparseCheckout = [ "web" ];
    rev = version;
    hash = "sha256-ky37MAREFzGskokVxJUarYXpFpbq85TS31QAp027hqg=";
  };

  sourceRoot = "source/web";

  packageJSON = "${src}/web/package.json";

  offlineCache = fetchYarnDeps {
    yarnLock = "${src}/web/yarn.lock";
    hash = "sha256-ZGZkpHZD2LoMIXzpQRAO4Fh9Jf4WxosgykKnn7I1+2g=";
  };

  # passthru.updateScript = nix-update-script { };

  nativeBuildInputs = [
    nodejs
    fixup-yarn-lock
    yarn
  ];

  configurePhase = ''
    runHook preConfigure
    export HOME=$(mktemp -d)
    yarn config --offline set yarn-offline-mirror $offlineCache
    fixup-yarn-lock yarn.lock
    yarn --offline --frozen-lockfile --ignore-platform --ignore-scripts --no-progress --non-interactive install
    patchShebangs node_modules
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    yarn --offline build:photos
    runHook postBuild
  '';

  meta = with lib; {
    description = "Web client for Ente Photos";
    homepage = "https://ente.io/";
    license = licenses.agpl3Only;
    maintainers = with maintainers; [ surfaceflinger pinpox ];
    mainProgram = "web";
    platforms = platforms.linux;
  };
}
