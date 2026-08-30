#!/bin/bash

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export USER="${USER:-$(id -un)}"

SPACE_JSON=$(yabai -m query --spaces --space 2>/dev/null) || exit 0
SPACE_INDEX=$(jq -r '.index // empty' <<<"$SPACE_JSON" 2>/dev/null) || exit 0
MODE=$(jq -r '.type // ""' <<<"$SPACE_JSON" 2>/dev/null) || exit 0

if [ -z "$SPACE_INDEX" ]; then
  exit 0
fi

if [ "$MODE" = "bsp" ]; then
  yabai -m config --space "$SPACE_INDEX" layout stack >/dev/null 2>&1 || true
else
  yabai -m config --space "$SPACE_INDEX" layout bsp >/dev/null 2>&1 || true
fi

# No yabai signal fires for a layout change (config --space ... layout pushes none), so
# poke the LayerBar menu-bar app directly -- this flips it BSP <-> N/M and there is no
# other event to catch it. A Darwin notification: fire-and-forget, no focus, sub-ms.
/usr/bin/notifyutil -p com.mackhaymond.layerbar.refresh >/dev/null 2>&1 || true
