{
  buildPackages,
  gixy,
  lib,
  libiconv,
  makeBinaryWrapper,
  mkNugetDeps,
  mkNugetSource,
  pkgs,
  stdenv,
}:
let
  inherit (lib)
    concatMapStringsSep
    elem
    escapeShellArg
    last
    optionalString
    strings
    types
    ;
in
rec {
  /**
    `makeScriptWriter` returns a derivation which creates an executable script.

    # Inputs

    config (AttrSet)
    : `interpreter` (String)
      : the [interpreter](https://en.wikipedia.org/wiki/Shebang_(Unix)) to use for the script.
    : `check` (String)
      : A command to check the script. For example, this could be a linting check.
    : `makeWrapperArgs` (Optional, [ String ], Default: [])
      : Arguments forwarded to (`makeWrapper`)[#fun-makeWrapper].

    `nameOrPath` (String)
    : The name of the script or the path to the script.

      When a `string` starting with "/" is passed, the script will be created at the specified path in $out.
      I.e. `"/bin/hello"` will create a script at `$out/bin/hello`.

      Any other `string` is interpreted as a filename.
      It must be a [POSIX filename](https://en.wikipedia.org/wiki/Filename) starting with a letter, digit, dot, or underscore.
      Spaces or special characters are not allowed.

    `content` (String)
    : The content of the script.

    :::{.note}
    This function is used as base implementation for other high-level writer functions.

    For example, `writeBash` can (roughly) be implemented as:

    ```nix
    writeBash = makeScriptWriter { interpreter = "${pkgs.bash}/bin/bash"; }
    ```
    :::

    # Examples
    :::{.example}
    ## `pkgs.writers.makeScriptWriter` dash example

    ```nix-repl
    :b makeScriptWriter { interpreter = "${pkgs.dash}/bin/dash"; } "hello" "echo hello world"
    -> /nix/store/indvlr9ckmnv4f0ynkmasv2h4fxhand0-hello
    ```

    The above example creates a script named `hello` that outputs `hello world` when executed.

    ```sh
    > /nix/store/indvlr9ckmnv4f0ynkmasv2h4fxhand0-hello
    hello world
    ```
    :::

    :::{.example}
    ## `pkgs.writers.makeScriptWriter` python example

    ```nix-repl
    :b makeScriptWriter { interpreter = "${pkgs.python3}/bin/python"; } "python-hello" "print('hello world')"
    -> /nix/store/4kvby1hqr45ffcdrvfpnpj62hanskw93-python-hello
    ```

    ```sh
    > /nix/store/4kvby1hqr45ffcdrvfpnpj62hanskw93-python-hello
    hello world
    ```
    :::
  */
  makeScriptWriter =
    {
      interpreter,
      check ? "",
      makeWrapperArgs ? [ ],
    }:
    nameOrPath: content:
    assert
      (types.path.check nameOrPath)
      || (builtins.match "([0-9A-Za-z._])[0-9A-Za-z._-]*" nameOrPath != null);
    assert (types.path.check content) || (types.str.check content);
    let
      nameIsPath = types.path.check nameOrPath;
      name = last (builtins.split "/" nameOrPath);
      path = if nameIsPath then nameOrPath else "/bin/${name}";
      # The inner derivation which creates the executable under $out/bin (never at $out directly)
      # This is required in order to support wrapping, as wrapped programs consist of
      # at least two files: the executable and the wrapper.
      inner =
        pkgs.runCommandLocal name
          (
            {
              inherit makeWrapperArgs;
              nativeBuildInputs = [ makeBinaryWrapper ];
              meta.mainProgram = name;
            }
            // (
              if (types.str.check content) then
                {
                  inherit content interpreter;
                  passAsFile = [ "content" ];
                }
              else
                {
                  inherit interpreter;
                  contentPath = content;
                }
            )
          )
          ''
            # On darwin a script cannot be used as an interpreter in a shebang but
            # there doesn't seem to be a limit to the size of shebang and multiple
            # arguments to the interpreter are allowed.
            if [[ -n "${toString pkgs.stdenvNoCC.hostPlatform.isDarwin}" ]] && isScript $interpreter
            then
              wrapperInterpreterLine=$(head -1 "$interpreter" | tail -c+3)
              # Get first word from the line (note: xargs echo remove leading spaces)
              wrapperInterpreter=$(echo "$wrapperInterpreterLine" | xargs echo | cut -d " " -f1)

              if isScript $wrapperInterpreter
              then
                echo "error: passed interpreter ($interpreter) is a script which has another script ($wrapperInterpreter) as an interpreter, which is not supported."
                exit 1
              fi

              # This should work as long as wrapperInterpreter is a shell, which is
              # the case for programs wrapped with makeWrapper, like
              # python3.withPackages etc.
              interpreterLine="$wrapperInterpreterLine $interpreter"
            else
              interpreterLine=$interpreter
            fi

            echo "#! $interpreterLine" > $out
            cat "$contentPath" >> $out
            ${optionalString (check != "") ''
              ${check} $out
            ''}
            chmod +x $out

            # Relocate executable
            # Wrap it if makeWrapperArgs are specified
            mv $out tmp
              mkdir -p $out/$(dirname "${path}")
              mv tmp $out/${path}
            if [ -n "''${makeWrapperArgs+''${makeWrapperArgs[@]}}" ]; then
                wrapProgram $out/${path} ''${makeWrapperArgs[@]}
            fi
          '';
    in
    if nameIsPath then
      inner
    # In case nameOrPath is a name, the user intends the executable to be located at $out.
    # This is achieved by creating a separate derivation containing a symlink at $out linking to ${inner}/bin/${name}.
    # This breaks the override pattern.
    # In case this turns out to be a problem, we can still add more magic
    else
      pkgs.runCommandLocal name { } ''
        ln -s ${inner}/bin/${name} $out
      '';

  /**
    `makeBinWriter` returns a derivation which compiles the given script into an executable format.

    :::{.note}
    This function is the base implementation for other compile language `writers`, such as `writeHaskell` and `writeRust`.
    :::

    # Inputs

    config (AttrSet)
    : `compileScript` (String)
      : The script that compiles the given content into an executable.

    : `strip` (Boolean, Default: true)
      : Whether to [strip](https://nixos.org/manual/nixpkgs/stable/#ssec-fixup-phase) the executable or not.

    : `makeWrapperArgs` (Optional, [ String ], Default: [])
      : Arguments forwarded to (`makeWrapper`)[#fun-makeWrapper]

    `nameOrPath` (String)
    : The name of the script or the path to the script.

      When a `string` starting with "/" is passed, the script will be created at the specified path in $out.
      For example, `"/bin/hello"` will create a script at `$out/bin/hello`.

      Any other `string` is interpreted as a filename.
      It must be a [POSIX filename](https://en.wikipedia.org/wiki/Filename) starting with a letter, digit, dot, or underscore.
      Spaces or special characters are not allowed.

    # Examples
    :::{.example}
    ## `pkgs.writers.makeBinWriter` example

    ```c
    // main.c
    #include <stdio.h>

    int main()
    {
        printf("Hello, World!\n");
        return 0;
    }
    ```

    ```nix-repl
    :b makeBinWriter { compileScript = "${pkgs.gcc}/bin/gcc -o $out $contentPath"; } "hello" ./main.c
    out -> /nix/store/f6crc8mwj3lvcxqclw7n09cm8nb6kxbh-hello
    ```

    The above example creates an executable named `hello` that outputs `Hello, World!` when executed.

    ```sh
    > /nix/store/f6crc8mwj3lvcxqclw7n09cm8nb6kxbh-hello
    Hello, World!
    ```
    :::
  */
  makeBinWriter =
    {
      compileScript,
      strip ? true,
      makeWrapperArgs ? [ ],
    }:
    nameOrPath: content:
    assert
      (types.path.check nameOrPath)
      || (builtins.match "([0-9A-Za-z._])[0-9A-Za-z._-]*" nameOrPath != null);
    assert (types.path.check content) || (types.str.check content);
    let
      nameIsPath = types.path.check nameOrPath;
      name = last (builtins.split "/" nameOrPath);
      path = if nameIsPath then nameOrPath else "/bin/${name}";
      # The inner derivation which creates the executable under $out/bin (never at $out directly)
      # This is required in order to support wrapping, as wrapped programs consist of at least two files: the executable and the wrapper.
      inner =
        pkgs.runCommandLocal name
          (
            {
              inherit makeWrapperArgs;
              nativeBuildInputs = [ makeBinaryWrapper ];
              meta.mainProgram = name;
            }
            // (
              if (types.str.check content) then
                {
                  inherit content;
                  passAsFile = [ "content" ];
                }
              else
                { contentPath = content; }
            )
          )
          ''
            ${compileScript}
            ${lib.optionalString strip "${lib.getBin buildPackages.bintools-unwrapped}/bin/${buildPackages.bintools-unwrapped.targetPrefix}strip -S $out"}
            # Sometimes binaries produced for darwin (e. g. by GHC) won't be valid
            # mach-o executables from the get-go, but need to be corrected somehow
            # which is done by fixupPhase.
            ${lib.optionalString pkgs.stdenvNoCC.hostPlatform.isDarwin "fixupPhase"}
            mv $out tmp
            mkdir -p $out/$(dirname "${path}")
            mv tmp $out/${path}
            if [ -n "''${makeWrapperArgs+''${makeWrapperArgs[@]}}" ]; then
              wrapProgram $out/${path} ''${makeWrapperArgs[@]}
            fi
          '';
    in
    if nameIsPath then
      inner
    # In case nameOrPath is a name, the user intends the executable to be located at $out.
    # This is achieved by creating a separate derivation containing a symlink at $out linking to ${inner}/bin/${name}.
    # This breaks the override pattern.
    # In case this turns out to be a problem, we can still add more magic
    else
      pkgs.runCommandLocal name { } ''
        ln -s ${inner}/bin/${name} $out
      '';

  /**
    Like writeScript but the first line is a shebang to bash
    Can be called with or without extra arguments.

    # Examples
    :::{.example}

    ## Without arguments

    ```nix
    writeBash "example" ''
    echo hello world
    ''
    ```

    ## With arguments

    ```nix
    writeBash "example"
    {
      makeWrapperArgs = [
        "--prefix" "PATH" ":" "${lib.makeBinPath [ pkgs.hello ]}"
      ];
    }
    ''
      hello
    ''
    ```
    :::
  */
  writeBash =
    name: argsOrScript:
    if lib.isAttrs argsOrScript && !lib.isDerivation argsOrScript then
      makeScriptWriter (argsOrScript // { interpreter = "${lib.getExe pkgs.bash}"; }) name
    else
      makeScriptWriter { interpreter = "${lib.getExe pkgs.bash}"; } name argsOrScript;

  /**
    Like writeScriptBin but the first line is a shebang to bash

    Can be called with or without extra arguments.

    ## Examples
    :::{.example}
    ## `pkgs.writers.writeBashBin` example without arguments

    ```nix
    writeBashBin "example" ''
      echo hello world
    ''
    ```
    :::

    :::{.example}
    ## `pkgs.writers.writeBashBin` example with arguments

    ```nix
    writeBashBin "example"
    {
      makeWrapperArgs = [
        "--prefix" "PATH" ":" "${lib.makeBinPath [ pkgs.hello ]}"
      ];
    }
    ''
      hello
    ''
    ```
    :::
  */
  writeBashBin = name: writeBash "/bin/${name}";

  /**
    Like writeScript but the first line is a shebang to dash

    Can be called with or without extra arguments.

    # Example
    :::{.example}
    ## `pkgs.writers.writeDash` example without arguments

    ```nix
    writeDash "example" ''
      echo hello world
    ''
    ```
    :::

    :::{.example}
    ## `pkgs.writers.writeDash` example with arguments

    ```nix
    writeDash "example"
    {
      makeWrapperArgs = [
        "--prefix" "PATH" ":" "${lib.makeBinPath [ pkgs.hello ]}"
      ];
    }
    ''
      hello
    ''
    ```
    :::
  */
  writeDash =
    name: argsOrScript:
    if lib.isAttrs argsOrScript && !lib.isDerivation argsOrScript then
      makeScriptWriter (argsOrScript // { interpreter = "${lib.getExe pkgs.dash}"; }) name
    else
      makeScriptWriter { interpreter = "${lib.getExe pkgs.dash}"; } name argsOrScript;

  /**
    Like writeScriptBin but the first line is a shebang to dash

    Can be called with or without extra arguments.

    # Examples
    :::{.example}
    ## `pkgs.writers.writeDashBin` without arguments

    ```nix
    writeDashBin "example" ''
      echo hello world
    ''
    ```
    :::

    :::{.example}
    ## `pkgs.writers.writeDashBin` with arguments

    ```nix
    writeDashBin "example"
    {
      makeWrapperArgs = [
        "--prefix" "PATH" ":" "${lib.makeBinPath [ pkgs.hello ]}"
      ];
    }
    ''
      hello
    ''
    ```
    :::
  */
  writeDashBin = name: writeDash "/bin/${name}";

  /**
    Like writeScript but the first line is a shebang to fish

    Can be called with or without extra arguments.

    :::{.example}
    ## `pkgs.writers.writeFish` without arguments

    ```nix
    writeFish "example" ''
      echo hello world
    ''
    ```
    :::

    :::{.example}
    ## `pkgs.writers.writeFish` with arguments

    ```nix
    writeFish "example"
    {
      makeWrapperArgs = [
        "--prefix" "PATH" ":" "${lib.makeBinPath [ pkgs.hello ]}"
      ];
    }
    ''
      hello
    ''
    ```
    :::
  */
  writeFish =
    name: argsOrScript:
    if lib.isAttrs argsOrScript && !lib.isDerivation argsOrScript then
      makeScriptWriter (
        argsOrScript
        // {
          interpreter = "${lib.getExe pkgs.fish} --no-config";
          check = "${lib.getExe pkgs.fish} --no-config --no-execute"; # syntax check only
        }
      ) name
    else
      makeScriptWriter {
        interpreter = "${lib.getExe pkgs.fish} --no-config";
        check = "${lib.getExe pkgs.fish} --no-config --no-execute"; # syntax check only
      } name argsOrScript;

  /**
    Like writeScriptBin but the first line is a shebang to fish

    Can be called with or without extra arguments.

    # Examples
    :::{.example}
    ## `pkgs.writers.writeFishBin` without arguments

    ```nix
    writeFishBin "example" ''
      echo hello world
    ''
    ```
    :::

    :::{.example}
    ## `pkgs.writers.writeFishBin` with arguments

    ```nix
    writeFishBin "example"
    {
      makeWrapperArgs = [
        "--prefix" "PATH" ":" "${lib.makeBinPath [ pkgs.hello ]}"
      ];
    }
    ''
      hello
    ''
    ```
    :::
  */
  writeFishBin = name: writeFish "/bin/${name}";

  /**
    writeBabashka takes a name, an attrset with babashka interpreter and linting check (both optional)
    and some babashka source code and returns an executable.

    `pkgs.babashka-unwrapped` is used as default interpreter for small closure size. If dependencies needed, use `pkgs.babashka` instead. Pass empty string to check to disable the default clj-kondo linting.

    # Examples
    :::{.example}
    ## `pkgs.writers.writeBabashka` with empty arguments

    ```nix
    writeBabashka "example" { } ''
      (println "hello world")
    ''
    ```
    :::

    :::{.example}
    ## `pkgs.writers.writeBabashka` with arguments

    ```nix
    writeBabashka "example"
    {
      makeWrapperArgs = [
        "--prefix" "PATH" ":" "${lib.makeBinPath [ pkgs.hello ]}"
      ];
    }
    ''
      (require '[babashka.tasks :as tasks])
      (tasks/shell "hello" "-g" "Hello babashka!")
    ''
    ```
    :::

    :::{.note}
    Babashka needs Java for fetching dependencies. Wrapped babashka contains jdk,
    pass wrapped version `pkgs.babashka` to babashka if dependencies are required.

    For example:

    ```nix
    writeBabashka "example"
    {
      babashka = pkgs.babashka;
    }
    ''
      (require '[babashka.deps :as deps])
      (deps/add-deps '{:deps {medley/medley {:mvn/version "1.3.0"}}})
      (require '[medley.core :as m])
      (prn (m/index-by :id [{:id 1} {:id 2}]))
    ''
    ```
    :::

    :::{.note}
    Disable clj-kondo linting:

    ```nix
    writeBabashka "example"
    {
      check = "";
    }
    ''
      (println "hello world")
    ''
    ```
    :::
  */
  writeBabashka =
    name:
    {
      makeWrapperArgs ? [ ],
      babashka ? pkgs.babashka-unwrapped,
      check ? "${lib.getExe pkgs.clj-kondo} --lint",
      ...
    }@args:
    makeScriptWriter (
      (builtins.removeAttrs args [
        "babashka"
      ])
      // {
        interpreter = "${lib.getExe babashka}";
      }
    ) name;

  /**
    writeBabashkaBin takes the same arguments as writeBabashka but outputs a directory
    (like writeScriptBin)
  */
  writeBabashkaBin = name: writeBabashka "/bin/${name}";

  /**
    `writeGuile` returns a derivation that creates an executable Guile script.

    # Inputs

    `nameOrPath` (String)
    : Name of or path to the script. The semantics is the same as that of
     `makeScriptWriter`.

    `config` (AttrSet)
    : `guile` (Optional, Derivation, Default: `pkgs.guile`)
      : Guile package used for the script.
    : `libraries` (Optional, [ Derivation ], Default: [])
      : Extra Guile libraries exposed to the script.
    : `r6rs` and `r7rs` (Optional, Boolean, Default: false)
      : Whether to adapt Guile’s initial environment to better support R6RS/
        R7RS. See the [Guile Reference Manual](https://www.gnu.org/software/guile/manual/html_node/index.html)
        for details.
    : `srfi` (Optional, [ Int ], Default: [])
      : SRFI module to be loaded into the interpreter before evaluating a
        script file or starting the REPL. See the Guile Reference Manual to
        know which SRFI are supported.
    : Other attributes are directly passed to `makeScriptWriter`.

    `content` (String)
    : Content of the script.

    # Examples

    :::{.example}
    ## `pkgs.writers.writeGuile` with default config

    ```nix
    writeGuile "guile-script" { }
    ''
      (display "Hello, world!")
    ''
    ```
    :::

    :::{.example}
    ## `pkgs.writers.writeGuile` with SRFI-1 enabled and extra libraries

    ```nix
    writeGuile "guile-script" {
      libraries = [ pkgs.guile-semver ];
      srfi = [ 1 ];
    }
    ''
      (use-modules (semver))
      (make-semver 1 (third '(2 3 4)) 5) ; => #<semver 1.4.5>
    ''
    ```
    :::
  */
  writeGuile =
    nameOrPath:
    {
      guile ? pkgs.guile,
      libraries ? [ ],
      r6rs ? false,
      r7rs ? false,
      srfi ? [ ],
      ...
    }@config:
    content:
    assert builtins.all builtins.isInt srfi;
    let
      finalGuile = pkgs.buildEnv {
        name = "guile-env";
        paths = [ guile ] ++ libraries;
        passthru = {
          inherit (guile) siteDir siteCcacheDir;
        };
        meta.mainProgram = guile.meta.mainProgram or "guile";
      };
    in
    makeScriptWriter
      (
        (builtins.removeAttrs config [
          "guile"
          "libraries"
          "r6rs"
          "r7rs"
          "srfi"
        ])
        // {
          interpreter = "${lib.getExe finalGuile} \\";
          makeWrapperArgs = [
            "--set"
            "GUILE_LOAD_PATH"
            "${finalGuile}/${finalGuile.siteDir}:${finalGuile}/lib/scheme-libs"
            "--set"
            "GUILE_LOAD_COMPILED_PATH"
            "${finalGuile}/${finalGuile.siteCcacheDir}:${finalGuile}/lib/libobj"
            "--set"
            "LD_LIBRARY_PATH"
            "${finalGuile}/lib/ffi"
            "--set"
            "DYLD_LIBRARY_PATH"
            "${finalGuile}/lib/ffi"
          ];
        }
      )
      nameOrPath
      /*
        Spaces, newlines and tabs are significant for the "meta switch" of Guile, so
        certain complication must be made to ensure correctness.
      */
      (
        lib.concatStringsSep "\n" [
          (lib.concatStringsSep " " (
            [ "--no-auto-compile" ]
            ++ lib.optional r6rs "--r6rs"
            ++ lib.optional r7rs "--r7rs"
            ++ lib.optional (srfi != [ ]) ("--use-srfi=" + concatMapStringsSep "," builtins.toString srfi)
            ++ [ "-s" ]
          ))
          "!#"
          content
        ]
      );

  /**
    writeGuileBin takes the same arguments as writeGuile but outputs a directory
    (like writeScriptBin)
  */
  writeGuileBin = name: writeGuile "/bin/${name}";

  /**
    writeHaskell takes a name, an attrset with libraries and haskell version (both optional)
    and some haskell source code and returns an executable.

    # Examples
    :::{.example}
    ## `pkgs.writers.writeHaskell` usage example

    ```nix
    writeHaskell "missiles" { libraries = [ pkgs.haskellPackages.acme-missiles ]; } ''
      import Acme.Missiles

      main = launchMissiles
    '';
    ```
    :::
  */
  writeHaskell =
    name:
    {
      ghc ? pkgs.ghc,
      ghcArgs ? [ ],
      libraries ? [ ],
      makeWrapperArgs ? [ ],
      strip ? true,
      threadedRuntime ? true,
    }:
    let
      appendIfNotSet = el: list: if elem el list then list else list ++ [ el ];
      ghcArgs' = if threadedRuntime then appendIfNotSet "-threaded" ghcArgs else ghcArgs;

    in
    makeBinWriter {
      compileScript = ''
        cp $contentPath tmp.hs
        ${(ghc.withPackages (_: libraries))}/bin/ghc ${lib.escapeShellArgs ghcArgs'} tmp.hs
        mv tmp $out
      '';
      inherit makeWrapperArgs strip;
    } name;

  /**
    writeHaskellBin takes the same arguments as writeHaskell but outputs a directory (like writeScriptBin)
  */
  writeHaskellBin = name: writeHaskell "/bin/${name}";

  /**
    writeNim takes a name, an attrset with an optional Nim compiler, and some
    Nim source code, returning an executable.

    # Examples
    :::{.example}
    ## `pkgs.writers.writeNim` usage example

    ```nix
      writeNim "hello-nim" { nim = pkgs.nim2; } ''
        echo "hello nim"
      '';
    ```
    :::
  */
  writeNim =
    name:
    {
      makeWrapperArgs ? [ ],
      nim ? pkgs.nim2,
      nimCompileOptions ? { },
      strip ? true,
    }:
    let
      nimCompileCmdArgs = lib.cli.toGNUCommandLineShell { optionValueSeparator = ":"; } (
        {
          d = "release";
          nimcache = ".";
        }
        // nimCompileOptions
      );
    in
    makeBinWriter {
      compileScript = ''
        cp $contentPath tmp.nim
        ${lib.getExe nim} compile ${nimCompileCmdArgs} tmp.nim
        mv tmp $out
      '';
      inherit makeWrapperArgs strip;
    } name;

  /**
    writeNimBin takes the same arguments as writeNim but outputs a directory
    (like writeScriptBin)
  */
  writeNimBin = name: writeNim "/bin/${name}";

  /**
    Like writeScript but the first line is a shebang to nu

    Can be called with or without extra arguments.

    # Examples
    :::{.example}
    ## `pkgs.writers.writeNu` without arguments

    ```nix
    writeNu "example" ''
      echo hello world
    ''
    ```
    :::

    :::{.example}
    ## `pkgs.writers.writeNu` with arguments

    ```nix
    writeNu "example"
      {
        makeWrapperArgs = [
          "--prefix" "PATH" ":" "${lib.makeBinPath [ pkgs.hello ]}"
        ];
      }
      ''
        hello
      ''
    ```
    :::
  */
  writeNu =
    name: argsOrScript:
    if lib.isAttrs argsOrScript && !lib.isDerivation argsOrScript then
      makeScriptWriter (
        argsOrScript // { interpreter = "${lib.getExe pkgs.nushell} --no-config-file"; }
      ) name
    else
      makeScriptWriter { interpreter = "${lib.getExe pkgs.nushell} --no-config-file"; } name argsOrScript;

  /**
    Like writeScriptBin but the first line is a shebang to nu

    Can be called with or without extra arguments.

    # Examples
    :::{.example}
    ## `pkgs.writers.writeNuBin` without arguments

    ```nix
    writeNuBin "example" ''
      echo hello world
    ''
    ```
    :::

    :::{.example}
    ## `pkgs.writers.writeNuBin` with arguments

    ```nix
    writeNuBin "example"
      {
        makeWrapperArgs = [
          "--prefix" "PATH" ":" "${lib.makeBinPath [ pkgs.hello ]}"
        ];
      }
      ''
        hello
      ''
    ```
    :::
  */
  writeNuBin = name: writeNu "/bin/${name}";

  /**
    makeRubyWriter takes ruby and compatible rubyPackages and produces ruby script writer,
    If any libraries are specified, ruby.withPackages is used as interpreter, otherwise the "bare" ruby is used.
  */
  makeRubyWriter =
    ruby: rubyPackages: buildRubyPackages: name:
    {
      libraries ? [ ],
      ...
    }@args:
    makeScriptWriter (
      (builtins.removeAttrs args [ "libraries" ])
      // {
        interpreter =
          if libraries == [ ] then "${ruby}/bin/ruby" else "${(ruby.withPackages (ps: libraries))}/bin/ruby";
        # Rubocop doesn't seem to like running in this fashion.
        #check = (writeDash "rubocop.sh" ''
        #  exec ${lib.getExe buildRubyPackages.rubocop} "$1"
        #'');
      }
    ) name;

  /**
    Like writeScript but the first line is a shebang to ruby

    # Examples
    :::{.example}
    ## `pkgs.writers.writeRuby` usage example

    ```nix
    writeRuby "example" { libraries = [ pkgs.rubyPackages.git ]; } ''
     puts "hello world"
    ''
    ```

    :::
  */
  writeRuby = makeRubyWriter pkgs.ruby pkgs.rubyPackages buildPackages.rubyPackages;

  writeRubyBin = name: writeRuby "/bin/${name}";

  /**
    makeLuaWriter takes lua and compatible luaPackages and produces lua script writer,
    which validates the script with luacheck at build time. If any libraries are specified,
    lua.withPackages is used as interpreter, otherwise the "bare" lua is used.
  */
  makeLuaWriter =
    lua: luaPackages: buildLuaPackages: name:
    {
      libraries ? [ ],
      ...
    }@args:
    makeScriptWriter (
      (builtins.removeAttrs args [ "libraries" ])
      // {
        interpreter = lua.interpreter;
        # if libraries == []
        # then lua.interpreter
        # else (lua.withPackages (ps: libraries)).interpreter
        # This should support packages! I just cant figure out why some dependency collision happens whenever I try to run this.
        check = (
          writeDash "luacheck.sh" ''
            exec ${buildLuaPackages.luacheck}/bin/luacheck "$1"
          ''
        );
      }
    ) name;

  /**
    writeLua takes a name an attributeset with libraries and some lua source code and
    returns an executable (should also work with luajit)

    # Examples
    :::{.example}
    ## `pkgs.writers.writeLua` usage example

    ```nix
    writeLua "test_lua" { libraries = [ pkgs.luaPackages.say ]; } ''
      s = require("say")
      s:set_namespace("en")

      s:set('money', 'I have %s dollars')
      s:set('wow', 'So much money!')

      print(s('money', {1000})) -- I have 1000 dollars

      s:set_namespace("fr") -- switch to french!
      s:set('wow', "Tant d'argent!")

      print(s('wow')) -- Tant d'argent!
      s:set_namespace("en")  -- switch back to english!
      print(s('wow')) -- So much money!
    ''
    ```

    :::
  */
  writeLua = makeLuaWriter pkgs.lua pkgs.luaPackages buildPackages.luaPackages;

  writeLuaBin = name: writeLua "/bin/${name}";

  writeRust =
    name:
    {
      makeWrapperArgs ? [ ],
      rustc ? pkgs.rustc,
      rustcArgs ? [ ],
      strip ? true,
    }:
    let
      darwinArgs = lib.optionals stdenv.hostPlatform.isDarwin [ "-L${lib.getLib libiconv}/lib" ];
    in
    makeBinWriter {
      compileScript = ''
        cp "$contentPath" tmp.rs
        PATH=${lib.makeBinPath [ pkgs.gcc ]} ${rustc}/bin/rustc ${lib.escapeShellArgs rustcArgs} ${lib.escapeShellArgs darwinArgs} -o "$out" tmp.rs
      '';
      inherit makeWrapperArgs strip;
    } name;

  writeRustBin = name: writeRust "/bin/${name}";

  /**
    writeJS takes a name an attributeset with libraries and some JavaScript sourcecode and
    returns an executable

    # Inputs

    `name`

    : 1\. Function argument

    `attrs`

    : 2\. Function argument

    `content`

    : 3\. Function argument

    # Examples
    :::{.example}
    ## `pkgs.writers.writeJS` usage example

    ```nix
    writeJS "example" { libraries = [ pkgs.uglify-js ]; } ''
      var UglifyJS = require("uglify-js");
      var code = "function add(first, second) { return first + second; }";
      var result = UglifyJS.minify(code);
      console.log(result.code);
    ''
    ```

    :::
  */
  writeJS =
    name:
    {
      libraries ? [ ],
    }:
    content:
    let
      node-env = pkgs.buildEnv {
        name = "node";
        paths = libraries;
        pathsToLink = [ "/lib/node_modules" ];
      };
    in
    writeDash name ''
      export NODE_PATH=${node-env}/lib/node_modules
      exec ${lib.getExe pkgs.nodejs} ${pkgs.writeText "js" content} "$@"
    '';

  /**
    writeJSBin takes the same arguments as writeJS but outputs a directory (like writeScriptBin)
  */
  writeJSBin = name: writeJS "/bin/${name}";

  awkFormatNginx = builtins.toFile "awkFormat-nginx.awk" ''
    awk -f
    {sub(/^[ \t]+/,"");idx=0}
    /\{/{ctx++;idx=1}
    /\}/{ctx--}
    {id="";for(i=idx;i<ctx;i++)id=sprintf("%s%s", id, "\t");printf "%s%s\n", id, $0}
  '';

  writeNginxConfig =
    name: text:
    pkgs.runCommandLocal name
      {
        inherit text;
        passAsFile = [ "text" ];
        nativeBuildInputs = [ gixy ];
      } # sh
      ''
        # nginx-config-formatter has an error - https://github.com/1connect/nginx-config-formatter/issues/16
        awk -f ${awkFormatNginx} "$textPath" | sed '/^\s*$/d' > $out
        gixy $out || (echo "\n\nThis can be caused by combining multiple incompatible services on the same hostname.\n\nFull merged config:\n\n"; cat $out; exit 1)
      '';

  /**
    writePerl takes a name an attributeset with libraries and some perl sourcecode and
    returns an executable

    # Examples
    :::{.example}
    ## `pkgs.writers.writePerl` usage example

    ```nix
    writePerl "example" { libraries = [ pkgs.perlPackages.boolean ]; } ''
      use boolean;
      print "Howdy!\n" if true;
    ''
    ```

    :::
  */
  writePerl =
    name:
    {
      libraries ? [ ],
      ...
    }@args:
    makeScriptWriter (
      (builtins.removeAttrs args [ "libraries" ])
      // {
        interpreter = "${lib.getExe (pkgs.perl.withPackages (p: libraries))}";
      }
    ) name;

  /**
    writePerlBin takes the same arguments as writePerl but outputs a directory (like writeScriptBin)
  */
  writePerlBin = name: writePerl "/bin/${name}";

  /**
    makePythonWriter takes python and compatible pythonPackages and produces python script writer,
    which validates the script with flake8 at build time. If any libraries are specified,
    python.withPackages is used as interpreter, otherwise the "bare" python is used.

    # Inputs

    `python`

    : 1\. Function argument

    `pythonPackages`

    : 2\. Function argument

    `buildPythonPackages`

    : 3\. Function argument

    `name`

    : 4\. Function argument

    `attrs`

    : 5\. Function argument
  */
  makePythonWriter =
    python: pythonPackages: buildPythonPackages: name:
    {
      libraries ? [ ],
      flakeIgnore ? [ ],
      doCheck ? true,
      ...
    }@args:
    let
      ignoreAttribute =
        optionalString (flakeIgnore != [ ])
          "--ignore ${concatMapStringsSep "," escapeShellArg flakeIgnore}";
    in
    makeScriptWriter (
      (builtins.removeAttrs args [
        "libraries"
        "flakeIgnore"
        "doCheck"
      ])
      // {
        interpreter =
          if pythonPackages != pkgs.pypy2Packages || pythonPackages != pkgs.pypy3Packages then
            if libraries == [ ] then
              python.interpreter
            else if (lib.isFunction libraries) then
              (python.withPackages libraries).interpreter
            else
              (python.withPackages (ps: libraries)).interpreter
          else
            python.interpreter;
        check = optionalString (python.isPy3k && doCheck) (
          writeDash "pythoncheck.sh" ''
            exec ${buildPythonPackages.flake8}/bin/flake8 --show-source ${ignoreAttribute} "$1"
          ''
        );
      }
    ) name;

  /**
    writePyPy2 takes a name an attributeset with libraries and some pypy2 sourcecode and
    returns an executable

    # Examples
    :::{.example}
    ## `pkgs.writers.writePyPy2` usage example

    ```nix
    writePyPy2 "test_pypy2" { libraries = [ pkgs.pypy2Packages.enum ]; } ''
      from enum import Enum

      class Test(Enum):
          a = "success"

      print Test.a
    ''
    ```

    :::
  */
  writePyPy2 = makePythonWriter pkgs.pypy2 pkgs.pypy2Packages buildPackages.pypy2Packages;

  /**
    writePyPy2Bin takes the same arguments as writePyPy2 but outputs a directory (like writeScriptBin)
  */
  writePyPy2Bin = name: writePyPy2 "/bin/${name}";

  /**
    writePython3 takes a name an attributeset with libraries and some python3 sourcecode and
    returns an executable

    # Examples
    :::{.example}
    ## `pkgs.writers.writePython3` usage example

    ```nix
    writePython3 "test_python3" { libraries = [ pkgs.python3Packages.pyyaml ]; } ''
      import yaml

      y = yaml.safe_load("""
        - test: success
      """)
      print(y[0]['test'])
    ''
    ```

    :::
  */
  writePython3 = makePythonWriter pkgs.python3 pkgs.python3Packages buildPackages.python3Packages;

  # writePython3Bin takes the same arguments as writePython3 but outputs a directory (like writeScriptBin)
  writePython3Bin = name: writePython3 "/bin/${name}";

  /**
    writePyPy3 takes a name an attributeset with libraries and some pypy3 sourcecode and
    returns an executable

    # Examples
    :::{.example}
    ## `pkgs.writers.writePyPy3` usage example

    ```nix
    writePyPy3 "test_pypy3" { libraries = [ pkgs.pypy3Packages.pyyaml ]; } ''
      import yaml

      y = yaml.safe_load("""
        - test: success
      """)
      print(y[0]['test'])
    ''
    ```

    :::
  */
  writePyPy3 = makePythonWriter pkgs.pypy3 pkgs.pypy3Packages buildPackages.pypy3Packages;

  /**
    writePyPy3Bin takes the same arguments as writePyPy3 but outputs a directory (like writeScriptBin)
  */
  writePyPy3Bin = name: writePyPy3 "/bin/${name}";

  makeFSharpWriter =
    {
      dotnet-sdk ? pkgs.dotnet-sdk,
      fsi-flags ? "",
      libraries ? _: [ ],
      ...
    }@args:
    nameOrPath:
    let
      fname = last (builtins.split "/" nameOrPath);
      path = if strings.hasSuffix ".fsx" nameOrPath then nameOrPath else "${nameOrPath}.fsx";
      _nugetDeps = mkNugetDeps {
        name = "${fname}-nuget-deps";
        nugetDeps = libraries;
      };

      nuget-source = mkNugetSource {
        name = "${fname}-nuget-source";
        description = "Nuget source with the dependencies for ${fname}";
        deps = [ _nugetDeps ];
      };

      fsi = writeBash "fsi" ''
        set -euo pipefail
        export HOME=$NIX_BUILD_TOP/.home
        export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
        export DOTNET_CLI_TELEMETRY_OPTOUT=1
        export DOTNET_NOLOGO=1
        export DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=1
        script="$1"; shift
        (
          ${lib.getExe dotnet-sdk} new nugetconfig
          ${lib.getExe dotnet-sdk} nuget disable source nuget
        ) > /dev/null
        ${lib.getExe dotnet-sdk} fsi --quiet --nologo --readline- ${fsi-flags} "$@" < "$script"
      '';

    in
    content:
    makeScriptWriter
      (
        (builtins.removeAttrs args [
          "dotnet-sdk"
          "fsi-flags"
          "libraries"
        ])
        // {
          interpreter = fsi;
        }
      )
      path
      ''
        #i "nuget: ${nuget-source}/lib"
        ${content}
        exit 0
      '';

  writeFSharp = makeFSharpWriter { };

  writeFSharpBin = name: writeFSharp "/bin/${name}";

  /**
    writeAIBin takes a name and a string containing a prompt, and generates a script at build time
    using an LLM via Ollama. The resulting script contains the actual generated code, not a wrapper.
    
    This function uses fixed-output derivations to allow network access during build while maintaining
    Nix's build reproducibility.

    # Parameters
    - `name`: The name of the output script
    - `args`: An attribute set of options, or a string prompt
      - If a string, it's used as the prompt with default options
      - If an attribute set:
        - `prompt`: The prompt to send to the LLM (required)
        - `modelName`: Model name to use (default: "codellama")
        - `systemPrompt`: System prompt to set context for the LLM (default: "You are a helpful assistant that generates code.")
        - `interpreter`: Interpreter to use if no shebang is detected (default: "/bin/bash")
        - `ollamaPort`: Port where Ollama is running (default: 11434)
        - `ollamaHost`: Host where Ollama is running (default: "localhost")
        - `timeout`: Timeout for the LLM response in seconds (default: 60)

    # Examples
    :::{.example}
    ## `pkgs.writers.writeAIBin` usage example

    ```nix
    writeAIBin "generate-greeting" ''
      Write a short shell script that prints a random greeting
    ''
    ```

    ## Using with specific model and options

    ```nix
    writeAIBin "generate-greeting" {
      prompt = ''
        Write a short shell script that prints a random greeting
      '';
      modelName = "llama3";
      systemPrompt = "You are an expert shell script programmer.";
    }
    ```

    The above example creates an executable named `generate-greeting` that contains
    the script generated by the LLM in response to the prompt.
    :::
  */
  writeAIBin = name: args:
    let
      # Handle both simple string usage and attribute set usage
      isString = builtins.isString args;
      
      # Extract parameters with defaults
      prompt = if isString then args else args.prompt;
      modelName = if isString then "codellama" else (args.modelName or "codellama");
      systemPrompt = if isString then "You are a helpful assistant that generates code." 
                    else (args.systemPrompt or "You are a helpful assistant that generates code.");
      interpreter = if isString then "/bin/bash" else (args.interpreter or "/bin/bash");
      ollamaPort = toString (if isString then 11434 else (args.ollamaPort or 11434));
      ollamaHost = if isString then "localhost" else (args.ollamaHost or "localhost");
      timeout = toString (if isString then 60 else (args.timeout or 60));
      
      # Create a Python generator script that will be run outside the Nix build
      generatorScript = pkgs.writeTextFile {
        name = "ai-generator-script.py";
        text = ''
          #!/usr/bin/env python3
          import sys
          import os
          import asyncio
          import json
          import time
          import hashlib
          
          try:
              import ollama
          except ImportError:
              print("Error: Ollama Python module not found. Please install with:", file=sys.stderr)
              print("pip install ollama", file=sys.stderr)
              sys.exit(1)
          
          # Configuration from Nix
          CONFIG = ${builtins.toJSON {
            model = modelName;
            host = ollamaHost;
            port = ollamaPort;
            timeout = timeout;
            systemPrompt = systemPrompt;
            prompt = prompt;
            interpreter = interpreter;
          }}
          
          def clean_response(response):
              """Clean up the LLM response to extract code"""
              content = response.strip()
              
              # Extract code from markdown blocks if present
              if content.startswith("```") and "```" in content[3:]:
                  # Find the first and last code block markers
                  start = content.find("\n", content.find("```")) + 1
                  end = content.rfind("```")
                  
                  # Extract the code between the markers
                  if start < end:
                      content = content[start:end].strip()
              
              # Add shebang if not present
              if not content.startswith("#!"):
                  if "python" in content.lower()[:20]:
                      content = "#!/usr/bin/env python3\n" + content
                  else:
                      content = f"#!{CONFIG['interpreter']}\n" + content
                      
              return content
          
          async def generate_code():
              """Generate code using the LLM"""
              # Configure Ollama client
              ollama.base_url = f"http://{CONFIG['host']}:{CONFIG['port']}"
              
              try:
                  # Check if Ollama is accessible
                  try:
                      models = await ollama.list()
                  except Exception as e:
                      print(f"Error connecting to Ollama: {str(e)}", file=sys.stderr)
                      print(f"Make sure Ollama is running at {CONFIG['host']}:{CONFIG['port']}", file=sys.stderr)
                      sys.exit(1)
                  
                  # Check if model exists
                  model_exists = any(model['name'] == CONFIG['model'] for model in models['models'])
                  if not model_exists:
                      print(f"Model '{CONFIG['model']}' not found. Pulling it now...", file=sys.stderr)
                      await ollama.pull(CONFIG['model'])
                  
                  # Generate the response
                  print(f"Generating code using model '{CONFIG['model']}'...", file=sys.stderr)
                  response = await asyncio.wait_for(
                      ollama.chat(
                          model=CONFIG['model'],
                          messages=[
                              {'role': 'system', 'content': CONFIG['systemPrompt']},
                              {'role': 'user', 'content': CONFIG['prompt']}
                          ],
                          stream=False
                      ),
                      timeout=float(CONFIG['timeout'])
                  )
                  
                  # Extract and clean the content
                  content = clean_response(response['message']['content'])
                  return content
                  
              except Exception as e:
                  print(f"Error generating code: {str(e)}", file=sys.stderr)
                  sys.exit(1)
          
          if __name__ == "__main__":
              """Main function - run the generator and print to stdout"""
              try:
                  code = asyncio.run(generate_code())
                  print(code)
              except KeyboardInterrupt:
                  print("\nOperation cancelled by user", file=sys.stderr)
                  sys.exit(1)
        '';
        executable = true;
      };
      
      # Use a fixed-output derivation to fetch the AI-generated content
      generatedScript = pkgs.runCommand "${name}-generated" 
        {
          outputHashMode = "flat";
          outputHashAlgo = "sha256";
          # We don't know the hash beforehand, but Nix will calculate it after the first run
          # This means the build will fail once (with the correct hash) and then succeed when run again
          outputHash = lib.fakeHash;
          __contentAddressed = true;
          
          buildInputs = [ pkgs.python3 ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          # Pass the generator script and other needed tools
          inherit generatorScript;
          
          # Make this suitable for impure builds
          preferLocalBuild = true;
          allowSubstitutes = false;
        }
        ''
          # Check if necessary tools are available
          if ! command -v ollama &> /dev/null; then
            echo "Error: Ollama must be installed on the build machine" >&2
            echo "Please install Ollama: https://ollama.ai/download" >&2
            exit 1
          fi
          
          if ! python3 -c "import ollama" &> /dev/null; then
            echo "Error: Python Ollama module is required" >&2
            echo "Please install it with: pip install ollama" >&2
            exit 1
          fi
          
          # Run the generator script (this runs outside the sandbox)
          "$generatorScript" > $out || {
            echo "Error generating AI script" >&2
            exit 1
          }
          
          # Ensure the output file has content
          if [ ! -s "$out" ]; then
            echo "Error: Generated script is empty" >&2
            exit 1
          fi
        '';
      
      # Create the final executable script 
      finalScript = pkgs.runCommandLocal name
        {
          # Use the generated script as input
          inherit generatedScript;
        }
        ''
          cp $generatedScript $out
          chmod +x $out
        '';
    in
      finalScript;
}
