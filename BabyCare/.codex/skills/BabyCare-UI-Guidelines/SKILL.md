---
name: BabyCare-UI-Guidelines
description: Use when creating or modifying SwiftUI UI in the BabyCare app. Applies the project's approved typography roles, color usage, and default container styling so new and updated screens stay visually aligned.
---

# BabyCare UI Guidelines

Use this skill for UI work in the BabyCare app. Follow these rules when creating or modifying views, cards, controls, and screen layouts.

## Core rules

- Reuse the approved text roles instead of introducing one-off font sizes.
- Reuse the approved app colors instead of inventing new nearby shades.
- Preserve the established BabyCare padding rhythm when adding or modifying containers and controls.
- Default top-level containers and cards use a `24pt` corner radius.
- Keep navigation titles native.
- Keep section headers native where the app already uses them, including Settings section headers and Activities day/date group headers.
- When a screen already has an established pattern, preserve it unless the task explicitly asks for a redesign.

## Typography roles

Use these roles consistently:

- `body`
  System `16pt` regular.
  Use for default non-interactive body text.
  Examples: summary labels, elapsed values, empty states, status rows, tooltip text, camera row primary/status text, general form row text.

- `bodyBold`
  System `16pt` semibold.
  Use for interactive elements.
  Examples: buttons, clickable list items, diagnostic navigation labels, custom button titles, permission CTA.

- `emphasis`
  System `36pt` bold.
  Use for important data that the app wants to highlight. Keep this content short and concise, such as a few numbers.
  Examples: high-priority summary values, current measurement values, short activity totals.

- `supporting`
  System `12pt` regular.
  Use for secondary or supporting information.
  Examples: timestamps, rationale text, confidence text, condition explanations, secondary values.

- `micro`
  System `10pt` medium.
  Use only for very small utility labels.
  Current approved uses: nav tab names, measurements like time markers, and summary graph meridiem labels (`AM` / `PM`).
  Limit the use of this role and use it cautiously.

- Native system titles
  Use native navigation titles for top-level screens.

- Native system section headers
  Use for Settings section headers and Activities date group headers.

When choosing between roles, default to `body`. Use `bodyBold` for interactive text, `emphasis` only for short highlighted data, and `supporting` or `micro` for lower-priority context.

## Color usage

Use these colors by meaning:

- `#00BA6C`
  Diaper event color. Use on diaper-related content.

- `#4992FF`
  Sleeping event color. Use on sleeping-related content.

- `#AF5EFF`
  Feeding event color. Use on feeding-related content.

- `#EE5A5A`
  Recording color. Use on the button for starting and stopping recording.

- `#351600`
  Default text color. Use on most text by default.

- `#72675C`
  Secondary text color. Use on `supporting` and `micro` typography.

- `#E35F00`
  Default CTA color. Use on registration and camera permission buttons.

- `#F2E5DA`
  Default non-interactive color. Use on card strokes and backgrounds for non-interactive elements.

- `#FFEDDE`
  `SkinLight` background color.

- `#FCE0D0`
  `SkinNatural` background color.

- `#FFE2DE`
  `SkinRed` background color.

- `#FFE5F1`
  `SkinPink` background color.

Use semantic event colors only when the content is actually about that event type. Use `#E35F00` for neutral registration and camera permission CTAs instead of reusing event colors.

## Container styling

- Preserve established screen, card, row, and control padding patterns when extending existing UI.
- Default top-level cards and containers use `24pt` corner radius.
- Use BabyCare background colors for app surfaces and `#F2E5DA` for standard non-interactive card strokes and backgrounds unless the design already establishes a different treatment.
- Only use a different radius when matching an already-established special control.

## Implementation guidance

- Prefer semantic helpers or shared style wrappers over repeated raw `.font(.system(...))` and repeated raw color literals.
- If a UI change introduces a new text element, ask for approval before mapping it to one of the approved roles.
- If a UI change introduces a new color, first check whether one of the approved semantic colors already fits.
- If you need to break these rules for a specific design reason, keep the exception local and explain it in your response.
