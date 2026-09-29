# Development experience — plain JVM vs Kubernetes

A hands-on log of what it costs to develop the same connector on each path.
The lab keeps both ([design.md](design.md) → "Topology"), so claims like
"Kubernetes slows the inner loop" can rest on measurements instead of
opinion. Record entries as they happen; summarize once both paths have
enough entries.

## How to log

Same task, both paths, measured the same way:

- **Iteration time**: from saving a change to seeing its effect in a
  passing (or failing) check.
- **Steps**: commands or manual actions needed.
- **Friction**: anything that failed, confused, or needed a workaround —
  including where the signal was (which log, which command).

Paths: **JVM** = T0–T2 (in-IDM or RCS on the host). **K8s** = T3 (RCS pod
in minikube). Topology codes are defined in design.md.

## Standard tasks

Run each task on both paths at least once:

1. Edit a Groovy script (e.g. add a log line) and observe it.
2. Change a connector config property (provisioner JSON).
3. Rotate a secret (RCS credential; Databricks SP secret).
4. Find the log line for a failed operation.
5. Debug a failure (attach a debugger or add tracing).
6. Upgrade the RCS version.
7. Recover from a killed process/pod mid-operation.

## Log

| Date | Task | Path | Iteration time | Steps | Friction / notes |
|---|---|---|---|---|---|
| | | | | | |

## Summary

_Pending — written after both paths have entries for the standard tasks._
