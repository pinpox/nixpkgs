{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pythonOlder,
  setuptools,
  urwid,
}:

buildPythonPackage rec {
  pname = "urwidgets";
  version = "0.2.1";
  pyproject = true;

  disabled = pythonOlder "3.7";

  src = fetchFromGitHub {
    owner = "AnonymouX47";
    repo = "urwidgets";
    tag = "v${version}";
    hash = "sha256-RgY7m0smcdUspGkCdzepxruEMDq/mAsVFNjHMLoWAyc=";
  };

  nativeBuildInputs = [ setuptools ];

  propagatedBuildInputs = [ urwid ];

  pythonImportsCheck = [ "urwidgets" ];

  meta = with lib; {
    description = "Collection of widgets for urwid";
    homepage = "https://github.com/AnonymouX47/urwidgets";
    changelog = "https://github.com/AnonymouX47/urwidgets/releases/tag/v${version}";
    license = licenses.mit;
    maintainers = with maintainers; [ huyngo ];
  };
}
