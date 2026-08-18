# Before you deploy this

Written for the case where an instructor is considering this for a real class. Take
these to whoever approves it at your institution.

**Consent and notice.** Every session opens with a notice listing exactly what is
captured and where it is saved, and the student must agree before anything starts;
declining exits without changing the machine. That is deliberately the first thing that
happens. You can turn it off (`REQUIRE_CONSENT` in the lockdown script), but recording
someone's camera and microphone without notice can be unlawful — several US states
require all-party consent for audio — so only do that where students have already been
told in writing, and where your institution has signed off.

**Get institutional review first.** Recording students' cameras, screens and audio is
covered at most universities by FERPA obligations, an IRB or privacy office, and often a
union or accessibility policy. Things they will ask that this tool does not answer for
you:

- Where do the recordings end up? The full-length video and audio always stay on the
  student's own machine — there is no upload of those, and no retention policy for
  them, so you would have to define how they're collected, who may watch them, and
  when they're deleted.
- In **proctored** mode there is additionally a server, and it holds more sensitive
  material than the videos do: a photograph of each student's ID card, a photograph
  of their face, and rolling thumbnails of their screen. That data lives in your
  Supabase project, and deciding where it may live, who can read it, and when it is
  purged is now your obligation rather than a hypothetical. `server/purge.py` does the
  deleting; nothing runs it for you. Note also that deletion has a mandatory order —
  files through the Storage API *first*, rows second — because a file whose session
  row is gone can no longer be deleted by anyone. See SETUP.md.
- Who can access them? The local files land on the Desktop, readable by the student
  and anyone else on that account. The uploaded material is readable by the student it
  belongs to and by the proctor who owns that exam, enforced by database policies —
  and by anyone holding your project's `service_role` key, which is why that key must
  never go near the app.
- What about students who can't comply — no webcam, a shared room, a disability
  accommodation, or reasonable objections to being filmed at home?
- What is the fallback when the recorder fails? It reports the failure and, by design,
  lets the session continue rather than blocking an exam.

**Be honest about the lockdown's strength.** It stops casual tab-switching. It does not
stop Force Quit, Task Manager, a reboot, a phone, or a second laptop. Anyone deciding
whether this is sufficient should know that before they rely on it.

**This has not been through a security review**, and the recordings are unencrypted on
disk.
