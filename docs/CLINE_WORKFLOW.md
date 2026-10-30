# Focused Cline coding workflow

Use a fresh task for a distinct change. First read `PROJECT_MAP.md` and the root `.clinerules`; keep the existing permission settings.

1. **Define success.** Identify one bug or behavior, expected result, affected platform, and a reproducer. If no bug is specified, propose a concrete candidate with evidence before modifying source.
2. **Inspect narrowly.** Check Git status, find relevant symbols, and read only needed source/test ranges. Track what was read. At 10 read/search calls, summarize findings and narrow any remaining investigation.
3. **Plan the patch.** Explain the cause, smallest fix, files to change, and regression test. Distinguish a confirmed defect from a hypothesis. Honor any requested review-before-edit step.
4. **Review and apply.** Review the diff for scope, unintended behavior, and preservation of existing work. Do not weaken tests or alter security/signing to get a pass.
5. **Verify.** Run the suites required by `.clinerules`; inspect exact commands and working directory before approval. Run assembly/lint or device checks when relevant. If a prerequisite blocks testing, report it rather than claiming success.
6. **Report.** Give changed paths, actual test results, remaining risks, elapsed time, tool-call count if available, and repeated reads with reasons. Keep claims proportional to the evidence.

## First real-task prompt

> Fix [specific reproducible bug] on [iOS/Android/shared]. First read the project map and inspect existing changes. State acceptance criteria, inspect only relevant files, and propose the minimal patch and regression test before editing. After the reviewed edit, run the required tests. Do not modify unrelated changes. At ten read/search calls, summarize progress before continuing. Use web search only for necessary public documentation and report search errors accurately.

## Read-only check of the new guidance

> Read the project map and rules. Without tools that modify files or run builds, identify the entry point, likely implementation files, and exact required test commands for a change to Android water-depth interpolation. Use at most five targeted reads/searches, cite local paths, and stop with a short plan. Do not reread unchanged ranges or search the web.

Success means a focused, path-backed plan without a repository-wide scan. Compare subsequent coding tasks against the earlier broad review's repeated reads; do not promise a speedup before measuring it. A larger context window does not replace a bounded task.
