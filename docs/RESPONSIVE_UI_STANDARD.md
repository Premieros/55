# Responsive UI Standard

This standard is mandatory for all user-facing Premier POS/ERP screens.

## Supported form factors

- Compact phone: 320–389 px width.
- Standard phone: 390–479 px width.
- Large phone / small tablet: 480–767 px width.
- Tablet portrait: 768–1023 px width.
- Tablet landscape / small laptop: 1024–1279 px width.
- Desktop: 1280–1919 px width.
- Large desktop / POS display: 1920 px and above.

Both Arabic RTL and English LTR must work at every breakpoint.

## Global rules

1. No page-level horizontal overflow. Wide content must scroll inside its own container.
2. Touch targets on phones/tablets should be at least 44x44 CSS pixels where practical.
3. Fixed headers, drawers, modals and bottom actions must respect dynamic viewport height (`dvh`) and device safe areas.
4. The desktop sidebar is persistent; below the desktop breakpoint it becomes a drawer and must not reduce the content width.
5. Tables keep meaningful column widths and use contained horizontal scrolling on narrow screens instead of squeezing values into unreadable cells.
6. Shared modals become full-width bottom sheets on phones, centered dialogs on tablets/desktops, with scrollable bodies and safe-area bottom padding.
7. Dense toolbars may hide secondary labels/actions at narrower widths, but required actions must remain reachable.
8. POS primary actions must remain touch-friendly and visible without requiring browser zoom.
9. Filters and form grids collapse to one column on phones, two columns on tablets where space allows, and multi-column layouts on desktop.
10. No behavior, permission, route, inventory logic or financial logic may depend on a visual breakpoint.

## Required browser checks

Responsive browser smoke must cover at least:

- 360x800 phone portrait.
- 430x932 large phone portrait.
- 768x1024 tablet portrait.
- 1024x768 tablet landscape.
- 1366x768 laptop.
- 1920x1080 desktop/POS monitor.

For each viewport verify:

- no document-level horizontal overflow;
- App Shell/header remains usable;
- mobile sidebar can open/close where applicable;
- dialogs stay within the viewport and their body scrolls;
- primary forms/buttons are reachable;
- tables scroll inside their container;
- Arabic RTL keeps sidebar/drawers and logical start/end alignment correct;
- POS product browser, cart, payment, shift and KDS entry points remain usable.

## POS-specific layout

Phone:
- catalog and current order should use stacked or switchable panels;
- secondary counters collapse into menus/badges;
- checkout and configuration dialogs use bottom-sheet behavior.

Tablet:
- prefer catalog + order side-by-side when width allows;
- keep large touch targets for restaurant operation;
- avoid desktop-only hover interactions.

Desktop/POS display:
- use persistent operational panels and counters;
- preserve maximum product visibility without reducing touch targets excessively.

## Acceptance rule

A UI change is not complete if it passes only at the developer's desktop viewport. New shared components or major pages must be checked against the responsive viewport matrix before being considered release-ready.
