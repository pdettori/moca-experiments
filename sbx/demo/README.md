# sbx demo: a first `mocactl sbx up` exercise

A two-file repository with one deliberate bug: `calc.py` implements `add` as
subtraction, so `test_calc.py` (stdlib `unittest`, no dependencies — the sandbox
guest has no network, so anything needing `pip install` cannot run its tests there)
fails. It is the same shape `deploy/sbx/smoke.sh` step 1 uses, sized for a first
session in the MOCA sandbox service.

## The exercise

From this directory, with `mocactl` installed and enrolled (your operator gives you
the control-plane URL and adds your GitHub account to the allowlist):

```bash
mocactl sbx login --control-plane-url <URL>   # once; it is remembered

mocactl sbx up                                # push the tree, bind the sandbox, wire the agent config
mocactl sbx run -- python3 -m unittest        # the failing test, inside a fresh VM

# fix it either way:
claude                                        # the repo's .mcp.json points Claude Code at the
                                              # sandbox; prompt: "The test suite fails
                                              # (python3 -m unittest). Fix it with a minimal
                                              # change and run the tests."
# or by hand:
printf 'def add(a, b):\n    return a + b\n' | mocactl sbx put calc.py

mocactl sbx pull --apply                      # bring the fix back to this tree
python3 -m unittest                           # passes locally; git diff shows the one-line change
```

What this walks through: `up`'s push and agent binding, per-`Exec` microVMs, the
client write path (`put`), the MCP path if you use an agent, and `pull --apply`'s
guarded apply. Internal code only, no secrets — the sandbox is shared
infrastructure.

The bug is the point: don't fix it before pushing.
