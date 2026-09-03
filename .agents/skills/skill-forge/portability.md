# Making a skill usable across Firstmate worker hosts

This reference is a captain-authorized adaptation of the captain-owned local skill-forge source on 2026-09-03.
A portable skill has one authoritative body in its owning repository and thin host adapters only where a supported host requires one.
Never duplicate the procedure into home-directory installations because copies drift.

## The pattern

1. Keep the host-neutral procedure in the owning repository's skill directory or established portable procedure surface.
2. Keep host-specific invocation syntax, tool names, and discovery mechanics in a thin adapter or reference beside that owner.
3. Point every supported host at the same authoritative bytes when its discovery mechanism allows it.
4. Install or update fleet-visible bytes only after the owning repository's reviewed delivery path lands.

A skill that genuinely depends on one host may remain host-specific.
State that limitation instead of pretending its procedure is portable.

## Which repository

Use the repository that owns the procedure, not whichever local copy is convenient.
Read that repository's instructions and audience inventory before adding an adapter or documentation pointer.
Firstmate routes repository writes to a worker in an isolated copy and preserves the registered validation, delivery, and merge authority.

## Rules

- Check current repository state before writing and do not disturb another worker's changes.
- Keep one source of truth for the procedure.
- Re-derive every host path and invocation from the current host rather than copying a workstation-specific path.
- Keep private evidence, credentials, machine paths, and installation state out of a portable skill.
- Expose exact candidate bytes from an isolated repository discovery location for evaluation.
- Do not install candidate bytes into a fleet-visible location before reviewed delivery lands.

## Verifying portability

Ask a fresh-context evaluator on each claimed host to perform an unrelated task using the candidate from an isolated repository discovery location.
Bind the result to the exact candidate commit and require the host to report whether it loaded the skill.
If the evaluator needs an undocumented host-specific affordance, narrow the portability claim or add a thin adapter at the existing owner.
