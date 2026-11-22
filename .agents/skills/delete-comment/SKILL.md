---
name: delete-comment
description: Audit and remove Starlark comments without losing decisions or weakening the lint ratchet.
disable-model-invocation: true
---

# Delete comments

1. Pick a tranche within the two rulesets. Run `python3 tools/ci/starlark_comment_ratchet.py --inventory` from the repository root. Record the base revision and a file:line disposition for every comment in the tranche. Review adjacent code and existing decisions before labeling. Keep recognized Buildifier directives while their warnings still need suppression; string contents and docstrings are not comment tokens.
2. Classify and act:
   - **Tautology:** The code already says it. Delete it.
   - **Stale:** The comment contradicts the current implementation or refers to a retired one. Verify against the code, then delete it.
   - **Excuse:** The comment justifies a defect or a known workaround. File or update an issue with evidence, impact, and an observable acceptance criterion, then delete the comment. Do not treat a documented compatibility requirement as a defect.
   - **Decision Record:** Preserve the non-obvious choice and why, including meaningful rejected alternatives or constraints, in the existing ADR or a new one. Delete the comment only once that rationale is recorded. For mixed blocks, preserve the decision and track any defect before deletion.
3. Run `python3 tools/ci/starlark_comment_ratchet.py --base <target-commit>` against the PR target revision and the relevant narrow format check. Work in coherent tranches; leave unreviewed comments grandfathered rather than rewriting or relocating them inside source. Report physical source lines removed, remaining prose lines, preserved directives, and ADR and issue paths.
