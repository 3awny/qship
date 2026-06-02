"""Read-only scan: every active tenant's alembic_version vs branch's alembic history.

Implements Check 3i from ``qmigrationdevcheck`` for the case where you
have staging credentials and want a full multi-tenant view.

Connects to staging global DB, lists tenants from ``account_registry``,
then for each tenant fetches its the Postgres provider connection string, queries
each schema's ``<schema>.alembic_version``, and reports any
revision that is NOT resolvable in the current branch's alembic history.

NO writes. NO stamping. Pure scan.

Usage::

    python scan_orphan_tenants.py \\
        --core-root /path/to/{{PRIMARY_REPO_NAME}} \\
        --app-root /path/to/{{PRIMARY_REPO_NAME}}

Env (loaded from ``<core-root>/.env`` and ``<core-root>/.env.staging``;
staging takes precedence so the staging GLOBAL_DATABASE_URL wins, while
DB_PROVIDER_API_KEY (typically only in .env) stays available):

    GLOBAL_DATABASE_URL  - staging multi-tenant global DB
    DB_PROVIDER_API_KEY         - DB provider API key for connection-string fetching
    DATABASE_OWNER       - optional, default ``{{DB_OWNER_ROLE}}``

Exit code: 0 if all tenants stamped at branch-resolvable revisions,
1 if any orphan found, 2 on operator error (missing env, missing repos).
"""
from __future__ import annotations

import argparse
import os
import sys
import traceback
from typing import Set


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--core-root",
        required=True,
        help="Absolute path to {{PRIMARY_REPO_NAME}} checkout (must contain alembic.ini)",
    )
    parser.add_argument(
        "--app-root",
        required=True,
        help="Absolute path to {{PRIMARY_REPO_NAME}} checkout",
    )
    return parser.parse_args()


_ARGS = _parse_args()
{{COMPANY_SLUG_UPPER}}_CORE = os.path.abspath(_ARGS.core_root)
{{COMPANY_SLUG_UPPER}}_APP = os.path.abspath(_ARGS.app_root)
for _root in ({{COMPANY_SLUG_UPPER}}_CORE, {{COMPANY_SLUG_UPPER}}_APP):
    if not os.path.isfile(os.path.join(_root, "alembic.ini")):
        print(f"ERROR: {_root}/alembic.ini not found", file=sys.stderr)
        sys.exit(2)
sys.path.insert(0, {{COMPANY_SLUG_UPPER}}_CORE)
sys.path.insert(0, {{COMPANY_SLUG_UPPER}}_APP)

from dotenv import load_dotenv

load_dotenv(os.path.join({{COMPANY_SLUG_UPPER}}_CORE, ".env"), override=False)
load_dotenv(os.path.join({{COMPANY_SLUG_UPPER}}_CORE, ".env.staging"), override=True)

# Sanity check.
if not os.environ.get("GLOBAL_DATABASE_URL", "").startswith("postgresql"):
    print("ERROR: GLOBAL_DATABASE_URL not set from .env.staging")
    sys.exit(2)
if not os.environ.get("DB_PROVIDER_API_KEY"):
    print("ERROR: DB_PROVIDER_API_KEY not set")
    sys.exit(2)

import sqlalchemy
from sqlalchemy import create_engine, text

from {{COMPANY_SLUG}}.{{PRIMARY_REPO_NAME}}.data_models.orm.account_registry import AccountRegistry  # noqa: E402
from {{COMPANY_SLUG}}.{{PRIMARY_REPO_NAME}}.db.registry_db import get_registry_db  # noqa: E402
from {{COMPANY_SLUG}}.{{PRIMARY_REPO_NAME}}.services.db_provider_client import DBProviderClient  # noqa: E402


def _branch_revisions(repo_root: str, schema: str) -> Set[str]:
    """Return every revision id reachable from the current branch's
    alembic history for the given schema."""
    sys.path.insert(0, repo_root)
    from alembic.config import Config
    from alembic.script import ScriptDirectory

    cfg = Config(os.path.join(repo_root, "alembic.ini"))
    cfg.set_main_option("script_location", os.path.join(repo_root, "alembic"))
    if schema and repo_root.endswith("{{PRIMARY_REPO_NAME}}"):
        cfg.set_main_option(
            "version_locations", os.path.join(repo_root, f"alembic/versions/{schema}")
        )
    sd = ScriptDirectory.from_config(cfg)
    return {rev.revision for rev in sd.walk_revisions()}


def main() -> int:
    print("== Resolving branch alembic histories ==")
    core_revs = _branch_revisions({{COMPANY_SLUG_UPPER}}_CORE, "{{PRIMARY_REPO_NAME}}")
    app_revs = _branch_revisions({{COMPANY_SLUG_UPPER}}_APP, "")
    print(f"  {{PRIMARY_REPO_NAME}} history     : {len(core_revs)} revisions")
    print(f"  {{PRIMARY_REPO_NAME}} history : {len(app_revs)} revisions")

    print("\n== Listing active tenants ==")
    registry_db = get_registry_db()
    with registry_db.get_registry_db_session() as session:
        tenants = (
            session.query(AccountRegistry)
            .filter(AccountRegistry.is_active.is_(True))
            .all()
        )
        tenants_data = [
            {
                "tenant_id": str(t.tenant_id),
                "tenant_name": t.tenant_name,
                "db_project_id": t.db_project_id,
                "db_branch_id": t.db_branch_id,
                "db_database_name": t.db_database_name,
            }
            for t in tenants
            if not t.tenant_name.startswith("TEST:")
        ]
    print(f"  {len(tenants_data)} active non-test tenants")

    the_db_provider = DBProviderClient(os.environ["DB_PROVIDER_API_KEY"])
    db_owner = os.environ.get("DATABASE_OWNER", "{{DB_OWNER_ROLE}}")

    orphans = []
    skipped = []
    for t in tenants_data:
        name = t["tenant_name"]
        try:
            uri = the_db_provider.build_connection_string(
                t["db_project_id"],
                t["db_branch_id"],
                t["db_database_name"],
                db_owner,
                pooled=True,
            )
        except Exception as exc:
            skipped.append((name, f"the_db_provider connection: {exc!r}"))
            continue
        try:
            engine = create_engine(uri, connect_args={"connect_timeout": 10})
            with engine.connect() as conn:
                for schema, branch_revs in (
                    ("{{PRIMARY_REPO_NAME}}", core_revs),
                    ("{{PRIMARY_REPO_NAME}}", app_revs),
                ):
                    try:
                        rows = conn.execute(
                            text(f"SELECT version_num FROM {schema}.alembic_version")
                        ).fetchall()
                    except sqlalchemy.exc.ProgrammingError:
                        # Schema or table missing — note and continue
                        skipped.append((name, f"{schema}: alembic_version absent"))
                        continue
                    for (rev,) in rows:
                        if rev not in branch_revs:
                            orphans.append((name, schema, rev))
                            print(f"  ORPHAN  {name:35s}  {schema:10s}  {rev}")
            engine.dispose()
        except Exception as exc:
            skipped.append((name, f"{type(exc).__name__}: {exc}"))

    print("\n== Summary ==")
    print(f"  Tenants scanned : {len(tenants_data)}")
    print(f"  Orphan stamps   : {len(orphans)}")
    print(f"  Skipped tenants : {len(skipped)}")
    if skipped:
        print("\nSkipped detail:")
        for n, reason in skipped:
            print(f"  - {n}: {reason}")

    if orphans:
        print("\nOrphans (tenant, schema, revision):")
        for n, s, r in orphans:
            print(f"  {n}  {s}  {r}")
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(2)
