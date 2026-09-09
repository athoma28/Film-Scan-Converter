# Maintenance Scope

The native app is the product target. Current priorities and acceptance criteria
are in the [roadmap](MacOS-Native-Roadmap.md); current evidence is in
[development status](../development/native-macos.md).

Python changes are limited to critical correctness, data-loss, compatibility,
and fixture reproducibility work under the [legacy policy](../legacy-python.md).
Shared pixel behavior requires equivalence tests. Performance work requires a
measured bottleneck and a comparable before/after workload.

Resolved proposal lists and superseded handoff instructions are retained in Git
history rather than presented as active tasks.
