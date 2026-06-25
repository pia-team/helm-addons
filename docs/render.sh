#!/usr/bin/env bash
# Render the multi-dimensional-autoscaling whitepaper + presentation (Markdown with Mermaid)
# into shareable PDF/PPTX under docs/exports/.
#
# Requires: node/npx, pandoc, and Google Chrome.
#   - whitepaper: mermaid -> SVG (mmdc) -> standalone HTML (pandoc, embedded) -> PDF (Chrome)
#   - presentation: mermaid -> SVG (per block, preserving Marp directives) -> PDF + PPTX (Marp + Chrome)
# Override the browser with:  CHROME_BIN=/path/to/chrome bash docs/render.sh
set +e
cd "$(dirname "$0")" || exit 1   # docs/
CHROME="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
export PUPPETEER_EXECUTABLE_PATH="$CHROME"; export CHROME_PATH="$CHROME"
echo '{"args":["--no-sandbox","--disable-gpu"]}' > /tmp/pptr.json
mkdir -p exports

WP=whitepaper-multidimensional-autoscaling
DECK=presentation-multidimensional-autoscaling

echo "### Whitepaper -> PDF"
npx -y @mermaid-js/mermaid-cli@latest -p /tmp/pptr.json -i "$WP.md" -o wp.rendered.md
pandoc wp.rendered.md -o wp.html --standalone --embed-resources \
  --metadata title="Grow Up, Then Out — Multi-Dimensional Autoscaling"
"$CHROME" --headless=new --no-sandbox --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="$PWD/exports/$WP.pdf" "file://$PWD/wp.html"

echo "### Presentation -> PDF + PPTX (Mermaid pre-rendered, Marp directives preserved)"
python3 - <<'PY'
import re, subprocess
src = open("presentation-multidimensional-autoscaling.md").read()
n = 0
def repl(m):
    global n; n += 1
    open(f"/tmp/deck{n}.mmd","w").write(m.group(1))
    subprocess.run(["npx","-y","@mermaid-js/mermaid-cli@latest","-p","/tmp/pptr.json",
                    "-i",f"/tmp/deck{n}.mmd","-o",f"deck-diagram-{n}.svg"], check=False)
    return f"![w:820](deck-diagram-{n}.svg)"
open("deck.rendered.md","w").write(re.sub(r"```mermaid\n(.*?)```", repl, src, flags=re.S))
PY
npx -y @marp-team/marp-cli@latest deck.rendered.md --pdf  --allow-local-files -o "exports/$DECK.pdf"
npx -y @marp-team/marp-cli@latest deck.rendered.md --pptx --allow-local-files -o "exports/$DECK.pptx"

echo "### Cleanup scaffolding"
rm -f wp.rendered.md wp.rendered-*.svg wp.html deck.rendered.md deck-diagram-*.svg
echo "### Done -> docs/exports/"; ls -lh exports/ | awk 'NR>1{print $5"\t"$NF}'
