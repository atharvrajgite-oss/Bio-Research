const fs = require("fs");
const p = require("path").join(__dirname, "frontend", "components", "TraceFeed.tsx");
const s = fs.readFileSync(p, "utf8");
const t = s.replace(
  /\{step\.graph\.links\?\.length\s*\?\?\s*0\}/g,
  "{step.graph.links?.length ?? 0}"
);
if (t === s) { console.log("NO CHANGE"); process.exit(0); }
fs.writeFileSync(p, t);
console.log("OK");
