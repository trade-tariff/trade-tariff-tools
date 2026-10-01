// The EU changed its Official Journal numbering on this date. Citation links
// only resolve for documents published before it.
export const CITATION_CUTOFF_DATE = '2023-10-01';

// Mirrors MeasureService::CouncilRegulationUrlGenerator in trade-tariff-backend:
// "3" (CELEX sector 3) + year + TARIC type letter + number.
export function celexGuess(rid) {
  const year = rid.slice(1, 3);
  const century = Number.parseInt(year, 10) > 70 ? '19' : '20';
  return `3${century}${year}${rid[0]}${rid.slice(3, 7)}`;
}

export function ojCitation({ officialjournal_number: number, officialjournal_page: page, published_date: publishedDate }) {
  const match = String(number ?? '').trim().match(/^([LC])\s*(\d+)$/i);
  const pageNumber = Number.parseInt(page, 10) || 0;
  if (!match || pageNumber <= 0 || !publishedDate || publishedDate >= CITATION_CUTOFF_DATE) return null;

  const series = match[1].toUpperCase();
  const issue = String(Number.parseInt(match[2], 10)).padStart(3, '0');
  return `OJ.${series}_.${publishedDate.slice(0, 4)}.${issue}.01.${String(pageNumber).padStart(4, '0')}.01.ENG`;
}

// buildLinks never uses the citation of a decision whose CELEX link works, so
// the browser only needs to check a citation if another legal base uses it.
// A decision in wrong-celex.txt counts as broken: its CELEX link opens another act.
export function needsBrowserCheck({ rids }, celexStatus, wrongCelex = new Set()) {
  return rids.some((rid) => !rid.startsWith('D') || celexStatus[celexGuess(rid)] !== 303 || wrongCelex.has(rid));
}

// True when Cellar files the act behind a CELEX guess in a different OJ issue
// from the one TARIC cites, so the guess probably opens a different act.
// Only pre-2023 Cellar OJ ids (oj:JO{L|C}_YYYY_NNN_...) can be compared. Their
// last part is a page before 2013 and a sequence number after, so pages are
// ignored. find-wrong-celex.mjs lists these for a person to review.
export function ojIssueMismatch({ officialjournal_number: number, published_date: publishedDate }, cellarOjIds) {
  const taric = String(number ?? '').trim().match(/^([LC])\s*(\d+)$/i);
  const cellar = cellarOjIds.map((id) => id.match(/^oj:JO([LC])_(\d{4})_(\d+)_/)).filter(Boolean);
  if (!taric || !publishedDate || cellar.length === 0) return false;

  return !cellar.some(([, series, year, issue]) => series === taric[1].toUpperCase()
    && year === publishedDate.slice(0, 4)
    && Number(issue) === Number(taric[2]));
}

// Reads denylist.txt and wrong-celex.txt: one id per line, # starts a comment.
export function parseIdList(text) {
  return new Set(text
    .split('\n')
    .map((line) => line.replace(/#.*/, '').trim())
    .filter(Boolean));
}

// Rows for trade-tariff-backend db/eur_lex_legal_base_links.csv. Only legal
// bases whose CELEX formula link is broken are listed, so working links never
// change. A CELEX link is broken when Cellar doesn't have the guess (404), or
// when the decision is in wrong-celex.txt because the guess opens another act.
// - a browser-verified, non-denylisted citation for any A/C/I/J id, and for a
//   D id whose CELEX link is broken
// - a blank citation (no link) for any other D id whose CELEX link is broken
// Everything else is left out: the backend keeps the CELEX link for D and
// shows no link for A/C/I/J.
export function buildLinks({ candidates, browserPass, denylist, celexStatus, wrongCelex = new Set() }) {
  const links = new Map();

  for (const { rid, celex } of candidates) {
    const decision = rid.startsWith('D');
    const status = celexStatus[celex];
    if (decision && status !== 303 && status !== 404) {
      throw new Error(`No Cellar result for ${rid} (${celex}); run check-celex.mjs first`);
    }

    const celexDead = !decision || status === 404 || wrongCelex.has(rid);
    const citation = denylist.has(rid) ? null : browserPass.get(rid);
    if (celexDead && citation) {
      links.set(rid, citation);
    } else if (decision && celexDead) {
      links.set(rid, null);
    }
  }

  return [...links]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([rid, citation]) => ({ regulation_id: rid, oj_citation: citation }));
}

export function toCsv(rows) {
  const lines = rows.map(({ regulation_id: rid, oj_citation: citation }) => `${rid},${citation ?? ''}`);
  return `${['regulation_id,oj_citation', ...lines].join('\n')}\n`;
}
