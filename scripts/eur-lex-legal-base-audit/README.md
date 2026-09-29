# EUR-Lex legal base audit

Builds `db/eur_lex_legal_base_links.csv` for
[trade-tariff-backend](https://github.com/trade-tariff/trade-tariff-backend).
The backend's `MeasureService::CouncilRegulationUrlGenerator` reads that file
to decide how to link each measure's legal base to EUR-Lex, the EU law website.
The backend change that added the file is
[trade-tariff-backend#3819](https://github.com/trade-tariff/trade-tariff-backend/pull/3819).

## Why this exists

The backend guesses a EUR-Lex document id (a CELEX number) from the TARIC
regulation id: `"3" + year + type letter + number`. The leading `3` means
"sector 3", where EUR-Lex files ordinary regulations. The guess works for
regulations (R) and for many decisions (D). It does not work for acts EUR-Lex
files in other sectors: some decisions, and every agreement (A), notice (C),
Joint Committee act (J) and TARIC notice (I). Those links go to a 404 page.

For most of those acts, a link by Official Journal (OJ) citation works
instead, for example
`https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=uriserv%3AOJ.L_.1996.035.01.0001.01.ENG`.
But EUR-Lex's citation index has gaps, so each citation must be checked before
the backend uses it.

The file only lists legal bases whose CELEX link is dead. A legal base with a
working link is never listed, so a new run can't break a link that works.

| In the file? | Type | The backend shows |
| --- | --- | --- |
| Yes, with a citation | any | a link by that citation |
| Yes, with a blank citation | D | no link |
| No | D, R and others | the CELEX link, as before |
| No | A, C, I, J | no link |

UK national regulations (OJ number `1`, page `1`) are out of scope. The
backend links them to legislation.gov.uk.

## The steps

1. **`derive-targets.mjs`** lists every D, A, J, C and I legal base behind a
   live UK or XI measure. For each one it works out the backend's CELEX guess
   and, where the OJ data allows, the OJ citation. Citations only work for
   documents published before 1 October 2023, when the EU changed its OJ
   numbering. Writes `derived-targets.json`.
2. **`check-celex.mjs`** asks the EU Cellar API whether each decision's CELEX
   guess exists (`303` = exists, `404` = doesn't). Cellar is the EU's
   machine-readable store behind EUR-Lex, and it's reliable for CELEX ids.
   Only decisions are checked, because the guess never exists for A, C, I or J
   (0 of 620 in the 2026-09 audit). Writes `celex-results.json`.
3. **`audit.mjs`** opens every citation URL in a headless browser and checks
   the page shows the expected OJ reference (series, issue, year and first
   page). A browser is needed because EUR-Lex blocks plain HTTP clients, and
   Cellar can't be used for citations: in the 2026-09 audit it missed 281 of
   753 citations a browser confirmed, including almost all after 2013. It
   skips citations used only by decisions whose CELEX link works, because
   those citations are never used (169 of 686 URLs in the 2026-09 audit).
   Takes about 1 second per URL and resumes if stopped. Writes
   `audit-results.json` with `PASS` or `SUSPECT` for each URL.
4. **Check by hand.** Open a sample of `PASS` URLs, and any that look odd. If
   a citation page is dead or opens a different law, add the id to
   `denylist.txt` with the reason. `SUSPECT` results are never used, so those
   ids get no link (A, C, I, J) or keep their CELEX link or a blank row (D).
5. **`combine.mjs`** writes `eur_lex_legal_base_links.csv`:
   - a citation row for each `PASS` id that isn't denylisted, where the id is
     A, C, I or J, or is a D whose CELEX guess is a Cellar `404`
   - a blank row for each other D whose CELEX guess is a Cellar `404`

   The rules live in `rules.mjs` and are tested by
   `tests/eur-lex-legal-base-audit.test.js`.
6. **Copy** `eur_lex_legal_base_links.csv` to the backend's `db/` directory,
   run `bundle exec rspec spec/services/measure_service`, and update the
   "last run" date in `council_regulation_url_generator.rb`.

## How to run

You need Node 20 or later, `psql`, and a local tariff database with the `uk`
and `xi` schemas loaded. The defaults are database `tariff_development`, host
`localhost` and user `postgres`. Override them with `AUDIT_DB_NAME`,
`AUDIT_DB_HOST` and `AUDIT_DB_USER`.

From this directory:

```bash
npm install
npx playwright install chromium
node derive-targets.mjs
node check-celex.mjs
node audit.mjs
# check by hand and update denylist.txt
node combine.mjs
```

## When to re-run

Re-run when TARIC data starts using legal bases published before
1 October 2023 that aren't in the backend file. Until then, a new A, C, I or J
legal base gets no link, and a new D keeps its CELEX guess, which may be dead.
The candidate list is historical and rarely changes, so a quarterly check is
plenty.

## History

- Gabriel's browser harness was written for HMRC-2159
  ([trade-tariff-backend#3667](https://github.com/trade-tariff/trade-tariff-backend/pull/3667)).
- HMRC-2663 moved it here and added both services, lowercase OJ series,
  the Cellar check, the denylist and the combine step. The first data file
  it made shipped in
  [trade-tariff-backend#3819](https://github.com/trade-tariff/trade-tariff-backend/pull/3819).
- Last run: 2026-09-28. 1,011 live legal bases gave 563 rows: 515 citations
  (D 41, I 468, A 1, J 5) and 48 blank decisions.
