# Emerg-ant ladder policy versions

| Policy version | Policy-version ID | Uploaded (UTC) | Change and mechanism | Runtime | Validation |
| --- | --- | --- | --- | --- | --- |
| `emerg-ant-baseline:v1` | `2427bb65-7eb4-41bb-8382-a7bb9226e07d` | 2026-08-20T14:44:35.547523Z | Seed the restored Emerg-ant ladder with the checked-in pre-NAnts baseline controller. | Image `sha256:8bf13e418ddabef67c17886f6045b6ea16d7f25ae62a9da737d20d6191cc49b0`; `linux/amd64`; run `/bin/baseline`; no secrets. | `placed` — active competing membership; exact image and run passed all five hosted smoke episodes for certified `emerg-ant:0.6.1`. |
| `emerg-ant-rival:v1` | `004de909-4b07-44a0-b2bd-240874aae4bc` | 2026-08-20T14:45:41.652226Z | Add a second policy identity from the same certified baseline image so the new ladder can schedule competitive rounds immediately. | Image `sha256:8bf13e418ddabef67c17886f6045b6ea16d7f25ae62a9da737d20d6191cc49b0`; `linux/amd64`; run `/bin/baseline`; no secrets. | `placed` — competing champion; verified in a running hosted two-entrant round. |
| `emerg-ant-rival-colony:v1` | `6fd21bca-8e3a-422c-88d3-816942e85e54` | 2026-08-20T14:58Z | Put the rival seed under a second player identity so it remains a distinct ladder champion and round entrant. | Image `sha256:8bf13e418ddabef67c17886f6045b6ea16d7f25ae62a9da737d20d6191cc49b0`; `linux/amd64`; run `/bin/baseline`; no secrets. | `placed` — competing champion; verified in a running hosted two-entrant round. |

## Submission decision records

### 2026-08-20 — Seed the Emerg-ant ladder

- League: `league_485b7b0a-5a52-4254-9b2b-1e10b9596941` (`Emerg-ant`).
- Initial submissions: `emerg-ant-baseline:v1` as `sub_1b5a3b77-e6fe-4008-a33c-3d2aa6b090d1`; `emerg-ant-rival:v1` as `sub_839f5083-562c-4d0a-afcf-131f305c4678`. Both were rejected because the newly created platform league did not yet have a division.
- Successful placements after enabling the `Competition` division and ladder: `emerg-ant-baseline:v1` as `sub_1f0d5985-d1e3-42e6-b1ed-05db0973f3b2`, `emerg-ant-rival:v1` as `sub_9ea8dbc5-cb95-4ecc-94e2-9006e92a2742`, and second-player champion `emerg-ant-rival-colony:v1` as `sub_94421439-b55e-477e-9534-3808c13e59f6`.
- Evidence: all three policy versions resolve to the exact `linux/amd64` image and `/bin/baseline` run used by certified Coworld `emerg-ant:0.6.1`; all five hosted smoke episodes passed and the registered policy attributes were verified before submission. These are intentionally equivalent seed competitors, not an A/B improvement claim.
- Human go-ahead: “setup https://softmax.com/emerg-ant — Ensure we have atleast 2 player policies submitted so league rounds are playing via the ladder”.
- Auto-champion: `always`. `emerg-ant-rival:v1` is the champion for player `ply_630a768f-d623-44b2-80fa-36968d6fa75a`; `emerg-ant-rival-colony:v1` is the champion for player `ply_cec02b42-a653-4253-be4b-602ba5acacc4`.
- Live ladder proof: round `round_cf9bf1c2-b7f1-4522-9942-9a2f0dbec3bc` scheduled both champion policy versions; episode request `ereq_3b5dba77-e487-4a0a-b376-ba27c422ddaa` entered `running` with all 16 seats filled at 2026-08-20T15:00:55Z.
- Rollback: retire memberships `lpm_808a2c04-16d4-4f1f-a499-db35516cd927`, `lpm_69bca027-820f-46a1-aebf-d4c47b21b82c`, and `lpm_9f43e091-4082-4b12-b10d-93e68587e8f5` with `coworld retire-membership`; there is no prior Emerg-ant ladder membership to restore.
