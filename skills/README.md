# Skills

Portable, reusable skills (Claude Agent Skills format — each is a folder with a
`SKILL.md` carrying YAML frontmatter) distilled from building this DTL-GenAI
framework. They document the patterns AND the hard-won gotchas so another agent
or LLM can pick up the work without rediscovering them.

Drop the `skills/` folder where your agent loads skills from (e.g. a Claude Code
plugin's `skills/`, or `~/.claude/skills/`), or read the `SKILL.md` files directly.

| Skill | Use it when… |
|---|---|
| [`objectscript-gotchas`](objectscript-gotchas/SKILL.md) | Writing/compiling ObjectScript; debugging `#1043`/`<SYNTAX>`/`#5351`; the `iris session` terminal; status checks; dynamic objects. |
| [`dtl-generation`](dtl-generation/SKILL.md) | Generating/compiling/verifying HL7 v2 DTL (incl. with an LLM loop); DocType, segment-path, MSH-offset, grouped-segment, repeating-field traps; success policies; prompt + injection safety. |
| [`intersystems-ui-theme`](intersystems-ui-theme/SKILL.md) | Building an InterSystems-themed single-file SPA served by IRIS; palette + logo; REST-base derivation; job polling; file-upload-as-base64; LCS diff; portal links. |
| [`iris-interop-rest`](iris-interop-rest/SKILL.md) | Ens productions + `%CSP.REST`; HTTP outbound adapter JSON body; creating CSP web apps in %SYS; the cross-namespace trap; `AutheEnabled` bits; async dispatch; FileInboundAdapter boot-with-path; Visual Trace links; production lifecycle recovery. |
| [`iris-embedded-python`](iris-embedded-python/SKILL.md) | Python from IRIS (PDF/DOCX text extraction, pip libs); the out-of-process `irispython` + `$ZF(-100)` pattern; avoiding SIGSEGV / hung-instance / destroyed-DB. |
| [`iris-docker-ops`](iris-docker-ops/SKILL.md) | Running/scripting IRIS in Docker; `docker cp` path-mangling; CRLF; keeping a sidecar alive; and the full recovery playbook (incl. "never `iris stop`"). |

These cross-reference each other; start with the one matching your immediate task.
