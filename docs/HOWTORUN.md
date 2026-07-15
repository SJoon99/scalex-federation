# How to run the experiment locally

From this worktree only:

```bash
cd /home/joon/study/scalex/worktrees/scalex-federation-single-values
FEATURE_REPOS_ROOT=/home/joon/study/scalex/work ./scripts/validate.sh
./tests/catalog/test-catalog-validation.sh
```

Do not run these commands from the main worktree or the per-release comparison
worktree.

The current catalog entry is disabled. Validation still Helm-renders it for
compatibility, but ApplicationSet generation filters it out because the pinned
feature chart does not yet render `PropagationPolicy` templates.
