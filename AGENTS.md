# Project Agent Instructions

## UI change acceptance

- Any change that affects the user-facing UI is not complete until the implementing agent has run the updated interface in the relevant target runtime, captured the affected states, and inspected the screenshots for UX problems.
- Screenshots are transient inspection inputs, not required task artifacts or deliverables. They need not be committed, retained, uploaded, attached, or included in a pull request or final response unless the user explicitly requests publication.
- A pull request, commit, or final response having no attached screenshots is never a review finding by itself. Review the reported UX inspection result and other runtime evidence instead.
- Use the actual built application for visual inspection. A mock, fixture, source inspection, or static rendering does not replace screenshots from the target runtime.
- Keep credentials and other sensitive or user-specific data out of screenshots and retained artifacts.
- If the implementing agent cannot capture and inspect the affected UI, report the exact blocker and state that UX inspection remains incomplete.
