# How we used Kiro

Windowfolk was created during the Kiroween 2026 submission period; its first repository commit is dated November 10, 2026. The project enters the **Resurrection** category: bringing the early desktop-pet experience back as a world whose possibilities depend on the arrangement of real application windows.

## From a scene to a specification

The initial idea was deliberately concrete: one resident wants to carry a flowerpot to a neighbor on another window. Together with Kiro, we developed version 1 around that scene and a complete playable loop: build a bridge, lose the route, rescue the resident, plant a flower, and receive a gift.

We kept requirements, design, and implementation tasks in the root `.kiro` directory. These are the original Chinese development records. This English write-up explains the workflow and evidence; they have not been replaced with retroactively invented Kiro output:

- [V1 requirements](../.kiro/specs/v1/requirements.md), [design](../.kiro/specs/v1/design.md), and [tasks](../.kiro/specs/v1/tasks.md).
- [V2 requirements](../.kiro/specs/V2/requirements.md), [design](../.kiro/specs/V2/design.md), and [tasks](../.kiro/specs/V2/tasks.md).
- [Art requirements](../.kiro/specs/美术/requirements.md), [design](../.kiro/specs/美术/design.md), and [tasks](../.kiro/specs/美术/tasks.md).

The V2 specification explicitly describes which V1 requirements it changes. That made it possible to expand from one story into five wish types, autonomous activities, furniture, day/night behavior, and diaries while preserving the original delivery-and-rescue loop. Later implementation and art work continued from these checked-in specifications; this is not a claim that Kiro alone performed every subsequent step.

## Steering and architecture

The checked-in [product steering document](../.kiro/steering/product.md) points back to the original concept and keeps product decisions with the project owner. The specifications provide the detailed behavioral contracts.

The implementation separates a pure `WindowfolkCore` simulation from the macOS application. The core accepts window snapshots, time, and randomness, making navigation, physics, wishes, and persistence testable without opening desktop windows. The app handles real window geometry, transparent rendering, input, menus, and optional model connections.

## Property-based testing

We use `swift-property-based` alongside Swift Testing to check behavior over generated worlds, layouts, and timelines. Examples include navigation consistency, wish lifecycles, persistence, and privacy boundaries. The current validation run passed **754 tests in 178 suites**.

One useful testing lesson concerned wish timeout: dropping a wish must preserve the furniture collection, but an already-falling decoration must still respond to gravity during that same simulation step. The property now checks identities and types, and unchanged placement for resting furniture, without incorrectly freezing falling objects. This separates the requirement from an unrelated physical effect.

## Validation beyond the specification

On-device testing exercised real window movement, a bridge failure and ladder rescue, all five completed wish types, both chase endings, furniture placement and removal, day/night transitions, template diaries, and quit/restart persistence. The demo uses existing debug controls to trigger wishes and shorten flower growth; it does not modify the live world to manufacture outcomes.

The optional AI text features are disabled by default and were not called in the recorded demonstration. The checked-in specs, test suite, and [on-device report](validation/2026-11-20/report.md) are the evidence for this submission. We do not claim use of Kiro Crew, hooks, custom agents, powers, or MCP workflows that are not documented in this repository.
