# Domain docs

How engineering skills should consume this repository's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repository root, or
- **`CONTEXT-MAP.md`** at the repository root if it exists; it points to one `CONTEXT.md` per context. Read each one relevant to the topic.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in.

If any of these files don't exist, proceed silently. Don't flag their absence or suggest creating them upfront. The `/domain-modeling` skill creates them when terms or decisions are resolved.

## File structure

This is a single-context repository:

```
/
├── CONTEXT.md
├── docs/adr/
└── supabase/
```

## Use the glossary's vocabulary

When naming a domain concept in an issue title, refactor proposal, hypothesis, or test, use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept isn't in the glossary yet, reconsider whether the project uses that term or note the gap for `/domain-modeling`.

## Flag ADR conflicts

If a proposal contradicts an existing ADR, surface it explicitly rather than silently overriding it:

> _Contradicts ADR-0007, but worth reopening because…_
