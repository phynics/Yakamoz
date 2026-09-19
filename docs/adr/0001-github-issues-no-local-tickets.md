# Track work only as GitHub issues

Yakamoz left the monorepo, whose work was tracked as local ticket files under the shared
`workflow/Yakamoz/tickets/` directory with `Status`/`Triage` lines and archive-on-close. The
standalone repository shares no filesystem with that system, so work is tracked only as
GitHub issues on `phynics/Yakamoz`; no local ticket files and no archive directory. GitHub's
open/closed state replaces the `Status` lifecycle, and the default labels replace the
`Triage` taxonomy.
