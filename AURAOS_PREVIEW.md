# AuraOS isolated preview

This branch is an isolated preview of the `AuraOS-main.zip` archive committed on `main`.

## Safety rules

- `main` is not modified by this branch.
- The existing Premieros/55 source remains intact at the repository root.
- AuraOS is extracted into `auraos/` by the preview workflow.
- `.env`, `node_modules`, and nested `.git` content are excluded from extraction commits.
- AuraOS is **not** connected to the existing Premieros/55 Supabase database.
- GitHub Pages can host only the AuraOS static frontend; its Express/PostgreSQL backend requires a separate runtime/database.

## Preview path

The workflow publishes a combined Pages artifact:

- Existing app: `/55/`
- AuraOS static preview: `/55/auraos-preview/`

The AuraOS preview uses hash routing to remain compatible with GitHub Pages.
