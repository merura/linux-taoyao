# Proprietary firmware for xiaomi-taoyao (adsp, cdsp, gpu, ipa, modem,
# sensors, vpu, wpss), extracted from stock by zstas.
#
# The repository is already laid out as lib/firmware/... and
# usr/share/qcom/..., which is what Mobile NixOS expects, so this is
# essentially just a copy.
{ stdenvNoCC
, fetchFromGitHub
}:

stdenvNoCC.mkDerivation {
  pname = "firmware-xiaomi-taoyao";
  version = "2026-07-09";

  src = fetchFromGitHub {
    owner = "zstas";
    repo = "firmware-xiaomi-taoyao";
    rev = "fb9b96ddd6e96398d9d70563f71f15a85dac9566";
    hash = "sha256-Nk08hjbxhFOfNFVZoXzutYN1DcJBC4dLz/9Vb8OJGYg=";
  };

  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r lib $out/
    if [ -d usr ]; then
      cp -r usr $out/
    fi
    chmod -R u+w $out
    find $out -type f -exec chmod 0644 {} +

    runHook postInstall
  '';

  meta = {
    description = "Firmware for Xiaomi 12 Lite 5G (taoyao)";
    # Proprietary Qualcomm/Xiaomi blobs.
    license = {
      free = false;
      redistributable = false;
      shortName = "proprietary";
    };
  };
}
