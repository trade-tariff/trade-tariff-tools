// Step 4: combine the browser audit, the denylist, the wrong-CELEX list and the
// Cellar results into eur_lex_legal_base_links.csv for trade-tariff-backend's
// db/ directory.
import { readFileSync, writeFileSync } from 'node:fs';
import { buildLinks, parseIdList, toCsv } from './rules.mjs';

const read = (name) => readFileSync(new URL(`./${name}`, import.meta.url), 'utf8');

const { candidates } = JSON.parse(read('derived-targets.json'));
const celexStatus = JSON.parse(read('celex-results.json'));
const audit = JSON.parse(read('audit-results.json'));
if (!audit.completed_at) {
  throw new Error('audit-results.json is incomplete; finish audit.mjs first');
}

// A PASS means the browser opened the citation URL and found the expected OJ
// reference on the page. Link by exactly the citation it opened.
const browserPass = new Map();
for (const { url, rids, outcome } of audit.results) {
  if (outcome !== 'PASS') continue;
  const citation = decodeURIComponent(url).split('uriserv:')[1];
  for (const rid of rids) browserPass.set(rid, citation);
}

const denylist = parseIdList(read('denylist.txt'));
const wrongCelex = parseIdList(read('wrong-celex.txt'));

const links = buildLinks({ candidates, browserPass, denylist, celexStatus, wrongCelex });
writeFileSync(new URL('./eur_lex_legal_base_links.csv', import.meta.url), toCsv(links));

const citations = links.filter(({ oj_citation: citation }) => citation);
const byPrefix = citations.reduce((summary, { regulation_id: rid }) => ({ ...summary, [rid[0]]: (summary[rid[0]] ?? 0) + 1 }), {});
process.stdout.write(`${links.length} rows: ${citations.length} citations ${JSON.stringify(byPrefix)}, ${links.length - citations.length} blank\n`);
