#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH_FILE="$BASEDIR/deploy-ollama-local.sh"
BAT_FILE="$BASEDIR/deploy-ollama-local.bat"

replace_sh_heredoc() {
  local marker="$1"
  local src="$2"
  local src_text
  src_text="$(cat "$src")"
  MARKER="$marker" SRC_TEXT="$src_text" perl -0777 -i -pe '
    my $m = $ENV{MARKER};
    my $s = $ENV{SRC_TEXT};
    my $re = qr/(<< '\''\Q$m\E'\''\n)(.*?)(\n\Q$m\E)/s;
    if ($_ !~ $re) { die "Marker not found: $m\n"; }
    s/$re/$1$s$3/s;
  ' "$SH_FILE"
}

replace_bat_region() {
  local region="$1"
  local src="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v region="$region" -v src="$src" '
    BEGIN { in_region=0; in_payload=0; replaced=0 }
    {
      if ($0 == "::#region " region) {
        in_region=1
        print
        next
      }
      if (in_region==1 && index($0, "Set-Content -Path $f -Encoding UTF8 -Value @\047") > 0) {
        print
        while ((getline line < src) > 0) print "::" line
        close(src)
        in_payload=1
        replaced=1
        next
      }
      if (in_payload==1) {
        if (index($0, "::\047@") == 1) {
          print
          in_payload=0
        }
        next
      }
      print
      if (in_region==1 && $0 == "::#endregion") in_region=0
    }
    END {
      if (replaced==0) {
        print "Region not found: " region > "/dev/stderr"
        exit 1
      }
    }
  ' "$BAT_FILE" > "$tmp"
  mv "$tmp" "$BAT_FILE"
}

replace_sh_heredoc "CADDYFILE_EOF" "$BASEDIR/config/Caddyfile"
replace_sh_heredoc "HYBRID_EOF" "$BASEDIR/config/docker-compose.hybrid.yml"
replace_sh_heredoc "CADDYONLY_EOF" "$BASEDIR/config/docker-compose.caddy-only.yml"
replace_sh_heredoc "NVIDIA_EOF" "$BASEDIR/config/docker-compose.nvidia.yml"
replace_sh_heredoc "AMD_EOF" "$BASEDIR/config/docker-compose.amd.yml"
replace_sh_heredoc "CPU_EOF" "$BASEDIR/config/docker-compose.cpu.yml"
replace_sh_heredoc "HTML_EOF" "$BASEDIR/ai-console.html"

replace_bat_region "Caddyfile" "$BASEDIR/config/Caddyfile"
replace_bat_region "docker-compose.hybrid.yml" "$BASEDIR/config/docker-compose.hybrid.yml"
replace_bat_region "docker-compose.caddy-only.yml" "$BASEDIR/config/docker-compose.caddy-only.yml"
replace_bat_region "detect-gpu.ps1" "$BASEDIR/tools/detect-gpu.ps1"
replace_bat_region "ai-console.html" "$BASEDIR/ai-console.html"

echo "[OK] Embedded inside blocks updated in deploy-ollama-local.sh and deploy-ollama-local.bat"
