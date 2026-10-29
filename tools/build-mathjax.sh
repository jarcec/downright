#!/bin/bash
# Rebuild Sources/DownrightEditor/Resources/mathjax-tex-svg.js: MathJax's TeX input and
# SVG output (glyphs as paths, no fonts) bundled into one script that runs in
# JavaScriptCore, with no DOM and no network. Needs node and npm.
#
#   tools/build-mathjax.sh [version]     (default 3.2.2)
set -euo pipefail
VERSION="${1:-3.2.2}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t downright-mathjax)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
npm init -y >/dev/null
npm install --silent --cache "$WORK/.npm" "mathjax-full@$VERSION" esbuild@0.24.0
cat > entry.js <<'JS'
import {mathjax} from 'mathjax-full/js/mathjax.js';
import {TeX} from 'mathjax-full/js/input/tex.js';
import {SVG} from 'mathjax-full/js/output/svg.js';
import {liteAdaptor} from 'mathjax-full/js/adaptors/liteAdaptor.js';
import {RegisterHTMLHandler} from 'mathjax-full/js/handlers/html.js';
import {AllPackages} from 'mathjax-full/js/input/tex/AllPackages.js';

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
// Every package that works offline: nothing loads at run time.
const packages = AllPackages.filter(p => !['autoload', 'require', 'bussproofs'].includes(p));
const tex = new TeX({packages, formatError: (jax, err) => { throw err; }});
const svg = new SVG({fontCache: 'none'});
const html = mathjax.document('', {InputJax: tex, OutputJax: svg});

// TeX to a standalone <svg>: {svg} or {error} with TeX's message.
globalThis.texToSVG = function (source, display) {
  try {
    const node = html.convert(source, {display});
    return {svg: adaptor.outerHTML(adaptor.firstChild(node))};
  } catch (e) {
    return {error: String(e && e.message || e)};
  }
};
JS
npx esbuild entry.js --bundle --minify --format=iife --platform=neutral --main-fields=module,main \
  --outfile="$REPO/Sources/DownrightEditor/Resources/mathjax-tex-svg.js" --log-level=warning
cp node_modules/mathjax-full/LICENSE "$REPO/Sources/DownrightEditor/Resources/mathjax-LICENSE.txt"
echo "Built MathJax $VERSION into Sources/DownrightEditor/Resources/mathjax-tex-svg.js"
