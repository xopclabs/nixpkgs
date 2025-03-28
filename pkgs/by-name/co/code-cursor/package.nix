{
  lib,
  stdenvNoCC,
  fetchurl,
  appimageTools,
  makeWrapper,
  writeScript,
  undmg,
}:
let
  pname = "cursor";
  version = "0.47.8";

  inherit (stdenvNoCC) hostPlatform;

  sources = {
    x86_64-linux = fetchurl {
      url = "https://downloads.cursor.com/production/client/linux/x64/appimage/Cursor-0.47.8-82ef0f61c01d079d1b7e5ab04d88499d5af500e3.deb.glibc2.25-x86_64.AppImage";
      hash = "sha256-3Ph5A+x1hW0SOaX8CF7b/8Fq7eMeBkG1ju9vud6Cbn0=";
    };
    aarch64-linux = fetchurl {
      url = "https://download.todesktop.com/230313mzl4w4u92/cursor-0.45.14-build-250219jnihavxsz-arm64.AppImage";
      hash = "sha256-8OUlPuPNgqbGe2x7gG+m3n3u6UDvgnVekkjJ08pVORs=";
    };
    x86_64-darwin = fetchurl {
      url = "https://download.todesktop.com/230313mzl4w4u92/Cursor%200.45.14%20-%20Build%20250219jnihavxsz-x64.dmg";
      hash = "sha256-NyDY74PZjSjpuTSVaO/l9adPcLX1kytyrFGQjJ/8WcQ=";
    };
    aarch64-darwin = fetchurl {
      url = "https://download.todesktop.com/230313mzl4w4u92/Cursor%200.45.14%20-%20Build%20250219jnihavxsz-arm64.dmg";
      hash = "sha256-A503TxDDFENqMnc1hy/lMMyIgC7YwwRYPJy+tp649Eg=";
    };
  };

  source = sources.${hostPlatform.system};

  # Linux -- build from AppImage
  appimageContents = appimageTools.extractType2 {
    inherit version pname;
    src = source;
  };

  wrappedAppimage = appimageTools.wrapType2 {
    inherit version pname;
    src = source;
  };

in
stdenvNoCC.mkDerivation {
  inherit pname version;

  src = if hostPlatform.isLinux then wrappedAppimage else source;

  nativeBuildInputs =
    lib.optionals hostPlatform.isLinux [ makeWrapper ]
    ++ lib.optionals hostPlatform.isDarwin [ undmg ];

  sourceRoot = lib.optionalString hostPlatform.isDarwin ".";

  # Don't break code signing
  dontUpdateAutotoolsGnuConfigScripts = hostPlatform.isDarwin;
  dontConfigure = hostPlatform.isDarwin;
  dontFixup = hostPlatform.isDarwin;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/

    ${lib.optionalString hostPlatform.isLinux ''
      cp -r bin $out/bin
      mkdir -p $out/share/cursor
      cp -a ${appimageContents}/locales $out/share/cursor
      cp -a ${appimageContents}/resources $out/share/cursor
      cp -a ${appimageContents}/usr/share/icons $out/share/
      install -Dm 644 ${appimageContents}/cursor.desktop -t $out/share/applications/

      substituteInPlace $out/share/applications/cursor.desktop --replace-fail "AppRun" "cursor"

      wrapProgram $out/bin/cursor \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}} --no-update"
    ''}

    ${lib.optionalString hostPlatform.isDarwin ''
      APP_DIR="$out/Applications"
      CURSOR_APP="$APP_DIR/Cursor.app"
      mkdir -p "$APP_DIR"
      cp -Rp Cursor.app "$APP_DIR"
      mkdir -p "$out/bin"
      cat << EOF > "$out/bin/cursor"
      #!${stdenvNoCC.shell}
      open -na "$CURSOR_APP" --args "\$@"
      EOF
      chmod +x "$out/bin/cursor"
    ''}

    runHook postInstall
  '';

  passthru = {
    inherit sources;
    updateScript = writeScript "update.sh" ''
      #!/usr/bin/env nix-shell
      #!nix-shell -i bash -p curl yq coreutils gnused trurl common-updater-scripts
      set -eu -o pipefail

      baseUrl="https://download.todesktop.com/230313mzl4w4u92"
      latestLinux="$(curl -s $baseUrl/latest-linux.yml)"
      latestDarwin="$(curl -s $baseUrl/latest-mac.yml)"
      linuxVersion="$(echo "$latestLinux" | yq -r .version)"

      currentVersion=$(nix-instantiate --eval -E "with import ./. {}; code-cursor.version or (lib.getVersion code-cursor)" | tr -d '"')

      if [[ "$linuxVersion" != "$currentVersion" ]]; then
          darwinVersion="$(echo "$latestDarwin" | yq -r .version)"
          if [ "$linuxVersion" != "$darwinVersion" ]; then
              echo "Linux version ($linuxVersion) and Darwin version ($darwinVersion) do not match"
              exit 1
          fi
          version="$linuxVersion"

          linuxFilename="$(echo "$latestLinux" | yq -r '.files[] | .url | select(. | endswith(".AppImage"))' | head -n 1)"
          linuxStem="$(echo "$linuxFilename" | sed -E s/^\(.+build.+\)-[^-]+AppImage$/\\1/)"

          darwinFilename="$(echo "$latestDarwin" | yq -r '.files[] | .url | select(. | endswith(".dmg"))' | head -n 1)"
          darwinStem="$(echo "$darwinFilename" | sed -E s/^\(.+Build[^-]+\)-.+dmg$/\\1/)"

          for platform in  "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"; do
              if [ $platform = "x86_64-linux" ]; then
                  url="$baseUrl/$linuxStem-x86_64.AppImage"
              elif [ $platform = "aarch64-linux" ]; then
                  url="$baseUrl/$linuxStem-arm64.AppImage"
              elif [ $platform = "x86_64-darwin" ]; then
                  url="$baseUrl/$darwinStem-x64.dmg"
              elif [ $platform = "aarch64-darwin" ]; then
                  url="$baseUrl/$darwinStem-arm64.dmg"
              else
                  echo "Unsupported platform: $platform"
                  exit 1
              fi

              url=$(trurl --accept-space "$url")
              hash=$(nix-hash --to-sri --type sha256 "$(nix-prefetch-url "$url" --name "cursor-$version")")
              update-source-version code-cursor $version $hash $url --system=$platform --ignore-same-version --source-key="sources.$platform"
          done
      fi
    '';
  };

  meta = {
    description = "AI-powered code editor built on vscode";
    homepage = "https://cursor.com";
    changelog = "https://cursor.com/changelog";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    maintainers = with lib.maintainers; [
      sarahec
      aspauldingcode
    ];
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "cursor";
  };
}
