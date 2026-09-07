from pathlib import Path
import re
import shutil
import zipfile

ROOT = Path('.')
ARCHIVE = ROOT / 'johna-s.zip'
TMP = ROOT / '.tmp-db-identity-cleanup'
CANONICAL = 'scpovyrqmsbiduanykod'
OLD_REFS = ('azzdesuowpdcoflmyezn', 'lwnsdsncmlsroiswgoga')
HISTORICAL_DOCS = {
    'docs/MASTER_LOG2.md',
    'docs/P0_STOCK_VALUATION_PRODUCTION_REPORT.md',
    'docs/ERP-01_REPORT.md',
    'docs/ERP-01_EXECUTION_PLAN.md',
}

if not ARCHIVE.exists():
    raise SystemExit('johna-s.zip not found')

shutil.rmtree(TMP, ignore_errors=True)
TMP.mkdir(parents=True)
with zipfile.ZipFile(ARCHIVE, 'r') as zf:
    zf.extractall(TMP)

for path in TMP.rglob('*'):
    if not path.is_file():
        continue
    try:
        text = path.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    rel = path.relative_to(TMP).as_posix()
    if not any(ref in text for ref in OLD_REFS):
        continue
    replacement = 'LEGACY_SUPABASE_PROJECT_REMOVED' if rel in HISTORICAL_DOCS else CANONICAL
    for ref in OLD_REFS:
        text = text.replace(ref, replacement)
    path.write_text(text, encoding='utf-8')

lock = TMP / 'docs/DATABASE_IDENTITY_LOCK.md'
lock.parent.mkdir(parents=True, exist_ok=True)
lock.write_text(
    f"""# Database Identity Lock — Premieros/55

## Canonical project identity

This repository is bound to exactly one Supabase project unless the user explicitly approves a database migration:

- Repository: `Premieros/55`
- Supabase project ref: `{CANONICAL}`
- Supabase project URL: `https://{CANONICAL}.supabase.co`

## Non-negotiable rule

Application code, CI/deployment workflows, tests, environment files and operational database scripts must not point to any other remote Supabase project. Any other remote project ref or URL is a hard failure.

Localhost/127.0.0.1 database URLs remain allowed only for isolated local/CI tests.

## Enforcement

`scripts/db/verify-database-identity.js` enforces the canonical identity and rejects a different `SUPABASE_PROJECT_REF`, `VITE_SUPABASE_URL`, or remote `SUPABASE_DB_URL`.

## Change control

Changing the database identity requires an explicit user instruction and coordinated updates to this lock, CI/deployment configuration, tests and migration tooling.
""",
    encoding='utf-8',
)

verifier = TMP / 'scripts/db/verify-database-identity.js'
verifier.write_text(
    f"""const EXPECTED_PROJECT_REF = '{CANONICAL}'
const EXPECTED_URL = `https://${{EXPECTED_PROJECT_REF}}.supabase.co`

const configuredRef = (process.env.SUPABASE_PROJECT_REF || EXPECTED_PROJECT_REF).trim()
const configuredUrl = (process.env.VITE_SUPABASE_URL || EXPECTED_URL).trim().replace(/\\\/$/, '')

function fail(message) {{
  console.error(`DATABASE_IDENTITY_LOCK_FAILED: ${{message}}`)
  process.exit(1)
}}

if (configuredRef !== EXPECTED_PROJECT_REF) {{
  fail(`SUPABASE_PROJECT_REF must be ${{EXPECTED_PROJECT_REF}}, received ${{configuredRef || '<empty>'}}`)
}}

let parsed
try {{
  parsed = new URL(configuredUrl)
}} catch {{
  fail('VITE_SUPABASE_URL is not a valid URL')
}}

if (parsed.protocol !== 'https:' || parsed.hostname !== `${{EXPECTED_PROJECT_REF}}.supabase.co`) {{
  fail(`VITE_SUPABASE_URL must be ${{EXPECTED_URL}}`)
}}

const dbUrl = (process.env.SUPABASE_DB_URL || '').trim()
if (dbUrl && !/localhost|127\\.0\\.0\\.1/.test(dbUrl)) {{
  let dbHost = ''
  try {{
    dbHost = new URL(dbUrl).hostname
  }} catch {{
    fail('SUPABASE_DB_URL is not a valid database URL')
  }}
  const directHost = `db.${{EXPECTED_PROJECT_REF}}.supabase.co`
  const isDirect = dbHost === directHost
  const isPooler = dbHost.endsWith('.pooler.supabase.com') && dbUrl.includes(EXPECTED_PROJECT_REF)
  if (!isDirect && !isPooler) {{
    fail(`SUPABASE_DB_URL does not belong to ${{EXPECTED_PROJECT_REF}}`)
  }}
}}

console.log(`Database identity verified: ${{EXPECTED_PROJECT_REF}}`)
""",
    encoding='utf-8',
)

migrate = TMP / 'scripts/db/migrate-target-db.mjs'
if migrate.exists():
    text = migrate.read_text(encoding='utf-8')
    text, count = re.subn(
        r"const DB_URL = process\.env\.SUPABASE_DB_URL \|\| '[^']+';",
        "const DB_URL = (process.env.SUPABASE_DB_URL || '').trim();\n"
        "if (!DB_URL) {\n"
        "  throw new Error('SUPABASE_DB_URL is required; no database credential may be embedded in source code.');\n"
        "}\n"
        f"if (!DB_URL.includes('{CANONICAL}') && !/localhost|127\\.0\\.0\\.1/.test(DB_URL)) {{\n"
        f"  throw new Error('SUPABASE_DB_URL does not belong to the locked Supabase project {CANONICAL}.');\n"
        "}",
        text,
        count=1,
    )
    if count != 1:
        raise SystemExit('Expected hard-coded SUPABASE_DB_URL fallback was not found exactly once')
    migrate.write_text(text, encoding='utf-8')

env_example = TMP / '.env.example'
if env_example.exists():
    env_example.write_text(
        f'SUPABASE_PROJECT_REF={CANONICAL}\n'
        f'VITE_SUPABASE_URL=https://{CANONICAL}.supabase.co\n'
        'VITE_SUPABASE_ANON_KEY=\n'
        'SUPABASE_DB_URL=\n',
        encoding='utf-8',
    )

remaining = []
refs = set()
ref_pattern = re.compile(r'(?:https://|db\.)([a-z0-9]{20})\.supabase\.co', re.I)
leaked_password_marker = '17vgWFWzH0vsptOo'
for path in TMP.rglob('*'):
    if not path.is_file():
        continue
    try:
        text = path.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    if any(ref in text for ref in OLD_REFS):
        remaining.append(path.relative_to(TMP).as_posix())
    if leaked_password_marker in text:
        raise SystemExit(f'Embedded database password marker remains in {path}')
    refs.update(match.group(1) for match in ref_pattern.finditer(text))

if remaining:
    raise SystemExit('Obsolete Supabase refs remain in: ' + ', '.join(remaining))
if refs != {CANONICAL}:
    raise SystemExit(f'Unexpected Supabase project refs remain: {sorted(refs)}')

new_archive = ROOT / 'johna-s.cleaned.zip'
if new_archive.exists():
    new_archive.unlink()
with zipfile.ZipFile(new_archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for path in sorted(TMP.rglob('*')):
        if path.is_file():
            zf.write(path, path.relative_to(TMP).as_posix())
new_archive.replace(ARCHIVE)
shutil.rmtree(TMP)

(ROOT / '.env.example').write_text(
    f'SUPABASE_PROJECT_REF={CANONICAL}\n'
    f'VITE_SUPABASE_URL=https://{CANONICAL}.supabase.co\n'
    'VITE_SUPABASE_ANON_KEY=\n'
    'SUPABASE_DB_URL=\n',
    encoding='utf-8',
)
(ROOT / 'DATABASE_IDENTITY_LOCK.md').write_text(
    f"""# Database Identity Lock — Premieros/55

The only approved Supabase project for this repository is:

- Project ref: `{CANONICAL}`
- Project URL: `https://{CANONICAL}.supabase.co`

Any other remote Supabase project reference is prohibited. Localhost/127.0.0.1 may be used only for isolated tests.
""",
    encoding='utf-8',
)

print(f'Database identity cleanup verified: only {CANONICAL} remains')
