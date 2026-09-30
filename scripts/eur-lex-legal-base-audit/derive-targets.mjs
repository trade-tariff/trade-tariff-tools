// Step 1: list every non-regulation legal base (D/A/J/C/I) behind a live or
// future-dated UK or XI measure, with its CELEX guess and OJ citation, and the
// citation URLs for audit.mjs to open in a browser. Writes derived-targets.json.
import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { CITATION_CUTOFF_DATE, celexGuess, ojCitation } from './rules.mjs';

const eurLexBase = 'https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=';
const database = process.env.AUDIT_DB_NAME ?? 'tariff_development';

const regulations = (schema, kind) => `
  SELECT '${schema}' AS service, ${kind}_regulation_id AS rid, ${kind}_regulation_role AS role,
         published_date, officialjournal_number, officialjournal_page
  FROM ${schema}.${kind}_regulations`;

// Future-dated measures are included so their legal bases are already in the
// backend file when they go live, instead of waiting for the next run.
const liveOrFutureMeasures = (schema) => `
  SELECT DISTINCT '${schema}' AS service, measure_generating_regulation_id AS rid, measure_generating_regulation_role AS role
  FROM ${schema}.measures
  WHERE validity_end_date IS NULL OR validity_end_date >= CURRENT_DATE`;

// UK national regulations (OJ number '1', page 1) are out of scope: the
// backend links them to legislation.gov.uk, not EUR-Lex.
const sql = `
SELECT coalesce(json_agg(row_to_json(candidates) ORDER BY rid, service), '[]')
FROM (
  SELECT DISTINCT regulations.*
  FROM (${regulations('uk', 'base')} UNION ALL ${regulations('uk', 'modification')}
        UNION ALL ${regulations('xi', 'base')} UNION ALL ${regulations('xi', 'modification')}) regulations
  JOIN (${liveOrFutureMeasures('uk')} UNION ${liveOrFutureMeasures('xi')}) measures USING (service, rid, role)
  WHERE left(rid, 1) IN ('D', 'A', 'J', 'C', 'I')
    AND NOT (coalesce(officialjournal_number, '') = '1' AND coalesce(officialjournal_page, 0) = 1)
) candidates;
`;

const rows = JSON.parse(execFileSync(
  'psql',
  ['-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-U', process.env.AUDIT_DB_USER ?? 'postgres', '-h', process.env.AUDIT_DB_HOST ?? 'localhost', '-d', database, '-c', sql],
  {
    encoding: 'utf8',
    env: { ...process.env, PGOPTIONS: '-c default_transaction_read_only=on' },
    maxBuffer: 50 * 1024 * 1024,
  },
));

// The same legal base can appear in both services with cosmetic differences
// (e.g. "C  62" vs "C 62"). Merge by id; if the variants give different
// citations, drop the citation so the id can only get a blank row or nothing.
const byRid = new Map();
for (const row of rows) {
  const citation = ojCitation(row);
  const existing = byRid.get(row.rid);
  if (existing) {
    existing.services = [...new Set([...existing.services, row.service])];
    if (existing.citation !== citation) {
      process.stderr.write(`Conflicting citations for ${row.rid}: ${existing.citation} vs ${citation}; dropping\n`);
      existing.citation = null;
    }
  } else {
    byRid.set(row.rid, {
      rid: row.rid,
      services: [row.service],
      published_date: row.published_date,
      officialjournal_number: row.officialjournal_number,
      officialjournal_page: row.officialjournal_page,
      celex: celexGuess(row.rid),
      citation,
    });
  }
}
const candidates = [...byRid.values()];

// audit.mjs judges a page by the OJ reference it displays, so it needs the
// expected series, issue, year and first page for each citation URL.
const ridsByCitation = new Map();
for (const { rid, citation } of candidates) {
  if (citation) ridsByCitation.set(citation, [...(ridsByCitation.get(citation) ?? []), rid]);
}
const targets = [...ridsByCitation]
  .map(([citation, rids]) => {
    const [, series, year, number, page] = citation.match(/^OJ\.([LC])_\.(\d{4})\.(\d{3})\.01\.(\d{4})\.01\.ENG$/);
    return {
      url: `${eurLexBase}uriserv%3A${citation}`,
      rids: rids.sort(),
      expected: { series, number: Number(number), year: Number(year), page: Number(page) },
    };
  })
  .sort((left, right) => left.url.localeCompare(right.url));

const output = {
  provenance: {
    commit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    database,
    schemas: ['uk', 'xi'],
    generated_at: new Date().toISOString(),
    cutoff_date: CITATION_CUTOFF_DATE,
  },
  counts: {
    candidates: candidates.length,
    decisions: candidates.filter(({ rid }) => rid.startsWith('D')).length,
    with_citation: candidates.filter(({ citation }) => citation).length,
    targets: targets.length,
  },
  candidates,
  targets,
};

writeFileSync(new URL('./derived-targets.json', import.meta.url), `${JSON.stringify(output, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(output.counts)}\n`);
