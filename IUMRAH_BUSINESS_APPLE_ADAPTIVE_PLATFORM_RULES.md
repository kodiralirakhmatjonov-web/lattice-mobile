# iumrah Business — Apple Adaptive Platform Rules

Production layout contract for iPhone, iPad and Mac Catalyst.

## 1. Non-negotiable invariant: protect iPhone

The existing compact iPhone composition is the reference implementation. Large-screen work must not globally change phone spacing, card width, tab behavior, safe-area treatment, typography scale, or modal presentation.

Adaptive decisions are made from the **actual available pane width**, not from `UIDevice.current.userInterfaceIdiom` alone. A narrow iPad Split View / Stage Manager window may therefore use the compact composition, while a wide iPad or Mac uses workstation layouts.

## 2. Application shell

- **Compact**: existing bottom `TabView` plus Business drawer.
- **Regular / Wide iPad**: persistent `NavigationSplitView` product sidebar.
- **Mac Catalyst**: persistent native sidebar and resizable desktop window.
- The desktop detail pane is measured again with `BusinessAdaptivePaneHost`, so screens never assume that the full window width is available after the product sidebar.

Top-level keyboard navigation:

- `⌘1` Overview
- `⌘2` Bookings
- `⌘3` Chats
- `⌘4` Hotels
- `⌘5` Flights
- `⌘F` Client Archive
- `⇧⌘N` New Notification

## 3. Layout classes

The shared implementation lives in `Sources/Core/BusinessAdaptiveLayout.swift`.

- `compact`: horizontal compact size class or pane width below 720 pt.
- `regular`: 720–1023 pt.
- `wide`: 1024 pt and above on iPadOS.
- `desktop`: Mac Catalyst; child panes still decide whether there is enough width for a second internal split.

A second list/detail workspace is allowed only when the **workspace pane itself** is at least 980 pt wide. This avoids cramped three-column layouts when the product sidebar already consumes part of an iPad window.

## 4. Workspace behavior

### Bookings
Wide workspace: booking list on the left, selected booking detail on the right. Narrow workspace: push navigation.

### Chats
Wide workspace: conversations left, active thread right. Narrow workspace: push navigation.

### Employees and Client Archive
Wide workspace: searchable/selectable list left, employee/client detail right. Narrow workspace: existing navigation flow.

### Flights
Controls and results split only at workstation widths. Published feed remains full-width because its content is scan-oriented rather than inspector-oriented.

### Hotels, Ziyarats, eSIM, Payments
Use adaptive grids when the pane can sustain useful card widths. Never create narrow columns simply to fill horizontal space.

### Forms and detail pages
Use readable max widths. A Mac window should not turn a text form into a 1300-pt-wide line of controls.

## 5. Persistent-sidebar presentation rule

A destination opened from the permanent iPad/Mac product sidebar is not a phone modal. Phone-only `Close`/`x` affordances must be hidden in persistent-sidebar mode. Nested sheets and editors keep their dismiss controls.

## 6. Mac Catalyst

The Mac build uses the Mac Catalyst Mac idiom rather than a scaled iPad presentation. `project.yml` keeps iPhone/iPad device families for iOS and resolves the Mac SDK to the Mac device family. The Catalyst window has a 980 × 680 pt minimum working size.

Device/session registration must identify Catalyst as Mac (`platform = macos`, `osName = macOS`) and use the hardware model where available. Do not map a real Apple Silicon Mac's `arm64` architecture to “iPhone Simulator”.

## 7. QA matrix before release

Every material UI change must be checked in both light and dark appearance where supported and at these sizes:

- iPhone compact portrait, including the smallest supported production width.
- iPhone landscape for screens that allow it.
- iPad portrait and landscape.
- iPad Split View / Stage Manager at narrow and wide window sizes.
- Mac Catalyst at minimum 980 × 680.
- Mac Catalyst around 1280 × 800, 1440 × 900, and full screen.
- Pointer hover/context menus where present.
- Hardware keyboard top-level shortcuts.
- Dynamic Type at least through the common accessibility-adjacent sizes without clipping primary actions.

## 8. Release gates

The repository CI must compile both:

1. the universal iPhone/iPad target, and
2. the Mac Catalyst target.

Do not ship a large-screen layout change solely because Swift syntax parsing succeeds. Syntax parsing is only the local preflight; Xcode compilation and visual simulator/device QA remain release gates.
