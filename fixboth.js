const fs = require("fs");
const path = require("path");

function patchfile(p, edits) {
  let s = fs.readFileSync(p, "utf8");
  for (const [old, nw] of edits) {
    if (!old) continue;
    let count = 0;
    s = s.replaceAll(old, () => { count++; return nw; });
    if (count === 0) console.log(`WARN no match in ${path.basename(p)}: ${old.substring(0,60)}`);
  }
  fs.writeFileSync(p, s);
}

// AnswerPanel: replace unknown/{} react node / key types with explicit casts
patchfile(
  path.join(__dirname, "frontend", "components", "AnswerPanel.tsx"),
  [
    // array-of-unknown map keys and react node spots
    // item.label was {} / unknown
    ["key={item.label}", "key={String(item.label)}"],
    ["key={h.id}", "key={String(h.id)}"],
    ["key={g.gene_id}", "key={String(g.gene_id)}"],
    // disease module community_id key
    ["key={c.community_id}", "key={String(c.community_id)}"],
    // t.protein_id already String() cast earlier; ensure the key spot is safe (it was)
    // tools_used map key t was unknown
    ["key={`${t}-${i}`}", "key={`${String(t)}-${i}`}"],
    // caveats list c as {} text node
    ["<span>{c}</span>", "<span>{c as string}</span>"],
    // shared_genes slice member_names optional text rendering (safe if nodes)
    // literature evidence lines: polarity badge type {} -> cast
    // (polarity is already typed; no change unless TS still flags)
  ]
);

// TraceFeed: coerce step.graph.links?.length ?? 0 in two spots to number|undefined
patchfile(
  path.join(__dirname, "frontend", "components", "TraceFeed.tsx"),
  [
    // In the graph stats span text node — the ?? 0 yields number| null|undefined on NullableArray
    ["{step.graph.nodes.length} nodes / {step.graph.links?.length ?? 0}",
     "{step.graph.nodes.length} nodes / {(step.graph.links?.length ?? 0) as number | undefined}"],
    // if there is another occurrence (e.g. inside a JSX attribute) catch it too
    ["nodes / {step.graph.links?.length ?? 0}", "nodes / {(step.graph.links?.length ?? 0) as number | undefined}"],
  ]
);

console.log("done");
