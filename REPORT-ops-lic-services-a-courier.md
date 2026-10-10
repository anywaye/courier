# REPORT — ops/w0-lic-services-a-courier

**Wave 0, OPS-P1 part 2 — the four services move from closed to BSL.**
**Repo:** `courier` (worktree `/Users/kaka/Code/any/ops-wt/lic-services-a-courier`,
branch `ops/w0-lic-services-a-courier`).
**Branch base:** `8477af0`. Commits: `c507c03` (LICENSE), `5890765` (manifest),
plus the prose sweep in this report's final commit.

The manager merges and pushes. Nothing here was pushed or merged.

## What landed

| File | Lines | What changed |
|---|---|---|
| `LICENSE` | whole file (90 lines) | "Copyright (c) 2026 Cafaye. All rights reserved." replaced by the Business Source License 1.1. Parameters at `:8-14` — Licensor `Cafaye`, Licensed Work `courier`, Additional Use Grant `None`, Change Date `2030-10-10`, Change License `Apache-2.0` |
| `mix.exs` | `:11-18`, `:31-40`, `:48` | Hex's package metadata is the manifest's licence declaration and it deliberately carried none; it now says `licenses: ["BUSL-1.1"]` (`:48`), and the two comment blocks that argued why the field was absent are rewritten rather than deleted |
| `openapi.yaml` | `:359-361` | `info.license.name` read "Proprietary - All rights reserved"; it now names the BSL and, OpenAPI 3.1 permitting, `identifier: BUSL-1.1` |
| `chart/values.yaml` | `:15-18` | "the substrate is closed source" → "the fleet is licensed BSL rather than open source" |
| `chart/README.md` | `:27-29` | the same sentence in the shipping-the-chart section |
| `README.md` | `:556-576` | a **Licence** section, which did not exist: the old README made no licence claim at all and this one does |
| `REPORT-courier-w85-chart.md` | `:66-69` | annotated, not rewritten — see below |

Not touched: `lib/`, `test/`, `config/`, `bin/`, `.github/`, `Dockerfile`,
`docker-compose.yml`, `cafaye.yml`, `chart/Chart.yaml`, `priv/`, `rel/`,
`AGENTS.md`, `CHANGELOG.md`. Every other licence hit in the tree is
unrelated third-party prose about dependencies (`mix.exs:130-140` on the
`sentry` SDK's own MIT; `docs/error-reporting.md` and
`docker-compose.errors.yml:130-136` on GlitchTip's MIT) and is left alone.

## The finding that matters: "free to self-host" is not in this licence

OPS-D2 states the split as "The services under a Business Source Licence:
free to run, free to self-host, never to offer a competing service"
(`/Users/kaka/Code/any/moon/CAFAYE-OPS.md:176`). Both briefs carried the same
sentence, and the parameters both briefs specified implement only the third
half of it. BSL 1.1's Terms grant "the right to copy, modify, create
derivative works, redistribute, and make **non-production use** of the
Licensed Work" (`LICENSE:23-24`), and the only thing that can widen that is
the Additional Use Grant — which is `None` (`LICENSE:12`). The consequence
is spelled out two paragraphs later: a use that "does not comply with the
requirements currently in effect as described in this License" means you
"must purchase a commercial license from the Licensor … or you must refrain
from using the Licensed Work" (`LICENSE:34-37`).

So under the parameters as specified, **self-hosting courier in production is
not a right this file grants**, and a customer who read "free to self-host"
on the licence page and then read the licence would find the two disagreeing.
The licence is the document that decides; the prose is not. I implemented the
specified parameters (uniform wording across the fleet was the explicit
requirement, and a lone courier diverging from identity/gateway/parlor would
have broken the diff-two-repos property), and did **not** write repo prose
claiming the right does not exist. `README.md:566-576` states the intent,
states what the Terms actually grant, and points here.

**Recommended fix, for whoever owns the fleet's wording:** give the four
services an Additional Use Grant of the standard shape —

> You may use the Licensed Work for any purpose, as long as the use does not
> include offering the Licensed Work to third parties on a hosted or embedded
> basis in order to compete with Cafaye's offering of the Licensed Work.

which is exactly "free to run, free to self-host, never to offer a competing
service", and is the shape most BSL deployments use precisely because it
makes the promise checkable. The alternative is to correct OPS-D2's wording
and sell self-hosting. What must not happen is the sentence staying where it
is while the parameter stays `None`.

## Second finding: the Change Licence and BSL's own covenant

The brief specified Apache-2.0, and Apache-2.0 is what the file says
(`LICENSE:14`). BSL 1.1's Covenants of Licensor, which every Licensor accepts
by using the text, ask that "the Change License [be] the GPL Version 2.0 or
any later version, or a license that is compatible with GPL Version 2.0 or a
later version" (`LICENSE:73-77`). Apache-2.0 is compatible with GPLv3 and is
**not** compatible with GPLv2. This is a cheap thing to change now and an
expensive thing to change in four years, and it is the manager's call — the
brief said Apache-2.0, so Apache-2.0 shipped.

## Third finding: the manifest schema has no licence field at all

`cafaye.yml` carries no licence declaration (measured: no `licen[cs]e` key in
`cafaye.yml:175-260`, and no `licen*` key anywhere in
`core/schemas/cafaye.manifest.schema.json`). That matters to this packet
because `chart/Chart.yaml:1` is generated from `cafaye.yml` and says
`DO NOT EDIT`, so a Helm `licenses:` annotation cannot be added here without
either editing a generated file or changing the generator and the schema —
both of which live in other repositories. OPS-D2 anticipated the shape
("any manifestless repo need both a grant and a `cafaye.yml`",
`CAFAYE-OPS.md:176`); the follow-up is core's, not courier's: add a licence
key to the manifest schema so the fleet's grant is machine-readable.

## The one historical report, and why it was annotated rather than rewritten

`REPORT-courier-w85-chart.md:64-66` read "the fleet is closed source and a
customer must pull the chart without read access to the source repos". That
sentence was true when the packet was written and is dated — the report's own
header carries a base commit (`:3`). Rewriting it would falsify the record,
and this repository's own rule is that a contradiction is named rather than
smoothed over. So the original sentence stands and is followed by a bracketed
superseding note (`:66-69`) that dates the change and states that the registry
design is unaffected. If the manager would rather the sentence itself were
edited, it is a one-line change.

The same judgement applied to `mix.exs:12` and `README.md:559`, which
describe the *previous* closed grant as replaced — the past tense is the
claim there, and it is accurate.

## Verification

No gate arm reads the licence, so none was run. The evidence for that is a
grep rather than an assumption: `grep -rn -i "licen[cs]e" test/ bin/ .github/`
returns two hits, neither about courier's grant
(`test/courier/compose_config_test.exs:484` and `test/support/test_dns.ex:25`,
both using "licence" in the ordinary sense). courier's
`openapi_document_test.exs` holds the document to the router by **path**,
never by `info` — measured, that file's assertions are over `Map.keys(...)`
paths and its exclusion list (`:16`, `:124`, `:142`, `:155`) and it contains no
reference to `license` at all — so `openapi.yaml:359-361` cannot affect it.

What was run instead, all green:

- `git status --porcelain` and `git diff --stat` (below, as the brief requires).
- `Code.string_to_quoted!` on `mix.exs` — parsed ok. The change is one keyword
  inside a list plus comments, and there is no other way for it to fail.
- `YAML.load_file` on `openapi.yaml`, `chart/values.yaml` and
  `chart/Chart.yaml` — all OK, with `aliases: true`.
- The sweep grep, after the edits: the only remaining hits are the MariaDB
  copyright the BSL text itself requires (`LICENSE:3`), the two past-tense
  descriptions of the replaced grant, and the annotated historical sentence.

A full `bin/prime` was not run in this worktree: it has no `deps/` and no
`_build/`, so it would spend the hour fetching and compiling a tree whose
change is a document. `mix precommit` was not run for the same reason, and
it is named here rather than quietly skipped.

## Disagreements, as the brief asks

1. **Additional Use Grant `None` contradicts OPS-D2's promise** — above, and
   the only one I would call blocking for the fleet's licence page.
2. **Apache-2.0 as Change Licence sits against BSL 1.1's covenant** — above.
3. **The Change Date is one date for the whole work.** The brief says "four
   years from today", and today is 2026-10-10, so `LICENSE:13` reads
   `2030-10-10`. BSL's own note is that the Change Date is otherwise measured
   from "the fourth anniversary of the first publicly available distribution of
   a specific version" (`LICENSE:28-32`) — which would make every version
   released from today on expire in 2030 at once, and every version released in
   2031 expire in 2035. One flat date is what was asked for and it is the
   simpler thing to audit; worth knowing that it is not what the licence
   defaults to.
4. **`info.license` gained an `identifier`.** A pure `name:` edit would have
   been the smaller diff and the one the other three workers will most likely
   produce. I added `identifier: BUSL-1.1` (`openapi.yaml:361`) because
   OpenAPI 3.1 defines it and a generator reading this document can then check
   the licence rather than parse English. Say the word and it goes.

## Not mine, and owed by someone

- `parlor/package.json:4` still reads `"license": "UNLICENSED"`. Not this
  repo's file; it is this wave's.
- `identity` and `gateway` manifests: not measured here, same reason.
