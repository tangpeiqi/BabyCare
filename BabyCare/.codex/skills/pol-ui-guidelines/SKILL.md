---
name: pol-ui-guidelines
description: Use when creating or modifying SwiftUI UI in the BabyTracker PoL app. Applies the project's approved typography roles, color usage, and default container styling so new and updated screens stay visually aligned.
---

# PoL UI Guidelines

Use this skill for UI work in the PoL app. Follow these rules when creating or modifying views, cards, controls, and screen layouts.

## Core rules

- Reuse the approved text roles instead of introducing one-off font sizes.
- Reuse the approved app colors instead of inventing new nearby shades.
- Default top-level containers and cards use a `24pt` corner radius.
- Keep navigation titles native.
- Keep section headers native where the app already uses them, including Settings section headers and Activities day/date group headers.
- When a screen already has an established pattern, preserve it unless the task explicitly asks for a redesign.

## Typography roles

Use these roles consistently:

- `body`
  Use for default readable app copy.
  Examples: summary labels, elapsed values, empty states, status rows, tooltip text, camera row primary/status text, general form row text.

- `bodyEmphasis`
  Use for important labels and primary action text inside a screen.
  Examples: activity card title/value, diagnostic navigation labels, custom button titles, permission CTA, debug event names.

- `supporting`
  Use for secondary or supporting information.
  Examples: timestamps, rationale text, confidence text, swipe action labels, badges, helper units like `h`/`m`/`d`, graph axis labels, secondary values.

- `micro`
  Use only for very small utility labels.
  Current approved uses: shared bottom tab labels and summary graph meridiem labels (`AM` / `PM`).
  Do not expand this role casually.

- Native system titles
  Use native navigation titles for top-level screens.

- Native system section headers
  Use for Settings section headers and Activities date group headers.

When choosing between roles, default to `body`. Only step up to `bodyEmphasis` when the text is the main action or the main semantic focus of the container.

## Color usage

Use these colors by meaning:

- `#7D2680`
  Feeding event color.

- `#8C7805`
  Diaper event color.

- `#05788C`
  Sleep event color.

- `#EE5A5A`
  Streaming, live capture, destructive-live attention, and active recording emphasis.

- `#004058`
  Default button color and default strong action color.

- `#888888`
  Secondary text color.

- `#E1E1E1`
  Default stroke, border, and divider color.

- `#FFFFFF`
  Primary card/container surface.

- `#000000`
  Primary text color when no semantic accent is needed.

Use semantic event colors only when the content is actually about that event type. Use `#004058` for neutral actions instead of reusing event colors.

## Container styling

- Default top-level cards and containers use `24pt` corner radius.
- Use white surfaces with the default `#E1E1E1` stroke for standard cards unless the design already establishes a different treatment.
- Only use a different radius when matching an already-established special control.

## Implementation guidance

- Prefer semantic helpers or shared style wrappers over repeated raw `.font(.system(...))` and repeated raw color literals.
- If a UI change introduces a new text element, Ask for approval before map it to one of the approved roles.
- If a UI change introduces a new color, first check whether one of the approved semantic colors already fits.
- If you need to break these rules for a specific design reason, keep the exception local and explain it in your response.
