#!/bin/bash
# Compact table of the matrix results.
L=/private/tmp/claude-501/-Users-morningman-workspace-git-sirius/06f00ebc-b875-47cb-a533-864dfe5db728/scratchpad/exp/matrix.log
awk '
/^### /   { if (hdr != "") flush(); hdr=$0; sub(/^### /,"",hdr); plugin=""; same=""; probe=""; res="" }
/plugin: pb=/ { sub(/^ *plugin: /,""); plugin=$0 }
/same_pool=/ { sub(/^ */,""); same=$0 }
/stdlib_probe:/ { sub(/^ *stdlib_probe: /,""); probe=$0 }
/RESULT:/ { sub(/^ *RESULT: /,""); res=$0 }
function flush() { printf "%-62s | %s\n", hdr, res; if (same!="") printf "%-62s |   %s\n", "", same; if (plugin!="") printf "%-62s |   %s\n", "", substr(plugin,1,110); if (probe!="") printf "%-62s |   probe: %s\n", "", substr(probe,1,90) }
END { flush() }' "$L"
