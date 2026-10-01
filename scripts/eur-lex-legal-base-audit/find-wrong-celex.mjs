// Step 2b: list decisions whose CELEX guess probably opens a different act.
// Cellar has the guess (303), but files it in a different OJ issue from the
// one TARIC cites. A person checks each suspect and adds the confirmed ones to
// wrong-celex.txt with the reason. This script never changes a link itself.
import { readFileSync } from 'node:fs';
import { ojIssueMismatch, parseIdList } from './rules.mjs';

const read = (name) => readFileSync(new URL(`./${name}`, import.meta.url), 'utf8');
const { candidates } = JSON.parse(read('derived-targets.json'));
const celexStatus = JSON.parse(read('celex-results.json'));
const wrongCelex = parseIdList(read('wrong-celex.txt'));

const working = candidates.filter(({ rid, celex }) => rid.startsWith('D') && celexStatus[celex] === 303);
const celexIds = [...new Set(working.map(({ celex }) => celex))];

const query = `PREFIX cdm: <http://publications.europa.eu/ontology/cdm#>
SELECT ?celex ?oj ?title WHERE {
  VALUES ?celex { ${celexIds.map((celex) => `"${celex}"^^<http://www.w3.org/2001/XMLSchema#string>`).join(' ')} }
  ?work cdm:resource_legal_id_celex ?celex .
  OPTIONAL { ?work cdm:work_id_document ?oj . FILTER(STRSTARTS(STR(?oj), "oj:")) }
  OPTIONAL {
    ?expression cdm:expression_belongs_to_work ?work ;
      cdm:expression_title ?title ;
      cdm:expression_uses_language <http://publications.europa.eu/resource/authority/language/ENG> .
  }
}`;

// POST, because a GET with this many ids is too long for Cellar (HTTP 414)
const response = await fetch('https://publications.europa.eu/webapi/rdf/sparql', {
  method: 'POST',
  headers: { Accept: 'application/sparql-results+json' },
  body: new URLSearchParams({ query }),
  signal: AbortSignal.timeout(120_000),
});
if (!response.ok) throw new Error(`Cellar SPARQL returned ${response.status}`);

const cellar = new Map();
for (const { celex, oj, title } of (await response.json()).results.bindings) {
  const entry = cellar.get(celex.value) ?? { ojIds: new Set(), title: null };
  if (oj) entry.ojIds.add(oj.value);
  entry.title ??= title?.value ?? null;
  cellar.set(celex.value, entry);
}

const suspects = working.filter(({ celex, ...candidate }) => ojIssueMismatch(candidate, [...(cellar.get(celex)?.ojIds ?? [])]));
for (const { rid, celex, officialjournal_number: number, officialjournal_page: page, published_date: publishedDate } of suspects) {
  const { ojIds, title } = cellar.get(celex);
  process.stdout.write(`${rid} ${wrongCelex.has(rid) ? '(in wrong-celex.txt)' : '(NOT LISTED: review)'}
  TARIC: OJ ${number} p. ${page}, published ${publishedDate}
  Guess: ${celex}, filed in ${[...ojIds].join(', ')}
         ${title?.slice(0, 160) ?? '(no English title)'}
`);
}
process.stdout.write(`${suspects.length} suspects among ${working.length} decisions with a working CELEX link\n`);
