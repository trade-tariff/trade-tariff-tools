# How to update the EUR-Lex legal base links

This guide takes you through a full update, one step at a time. You don't need
to understand the code. Do the steps in order, and check each "You should see"
before you go on.

For background on why this exists, read [README.md](README.md).

## When to do this

- About once every three months.
- When someone reports a legal base link that is dead or opens the wrong law.
- When a reviewer asks for the file to be regenerated.

It takes about 1 to 2 hours. Most of that is waiting for downloads and the
browser check.

## What each file is for

Files you **edit by hand** (in this folder):

| File | What it holds | When you change it |
| --- | --- | --- |
| `wrong-celex.txt` | Decisions whose normal (CELEX) link opens the wrong law | Step 5 |
| `denylist.txt` | Legal bases whose citation link a person found dead or wrong | Step 9 |
| `README.md` | Background, and the "Last run" line at the end | Step 11 |

Files the scripts **make for you** (in this folder). Don't edit them, and don't
commit them (git ignores them):

| File | Made by |
| --- | --- |
| `derived-targets.json` | `derive-targets.mjs` (step 2) |
| `celex-results.json` | `check-celex.mjs` (step 3) |
| `audit-results.json` | `audit.mjs` (step 6) |
| `eur_lex_legal_base_links.csv` | `combine.mjs` (step 8) |

Files you **run but never edit**: `derive-targets.mjs`, `check-celex.mjs`,
`find-wrong-celex.mjs`, `audit.mjs`, `combine.mjs`. The rules they share live
in `rules.mjs`. Only change `rules.mjs` with a test in
`tests/eur-lex-legal-base-audit.test.js`.

The result goes into the backend as `db/eur_lex_legal_base_links.csv`. Always
replace that file with the generated one. Never edit it by hand.

## Before you start (first time only)

You need Node 20 or later, `psql`, Docker, and the backend checked out next to
this repo (`trade-tariff-backend` and `trade-tariff-tools` in the same folder).

From this folder, run:

```bash
npm ci
npx playwright install chromium
```

## Step 1: Load a recent production database

The audit only finds legal bases that are in your local database. Old data
means missing rows. Skip this step if you loaded a dump in the last week.

1. Ask the team for the production dump URL and login. **Never write them in
   this repo: it is public.**
2. Check the dump is a full one. It should be a few GB:

   ```bash
   curl -sI -u "$DUMP_USER:$DUMP_PASSWORD" "$DUMP_URL" | grep -i content-length
   ```

3. Stop everything that uses `tariff_development`: the backend, Sidekiq,
   and any Rails console. With the development stack, that is
   `docker stop backend-uk backend-xi worker-uk worker-xi`.
4. Replace the database. This deletes your local `tariff_development`:

   ```bash
   docker exec -i postgres psql -U postgres -c "DROP DATABASE tariff_development" -c "CREATE DATABASE tariff_development"
   curl -sS --fail -u "$DUMP_USER:$DUMP_PASSWORD" "$DUMP_URL" | gunzip | docker exec -i postgres psql -U postgres -q tariff_development
   ```

5. Start the things you stopped again.

**You should see:** the load finish after about 40 minutes with no `ERROR`
lines. `NOTICE` lines are fine.

## Step 2: List the legal bases

```bash
node derive-targets.mjs
```

**You should see:** one line like
`{"candidates":1020,"decisions":406,...}`. The number of candidates should be
about the same as the "Last run" in [README.md](README.md) or higher.

## Step 3: Ask Cellar which CELEX links exist

```bash
node check-celex.mjs
```

**You should see:** `Finished: {"303":208,"404":87}` or similar. If you see
`ERR` in the totals, run it again. It only re-checks the ones that failed.

## Step 4: Find decisions whose link may open the wrong law

```bash
node find-wrong-celex.mjs
```

This prints each suspect, for example:

```
D0000023 (in wrong-celex.txt)
  TARIC: OJ L 157 p. 10, published 2000-06-30
  Guess: 32000D0002, filed in oj:JOL_2000_001_R_0017_01
         2000/2/EC: Commission Decision ... imports of bovine animals ...
```

You only need to look at the suspects marked **`(NOT LISTED: review)`**.

## Step 5: Review each new suspect

Do this for each `NOT LISTED` id. In the commands below, replace `D0000023`
with the id.

1. Find out what TARIC says the law is:

   ```bash
   psql -h localhost -U postgres tariff_development -c "
     SELECT 'uk' AS service, information_text FROM uk.base_regulations WHERE base_regulation_id = 'D0000023'
     UNION ALL SELECT 'xi', information_text FROM xi.base_regulations WHERE base_regulation_id = 'D0000023'
     UNION ALL SELECT 'uk', information_text FROM uk.modification_regulations WHERE modification_regulation_id = 'D0000023'
     UNION ALL SELECT 'xi', information_text FROM xi.modification_regulations WHERE modification_regulation_id = 'D0000023'"
   ```

   For `D0000023` this says `Mexico - (chap. 1 - 24)`.

2. Compare it with the title printed under `Guess:` in step 4. That is the law
   the link opens today.
3. Decide:
   - **Different law** (for example, TARIC says Mexico and the title is about
     cattle): add a line to `wrong-celex.txt`. Say what the law really is and
     what the link opens instead:

     ```
     D0000023 # EC-Mexico Joint Council Decision 2/2000; guess is 2000/2/EC on bovine imports
     ```

   - **Same law** (the subject, country or number matches): add the id to the
     "Reviewed and left out" comment at the top of `wrong-celex.txt`, with the
     reason. This stops the next person from checking it again.
   - **Not sure:** leave it out and ask the team. Leaving it out keeps today's
     link.

Never remove a line from `wrong-celex.txt` unless you are sure the link now
opens the right law. Removing it brings the wrong link back.

## Step 6: Check the citation links in a browser

```bash
node audit.mjs
```

This opens each citation link in a hidden browser. It takes 10 to 25 minutes.
If it stops, run it again: it carries on where it stopped.

**You should see:** `Finished: {"audited":525,...,"totals":{"PASS":518,"SUSPECT":7},"stopped":null}`.

- If it says `belongs to a different target derivation`, delete
  `audit-results.json` and run it again. This happens when you re-ran step 2.
- If `stopped` is not `null`, EUR-Lex is blocking you. Wait an hour, then run
  it again.

## Step 7: Look at the SUSPECT results

```bash
node -e 'require("./audit-results.json").results.filter((r) => r.outcome === "SUSPECT").forEach((r) => console.log(r.rids.join(","), r.reason))'
```

A `SUSPECT` citation is never used, so you don't need to fix anything. Only act
if the reason is `rate-limit-or-challenge`: that means EUR-Lex blocked the
check. Wait, delete `audit-results.json`, and do step 6 again.

## Step 8: Make the new file

```bash
node combine.mjs
```

**You should see:** a line like
`576 rows: 526 citations {...}, 50 blank`.

## Step 9: Check every row that changed

Compare the new file with the one in the backend:

```bash
diff ../../../trade-tariff-backend/db/eur_lex_legal_base_links.csv eur_lex_legal_base_links.csv
```

- **No output:** nothing changed. You can stop here.
- **Lines starting with `>`** are new or changed. For each one with a citation,
  open this link in your browser, with the citation at the end:
  `https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=uriserv%3A` +
  the citation (for example `OJ.L_.2000.157.01.0010.01.ENG`).
  Check the page is the law TARIC describes (see step 5.1).
  If the page is dead or shows a different law, add the id to `denylist.txt`
  with the reason, then do step 8 again.
- **Lines starting with `<`** were removed. This usually means no live or
  future measure uses that legal base now. That's fine.

## Step 10: Put the file in the backend

```bash
cp eur_lex_legal_base_links.csv ../../../trade-tariff-backend/db/
cd ../../../trade-tariff-backend
bundle exec rspec spec/services/measure_service
```

**You should see:** `0 failures`. If a test fails because a link changed, only
update the test if you checked that link in step 9.

## Step 11: Record the run and open the pull requests

1. In [README.md](README.md), update the "Last run" line with today's date,
   the dump date, and the counts from steps 2 and 8.
2. Open a pull request in **trade-tariff-tools** with your changes to
   `wrong-celex.txt`, `denylist.txt` and `README.md`.
3. Open a pull request in **trade-tariff-backend** with the new
   `db/eur_lex_legal_base_links.csv`. In the description, list the rows that
   changed and why, and link the tools pull request.

## If something goes wrong

| Message | What to do |
| --- | --- |
| `psql: ... Connection refused` | Start the database: `docker start postgres` |
| `No Cellar result for D... run check-celex.mjs first` | Run step 3 again, then step 8 |
| `audit-results.json is incomplete; finish audit.mjs first` | Run step 6 again |
| `belongs to a different target derivation` | Delete `audit-results.json`, then run step 6 |
| `Cellar SPARQL returned 5xx` | Cellar is busy. Wait a few minutes and run step 4 again |
