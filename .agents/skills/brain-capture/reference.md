# OKF page contract (Shared Brain profile v1)

This reference is a captain-authorized import from the captain-owned local brain-capture source on 2026-09-03.
The registered Shared Brain repository is authoritative.
If this file and its current validation code disagree, the repository code wins.

## File shape

Frontmatter is JSON between `---` fences (JSON is valid YAML, and the validator
parses it with `yaml.safe_load`), followed by the Markdown body.

```
---
{
  "schema_version": "1.0",
  "okf_version": "0.2",
  "id": "lesson:my-slug",
  "type": "engineering-lesson",
  "title": "Human Readable Title",
  "description": "One sentence naming the reusable lessons.",
  "status": "draft",
  "brain_status": "proposed",
  "visibility": "private",
  "created_at": "2026-08-27T21:37:08+10:00",
  "updated_at": "2026-08-27T21:37:08+10:00",
  "generated": {"by": "agent:<current-worker>", "at": "<current RFC 3339 timestamp with offset>"},
  "tags": ["diagnosis", "evidence"],
  "sources": [
    {
      "id": "my-retrospective",
      "resource": "../../docs/retrospectives/my-slug.md",
      "content_hash": "sha256:<64 hex>",
      "locator": "My Retrospective",
      "author": "agent:<current-worker>"
    }
  ],
  "relationships": [
    {"predicate": "reinforces", "target_id": "lesson:other-slug"}
  ]
}
---

# Human Readable Title

Opening claim, carrying a citation.[^my-retrospective]

## Durable lessons

- Imperative, transferable, one per line.

## Reuse guidance

When to retrieve this, and what stayed in the source retrospective.

[^my-retrospective]: Short description of the cited source.
```

## Field rules

| Field | Rule |
|---|---|
| `schema_version` | exactly `"1.0"` |
| `okf_version` | exactly `"0.2"` |
| `id` | `^[a-z][a-z0-9-]*:[A-Za-z0-9._~-]+$` - use `lesson:<slug>` |
| `status` | `draft` \| `stable` \| `deprecated` |
| `brain_status` | `proposed` \| `active` \| `disputed` \| `superseded` \| `retracted` \| `archived` |
| `visibility` | `private` \| `shared` \| `public` - default `private` |
| timestamps | RFC 3339 **with** offset. Naive timestamps are rejected |
| `generated` | `{by, at}` both required |
| `sources` | at least one; each needs `resource` + `content_hash` |
| `relationships[].predicate` | `^[a-z][a-z0-9_]*$` |

`additionalProperties` is **false** - an unrecognized key fails validation.

## Semantic checks beyond the schema

- `updated_at` must not precede `created_at`.
- `generated.at` must not follow `updated_at`.
- Local `resource` paths resolve relative to the **page**, must stay inside the
  repository, must exist, and `content_hash` must equal the file's actual
  sha256. Run `stamp.py` rather than computing by hand.
- Every `[^id]` in the body must match a declared source `id`.
- A page declaring `sources` must contain at least one footnote citation.
- Every `relationships[].target_id` must exist as some page's `id`.
- Entity `id`s must be unique across `knowledge/`.

## Index rules

- `knowledge/index.md` frontmatter may contain **only** `okf_version`.
- Any non-root `index.md` must have **no** frontmatter.
- A `log.md` must have no frontmatter, and its `##` headings must be ISO dates.

## Failure messages

| Message | Cause |
|---|---|
| `local source hash mismatch` | retrospective edited after stamping - re-run `stamp.py` |
| `sourced concept body must contain a source footnote` | body has no `[^id]` |
| `citations without source IDs` | `[^id]` with no matching source `id` |
| `relationship target does not exist` | `target_id` resolves to nothing |
| `timezone offset is required` | timestamp lacks `+HH:MM` |
| `potential <kind> detected in <path>` | secret scanner hit - redact |
| `Additional properties are not allowed` | unrecognized frontmatter key |

## Secret scanner

Runs over the whole repository on every validation. Patterns include private
keys, GitHub / OpenAI / AWS / Google / Slack tokens, and any
`password|secret|api_key|access_token|auth_token` followed by `:` or `=` and 8+
non-space characters. Avoid that shape even in prose. The privacy policy
additionally forbids auth URLs, emails, public IPs, and account identifiers,
which the scanner does not catch.
