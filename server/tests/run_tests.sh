#!/bin/bash
#
# run_tests.sh — check schema.sql against a real Postgres, then try to break it.
#
# Creates a throwaway database, stubs the parts of Supabase that schema.sql builds
# on, runs the schema three times (so idempotency is covered too), then runs the
# access-rule tests. Drops the database at the end.
#
# Needs a local Postgres you can create databases on:
#     brew install postgresql@16 && brew services start postgresql@16
#
# Usage:
#     ./run_tests.sh          run everything
#     ./run_tests.sh --keep   leave the database behind for poking at
#
# It never touches a Supabase project. The stub deliberately collides with the real
# auth and storage schemas, so it can only be used locally.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD="$(dirname "$HERE")"
DB="lockedin_schema_test"
KEEP=false
[[ "${1:-}" == "--keep" ]] && KEEP=true

fail() { printf '\n\033[31mFAILED: %s\033[0m\n' "$1"; exit 1; }
step() { printf '\n\033[32m==>\033[0m %s\n' "$1"; }

command -v psql >/dev/null || fail "psql not found. brew install postgresql@16"
pg_isready -q || fail "no Postgres is accepting connections. brew services start postgresql@16"

step "creating a throwaway database: $DB"
dropdb --if-exists "$DB" >/dev/null 2>&1
createdb "$DB" || fail "could not create $DB"

cleanup() { [[ "$KEEP" == true ]] || dropdb --if-exists "$DB" >/dev/null 2>&1; }
trap cleanup EXIT

step "stubbing auth + storage"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$HERE/supabase_stub.sql" \
	|| fail "the stub did not apply"

# Three times, because the schema promises to be re-runnable and a broken drop/create
# pair only shows up on the second pass.
for pass in 1 2 3; do
	step "applying schema.sql (pass $pass of 3)"
	psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$CLOUD/schema.sql" 2>&1 \
		| grep -v "does not exist, skipping" \
		| grep -i "error" && fail "schema.sql failed on pass $pass"
done

step "counting what was built"
psql -qtA -d "$DB" -c "
select 'tables:   ' || count(*) from pg_tables where schemaname = 'public'
union all
select 'policies: ' || count(*) from pg_policies where schemaname in ('public','storage')
union all
select 'triggers: ' || count(*) from pg_trigger where not tgisinternal;"

step "running the access-rule tests"
OUTPUT="$(psql -qtA -d "$DB" -f "$HERE/rls_test.sql" 2>&1)"
echo "$OUTPUT"

# Counting beats eyeballing the log: a policy that quietly stops rejecting is exactly
# the kind of regression that still reads as success.
#
# The thirteen attacks are blocked in two different ways, and both have to be checked:
#   * seven are refused outright, and must raise an error (1, 2, 3, 6, 7, 9, 13)
#   * six are allowed to run but must have no effect      (4, 5, 8, 10, 11, 12) — forged
#     writes that are silently discarded, reads that must come back empty, and a delete
#     of somebody else's evidence that must remove nothing
ATTACKS=$(grep -c "### ATTACK" <<<"$OUTPUT")
ERRORS=$(grep -c "^psql:.*ERROR:\|^ERROR:" <<<"$OUTPUT")
PASSES=$(grep -c "    PASS" <<<"$OUTPUT")
SILENT_ATTACKS=6
EXPECTED_ERRORS=$((ATTACKS - SILENT_ATTACKS))

printf '\n----------------------------------------\n'
printf 'attacks attempted:  %s\n' "$ATTACKS"
printf 'refused with error: %s (expected %s)\n' "$ERRORS" "$EXPECTED_ERRORS"
printf 'allowed actions:    %s\n' "$PASSES"

[[ "$ATTACKS" -eq 13 ]] \
	|| fail "expected 13 attacks in rls_test.sql, found $ATTACKS — the counts below assume 13"
[[ "$ERRORS" -eq "$EXPECTED_ERRORS" ]] \
	|| fail "expected $EXPECTED_ERRORS refusals, saw $ERRORS — an attack got through, or a legitimate action broke"
[[ "$PASSES" -eq 7 ]] \
	|| fail "expected 7 legitimate actions to succeed, saw $PASSES"

# The three that are checked by their result rather than by an error.
grep -q "^null|null$" <<<"$OUTPUT" \
	|| fail "ATTACK 4: a student wrote the proctor's decision fields"
grep -q "^approved|t|t$" <<<"$OUTPUT" \
	|| fail "faculty approval did not stamp decided_by and decided_at"

# The exit code has to be accepted, and accepting it has to stamp the session.
grep -q "^STAMPED$" <<<"$OUTPUT" \
	|| fail "the right exit code did not stamp exit_verified_at — the guard trigger is eating it"
grep -q "^NOT-STAMPED$" <<<"$OUTPUT" \
	&& fail "exit_verified_at was not stamped by a correct code"
# ATTACK 5 prints one 0, ATTACK 8 two, ATTACK 10 one, ATTACK 12 one (no forged stamp).
# Fewer than five means something leaked. ATTACK 11 is checked separately, by what
# survived it.
[[ "$(grep -c '^0$' <<<"$OUTPUT")" -eq 5 ]] \
	|| fail "ATTACK 5/8/10/12: a student saw what they should not, or forged their own exit stamp"

# The kept frame the student tried to delete has to still be there, and its proctor
# has to be able to read it. Both are the same "1" printed after ATTACK 11.
[[ "$(grep -c '^1$' <<<"$OUTPUT")" -ge 2 ]] \
	|| fail "ATTACK 11: a student deleted a frame kept of them, or its proctor cannot read it"

printf '\n\033[32mAll checks passed.\033[0m\n'
[[ "$KEEP" == true ]] && printf 'Database %s kept. Drop it with: dropdb %s\n' "$DB" "$DB"
exit 0
