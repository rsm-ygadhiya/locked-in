# The access-rule tests

The whole proctoring design rests on one claim:

> A student in full control of their own laptop, holding the anon key that ships inside
> the app, still cannot admit themselves to an exam or see anyone else's data.

That claim is not enforced by the app asking nicely. It is enforced by Postgres
row-level security policies and one trigger, all of them in
[`../schema.sql`](../schema.sql). This directory tries to break it, eleven ways, and
expects to fail every time.

```bash
brew install postgresql@16 && brew services start postgresql@16
./server/tests/run_tests.sh
```

It creates a throwaway local database, stubs the parts of Supabase that the schema
builds on, applies `schema.sql` to it three times over (running it twice must be safe,
so that is tested too), and runs the attacks inside a transaction that is rolled back.
**It never touches your Supabase project**, and needs no keys.

| | The attack | Blocked by |
| --- | --- | --- |
| 1 | Insert a session that is already `approved` | the status trigger |
| 2 | Approve my own pending session | the status trigger |
| 3 | Promote myself to `faculty` | the profiles update policy |
| 4 | Forge `decided_by` / `decided_at` on my own row | column-level reset — the write is allowed and silently discarded |
| 5 | Read another student's session | the sessions select policy |
| 6 | Walk a session backwards from `active` to `approved` | the status trigger |
| 7 | Upload into another student's storage folder | the storage object policy |
| 8 | Read another student's frames and storage objects | the frames and storage select policies |
| 9 | Heartbeat a session that was refused | the status trigger |
| 10 | Read another student's kept frames | the snapshots select policy |
| 11 | Delete a frame kept of you | no student delete policy — the delete removes nothing |

Six are refused outright with an error. Five — 4, 5, 8, 10 and 11 — are *allowed to
run* and must have no effect, which is the more interesting failure mode: a forged write that is
quietly discarded, and two reads that come back empty rather than erroring. A test that
only counted errors would pass while leaking every one of them, so `run_tests.sh` checks
those three by their results.

It also checks the other direction, which is just as easy to break. Four legitimate
actions must still succeed: a proctor creating an exam, a student joining as `pending`,
that student publishing a frame and an event for their own session, and that student
uploading under their own session id. Plus the proctor's approval stamping
`decided_by` and `decided_at`, and the signup trigger creating a profile row. A policy
that blocks everything is not a passing test.

**Reading the output.** Each `### ATTACK` line must be followed by an `ERROR`, except
for 4, 5 and 8. A silent attack is a failing test, and the script fails loudly if the
counts move — including if someone adds a tenth attack without updating them.
