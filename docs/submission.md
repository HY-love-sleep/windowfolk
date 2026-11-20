# Windowfolk — Kiroween 2026

## Project name

Windowfolk

## Elevator pitch

A little civilization between your windows. Move real macOS windows, build bridges, and help a cat and hamster turn small wishes into a living desktop world.

## Inspiration

Early desktop pets made computers feel inhabited. We wanted to bring that playful companionship back, with a new reason to interact: your actual window layout determines what the residents can do. A gap between two work windows becomes a canyon; a small bridge can make a gift delivery possible.

Windowfolk enters **Resurrection** by reimagining the desktop companions of the early internet as an environment-driven miniature world.

## What it does

Two residents, a silver cat and a golden hamster, live on application-window ledges and the desktop floor. They wander, visit neighbors, and express five kinds of wishes: deliver flowers, find a chair, sleep by a lamp, explore another window, or play chase.

You help by moving windows and dragging planks, ladders, and unlocked furniture out of a toolbox. A resident can carry a flowerpot across a bridge, hang and fall when the route breaks, climb a rescue ladder, plant a flower, and receive fruit after it blooms. Furniture creates places to sit and sleep. Chases can finish with a catch or an escape. Event-based diaries record what happened, and the world survives quitting and reopening the app.

Optional LLM diaries and short resident thoughts are available with your own compatible service. They are disabled by default. The core game and template diaries work without an API key.

## How we built it

We developed the first playable version with Kiro using requirements, design documents, implementation tasks, and property-based tests. The root `.kiro` directory retains the V1, V2, and art specifications plus product steering. Later work continued from those specifications.

The implementation uses Swift 6, AppKit, SpriteKit, SwiftUI, and Core Graphics. A pure core simulation accepts window snapshots, time, and randomness; the application layer reads real window geometry and renders a transparent world above the desktop. This keeps physics, navigation, wish lifecycles, and persistence testable without opening application windows.

Our [Kiro write-up](https://github.com/HY-love-sleep/windowfolk/blob/main/docs/kiro-usage.md) explains the workflow and links the checked-in evidence. The 45 game PNGs were created for this project with an image-generation and asset-processing workflow. Standard Apple frameworks and the MIT-licensed swift-property-based library are the main pre-existing dependencies; reference desktop-pet projects were not imported as game code or art.

## Challenges we ran into

Real application windows are moving terrain. When a window moves, disappears, or becomes occluded, the simulation must update support and reachability without leaving residents attached to nonexistent roads. Bridges, hanging, falling, ladders, and furniture all need to agree about the same geometry.

Tests also needed to distinguish independent effects. For example, ending a timed-out wish must preserve furniture identities and types, while furniture already falling must still move under gravity during the same step. Tightening that property made the test match the behavior we intended.

## Accomplishments

We demonstrated all five completed wish types on a real Mac, including bridge failure and rescue, both chase outcomes, chair placement and removal, lamp sleep and daylight waking, and diary generation. A quit/restart check preserved all 17 demo object IDs, both residents, and furniture unlocks. The submission test run passed 754 tests across 178 suites.

## What we learned

A small, concrete story is a useful starting point for an open-ended simulation. Specifying observable behavior before implementation made it easier to grow that story into a broader toy without losing the original loop. Property-based tests helped describe world invariants, while hands-on desktop testing checked the parts that simulated window snapshots cannot prove.

## What's next

Improve animation continuity, add English interface text, and broaden compatibility testing for fullscreen, sleep/wake, and more desktop layouts. Further activities should add small, visible changes to the world while preserving its calm, optional nature.

## Built with

Swift, AppKit, SpriteKit, SwiftUI, Core Graphics, Swift Testing, swift-property-based, Kiro.

## Links and judge instructions

- Source: https://github.com/HY-love-sleep/windowfolk
- Working application: https://github.com/HY-love-sleep/windowfolk/releases/latest
- English installation and testing guide: https://github.com/HY-love-sleep/windowfolk/blob/main/docs/README.en.md
- Kiro usage: https://github.com/HY-love-sleep/windowfolk/blob/main/docs/kiro-usage.md
- License: MIT.
- Platform: macOS 14+, primary display, Apple Silicon and Intel.
- No account or API key is required for the core experience.
- The interface currently uses Chinese; the English guide translates the relevant menus.
- The demonstration is segmented and uses existing debug controls for wishes, time of day, and flower growth. Speed changes and skipped waits are labeled. Optional AI generation is not enabled in the video.
