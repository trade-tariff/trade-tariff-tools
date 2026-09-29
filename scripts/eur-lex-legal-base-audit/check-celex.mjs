// Step 2: ask the EU Cellar API whether each decision's (D) CELEX guess
// exists. 303 means it exists (the backend's CELEX link works); 404 means it
// doesn't. Only D ids are checked: A/C/I/J guesses never exist (0 of 620 in
// the 2026-09 audit). Writes celex-results.json and resumes from it.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

const outputUrl = new URL('./celex-results.json', import.meta.url);
const { candidates } = JSON.parse(readFileSync(new URL('./derived-targets.json', import.meta.url), 'utf8'));
const results = existsSync(outputUrl) ? JSON.parse(readFileSync(outputUrl, 'utf8')) : {};

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function cellarStatus(celex) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      const response = await fetch(`https://publications.europa.eu/resource/celex/${encodeURIComponent(celex)}`, {
        headers: { Accept: 'application/rdf+xml' },
        redirect: 'manual',
        signal: AbortSignal.timeout(30_000),
      });
      await response.body?.cancel();
      if (response.status < 500) return response.status;
      if (attempt >= 3) return response.status;
    } catch (error) {
      if (attempt >= 3) return `ERR ${error.message.slice(0, 40)}`;
    }
    await sleep(2_000 * attempt);
  }
}

const todo = [...new Set(candidates.filter(({ rid }) => rid.startsWith('D')).map(({ celex }) => celex))]
  .filter((celex) => results[celex] !== 303 && results[celex] !== 404);
process.stdout.write(`${todo.length} CELEX ids to check\n`);

let done = 0;
const worker = async () => {
  for (let celex = todo.shift(); celex; celex = todo.shift()) {
    results[celex] = await cellarStatus(celex);
    done += 1;
    if (done % 50 === 0) {
      writeFileSync(outputUrl, `${JSON.stringify(results, null, 2)}\n`);
      process.stdout.write(`  ${done} checked\n`);
    }
    await sleep(200);
  }
};
await Promise.all(Array.from({ length: 4 }, worker));
writeFileSync(outputUrl, `${JSON.stringify(results, null, 2)}\n`);

const totals = Object.values(results).reduce((summary, status) => ({ ...summary, [status]: (summary[status] ?? 0) + 1 }), {});
process.stdout.write(`Finished: ${JSON.stringify(totals)}\n`);
