# Crew Date Voting & Group-Text Share — Design

**Date:** 2026-04-12
**Status:** Approved for implementation planning

## Summary

Turn Grip It 'N Rip It from a single-organizer planner into a collaborative loop: the organizer picks the activity, then sends a group text with a link; each crew member taps the link and submits their availability as free text; the organizer hits "Lock it in" when ready, Claude picks a consensus date and builds the per-person plan, and the organizer re-shares the locked plan to the group text.

## Goals

- Collect date availability from every crew member through a shared link, not a single organizer decision.
- Accept loose input ("any Saturday after 1pm", "not the 25th", "4/18 or 4/25") — Claude reconciles it.
- Keep all share steps on native SMS (no paid SMS provider).
- Preserve the existing organizer wizard feel; add the fewest new screens needed.
- No user accounts, no auth. Plan URLs are unguessable.

## Non-goals

- Automated outbound SMS (no Twilio). Both texts are sent by the organizer's own phone.
- Multiple organizers, account system, or plan history across devices.
- Voting on the *activity* — organizer still picks that.
- Push notifications when new votes arrive — the organizer's waiting dashboard polls.

## End-to-end flow

### Organizer (in the app)

1. **Crew screen** — crew name + rows for each person with **name and phone**. Organizer is row 1. Phone is required.
2. **Location screen** — city, drive distance, **"When are YOU available?"** free-text box. This replaces today's date-picker and "suggest 3 dates" toggle; both are removed.
3. **Vibe screen** — unchanged.
4. **Results** — 3 activity options (unchanged). Picking one now routes to the new Share screen.
5. **Share screen (new).** Shows the picked activity pitch on top. Big "Send to group text" button opens the SMS composer pre-filled with every crew phone number and a message like:
   *"{Crew Name}: {Activity} in {City}. Weigh in on dates here: https://gripitnripit.app/?p={id}"*
   Below the button, the waiting dashboard: the crew roster with ✓ / — next to each name and each voter's raw availability text visible. Polls `GET /api/plan/:id` every 10s while the screen is active. A "Lock it in" button sits at the bottom, always enabled (organizer's own vote is seeded at create time).
6. **Final plan screen (new).** Shows the locked date, the one-sentence reasoning, and the per-person plan (reusing the existing recap renderer). Buttons: "Send plan to group text" (opens SMS with the locked date + meet-up line) and "Copy all plans" (existing).

### Crew member (voter flow)

1. Taps the link. Page loads with crew name header, the activity pitch card, and "who else is in" list.
2. Picks their own name from the roster dropdown. Names that have already voted show a ✓; tapping a voted name loads that voter's previous answer for editing.
3. Availability textbox with helper copy:
   > **When works for you?**
   > *A date, a few dates, or a slot that works — "4/18", "any Sat after 1pm", "weekends in May but not the 25th"*
4. Submit → thank-you screen: *"Locked in. {Organizer} will send the plan to the group text once everyone's weighed in."*
5. Revisiting the same link after the organizer locks shows the final plan (same rendering as organizer's final screen, minus the send button).

## Data model

One key per plan in Cloudflare KV. 30-day TTL.

```
plan:{id} = {
  id:            string,        // ~13-char base32, random 64-bit
  createdAt:     number,        // ms since epoch
  crewName:      string,
  crew:          [ { name: string, phone: string } ],  // row 0 = organizer
  city:          string,
  driveDistance: number,
  vibe:          { adventure: number, risk: number, cost: number },
  activity:      { name: string, blurb: string, ... },  // whatever the existing activity shape is
  votes:         [ { name: string, availability: string, at: number } ],
  locked:        boolean,
  finalDate:     string | null,   // YYYY-MM-DD
  finalReason:   string | null,   // one-sentence reasoning from consensus call
  finalPlan:     any | null       // whatever the existing per-person plan shape is
}
```

The organizer's own availability is written to `votes[0]` at create time so the dashboard shows them as voted immediately.

## API (sorted-api worker)

All endpoints are JSON-in, JSON-out. No auth; the plan ID in the URL is the capability.

- `POST /api/plan` — create. Body: `{ crewName, crew, city, driveDistance, vibe, activity, organizerAvailability }`. Returns `{ id, url }`.
- `GET /api/plan/:id` — read. Returns the plan object **with `crew[].phone` stripped** (voter page only sees names). Organizer dashboard uses this same endpoint.
- `POST /api/plan/:id/vote` — upsert a vote by name. Body: `{ name, availability }`. Rejected with 409 if `locked === true`.
- `POST /api/plan/:id/lock` — run consensus + build plan. Rejected with 409 if already locked *and* `finalPlan !== null`. If `locked` but plan-build previously failed (`finalPlan === null`), re-runs the plan-build call only.

## Lock-it-in: consensus & plan-build

Two Claude calls in sequence.

**Call 1 — Consensus picker.** Prompt (sketch):
> "Today's date is {today}. Here's a crew's availability for a day out. Pick one specific calendar date (YYYY-MM-DD) that maximizes attendance. If nothing aligns perfectly, pick the best compromise and say why in one sentence.
>
> Crew availability:
> - Mark: 'any Saturday after 1pm'
> - Dave: 'not 4/25, otherwise weekends work'
> - ...
>
> Return JSON: `{ date: 'YYYY-MM-DD', reasoning: '<one sentence>' }`"

**Call 2 — Plan builder.** The existing per-person plan prompt, with the locked date frozen in so logistics (drive time, what to bring, weather notes) are concrete.

Write order: consensus result (`finalDate`, `finalReason`) → plan builder result (`finalPlan`) → `locked: true`. This means a refresh mid-call shows "building…" cleanly, and a retry picks up from the right spot.

## Frontend architecture

**Single `index.html`** keeps both flows. On load, check `?p=XXXX`:
- No `p` → organizer wizard (existing screens).
- `p` present → fetch the plan, route to voter flow.

**Organizer wizard — concrete changes:**
- `s-crew`: add phone input to each row; phone is required to continue.
- `s-loc`: replace `<input type="date">` + `date-options` block with the free-text availability textbox and helper copy. Remove the `voteMode` variable and `toggleDateOptions()` function.
- `s-vibe`: unchanged.
- `s-results`: picking an activity now calls `POST /api/plan`, stashes the returned `id`, and routes to `s-share` (not the old `s-recap-load`).
- `s-share` (new): activity pitch, "Send to group text" button, waiting dashboard, "Lock it in" button.
- `s-final` (new): locked date + reasoning, per-person plan, "Send plan to group text" + existing "Copy all plans".

**Voter flow (new screens, `?p=XXXX` mode):**
- `v-vote`: crew name header, activity pitch card, "who else is in" list, name dropdown (with ✓ on voted names), availability textbox, Submit.
- `v-thanks`: confirmation copy.
- `v-final`: if the plan is already locked on load, show the locked plan (same rendering as `s-final`, minus the send button).

**SMS composition.** Build as `sms:+15551,+15552?&body=<encoded>`. This covers most modern iOS and Android builds. Show a **"Copy message"** fallback button next to both Send buttons — same content, works when the `sms:` prefill misbehaves.

**JS state.** Existing globals (`people`, `chosen`, `crewName`) remain. Add: `planId`, `availability` (organizer's own string), `phones[]` parallel to `people[]`. Waiting-dashboard polling uses `setInterval`, cleared when the screen goes inactive or `locked` flips true.

## Error handling & edge cases

- **Bad/expired plan ID on voter load** → friendly "This plan isn't available anymore" screen.
- **Duplicate vote (same name)** → upsert, not append. Voter can re-open the link and change their answer up until lock.
- **Organizer locks with only their own vote** → allowed by design. Option B from brainstorming.
- **Nobody's availability aligns** → consensus call still returns a date + reasoning explaining the compromise. Organizer sees the reasoning and can choose not to send.
- **Voter visits after lock** → voter page renders the final plan instead of the vote form.
- **Missing phone number on an organizer crew row** → blocked at `s-crew`, same error-badge pattern as the existing name-required check.
- **Claude returns malformed JSON on consensus** → retry once automatically, then surface error to organizer with a "Try again" button. No partial write.
- **Plan-build fails after consensus succeeded** → `finalDate`/`finalReason` are saved, `finalPlan` stays null. Reloading the final screen shows a "Finish building" button that re-runs just the plan-build call.
- **Organizer closes tab mid-lock** → next load detects `locked: true` + `finalPlan === null` and offers the same "Finish building" retry.

## Privacy

- Phone numbers are stored server-side but never returned by `GET /api/plan/:id`.
- Plan IDs are 64-bit random tokens (unguessable).
- KV entries auto-expire after 30 days.
- No accounts, no logins, no analytics on individual voter responses beyond what's in the plan blob.

## Testing & verification

- **Worker endpoints** — curl-driven smoke tests for each endpoint in order (create → get → vote → lock → get).
- **Consensus call** — seeded-input tests against three synthetic crews: "all flexible", "one hard conflict", "no overlap". Confirm the returned date and reasoning are sensible.
- **End-to-end** — manual, two real phones. Organizer on laptop, voter on phone. Cover: happy path, voter updates their answer, organizer locks with only 1 of 3 voted, voter opens link after lock.
- **SMS link prefill** — verify on both iOS and Android. If either fails to prefill, the Copy-message fallback must be reachable with one tap from the same screen.

## Out of scope (explicit)

- Twilio / outbound SMS from the server.
- Activity-option voting.
- Reminder pings before the day.
- Multi-organizer or editable-after-lock.
- Any form of user authentication.
