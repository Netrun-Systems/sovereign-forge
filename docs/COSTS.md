# Costs

**Figures dated 2026-11-23.** Every number below carries a source. Prices change, vary by
region, and go stale — re-check the linked pages before you quote any of this to anyone.
Where a figure could not be verified it says so rather than guessing.

## The short version

1. **A free vendor tier beats self-hosting on cash, always.** GitHub Free hosts unlimited
   private repositories at $0. Nothing in this kit is cheaper than $0. Self-hosting starts
   making sense when you need something Free withholds — on GitHub Free that is branch
   protection on private repos ("Repository rules" is public-repos-only on Free).
2. **Against a paid per-seat tier, the crossover is early on cash and late on time.**
   Cash-only, a forge beats GitHub Team at about 2–4 seats and beats Enterprise from 1 seat.
   Price your own hours at $50 and the forge only beats Team above roughly 52–54 seats.
3. **Per-seat pricing scales; a host does not.** That is the whole argument. At 200 seats
   Enterprise is $50,400/yr against a host in the hundreds.
4. **Operator time is the cost people omit, and it is usually the biggest one.**

## Seat scaling, annual, cash only

| Seats | GitHub Free | GitHub Team | GitHub Enterprise | Forge on Hetzner | Forge on Lightsail |
|---:|---:|---:|---:|---:|---:|
| 1 | $0 | $48 | $252 | $79.11 | $144.48 |
| 5 | $0 | $240 | $1,260 | $79.11 | $144.48 |
| 20 | $0 | $960 | $5,040 | $79.11 | $144.48 |
| 50 | $0 | $2,400 | $12,600 | $118.49 | $288.48 |
| 200 | $0 | $9,600 | **$50,400** | $216.94 | $528.48 |

Method: Team $4/user-mo × 12; Enterprise $21/user-mo × 12; no annual discount is published,
and a Team minimum seat count is unverified. Forge = (host + $0.04/mo backup) × 12. Host
sizing is an assumption — Forgejo's real resource floor is unverified. Hetzner CX23 at 1–20
seats, CX33 at 50, CX43 at 200; Lightsail $12 at 1–20, $24 at 50, $44 at 200.

**Cash crossover.** vs Team: 2 seats on Hetzner, 4 on Lightsail (at 3 seats Team is $0.48
cheaper). vs Enterprise: 1 seat either way.

## Seat scaling with operator time priced in

Assumed **4 h/month** of operator work at 1–20 seats (6 h at 50, 8 h at 200). The breakdown
is below. The hourly rates are illustrative, not anybody's real number.

| Seats | Team | Enterprise | Hetzner @ $0/h | @ $50/h | @ $100/h | Lightsail @ $0/h | @ $50/h | @ $100/h |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | $48 | $252 | $79 | $2,479 | $4,879 | $144 | $2,544 | $4,944 |
| 5 | $240 | $1,260 | $79 | $2,479 | $4,879 | $144 | $2,544 | $4,944 |
| 20 | $960 | $5,040 | $79 | $2,479 | $4,879 | $144 | $2,544 | $4,944 |
| 50 | $2,400 | $12,600 | $118 | $3,718 | $7,318 | $288 | $3,888 | $7,488 |
| 200 | $9,600 | $50,400 | $217 | $5,017 | $9,817 | $528 | $5,328 | $10,128 |

**Loaded crossover at a flat 4 h/mo.** At $50/h a forge beats Team from 52 seats (Hetzner)
or 54 (Lightsail), and beats Enterprise from 10–11 seats. At $100/h, 102–104 seats against
Team and 20 against Enterprise. If hours scale with team size as above, then **at $100/h and
200 seats Team ($9,600) is still cheaper than the forge ($9,817–$10,128).**

Read that last line before you migrate. Self-hosting wins when your hours are cheap or
already sunk. If you are buying the hours, do the arithmetic for your own rate.

### The 4 hours

| Task | h/mo |
|---|---:|
| Patching and version upgrades, including reading release and security notes | 1.5 |
| Monitoring and alert triage | 1.0 |
| Backup verification, with a full restore drill amortised (≈3 h/quarter) | 1.0 |
| User, token and runner administration | 0.5 |
| **Total** | **4.0** |

Not in that table: the one-time migration of repos, webhooks, CI wiring and SSO. These hours
are an estimate, not a measurement.

## CI: per-run versus a host you own

Workload: a 12-minute build.

| Runs/mo | Minutes | GH-hosted, Free | GH-hosted, Team | GH-hosted, Enterprise | Managed builder @ ~$0.12/run | Self-hosted runner |
|---:|---:|---:|---:|---:|---:|---|
| 100 | 1,200 | $0 (within 2,000) | $0 (within 3,000) | $0 | $12.00 | host cost, any volume |
| 500 | 6,000 | $24.00 | $18.00 | $0 (within 50,000) | $60.00 | same |
| 2,000 | 24,000 | $132.00 | $126.00 | $0 | $240.00 | same |

GitHub-hosted Linux 2-core x64 is $0.006/min. Included minutes run out at 166 runs/mo (Free),
250 (Team) and 4,166 (Enterprise) for a 12-minute build. The Team and Enterprise columns
exclude seat cost. Whether the 1× Linux multiplier applies to included minutes is unverified,
as is any self-hosted-runner platform charge — GitHub's runner pricing page does not show one.

**Runner break-even against a managed builder at $0.12/run:** Hetzner CX23 55 runs/mo, CX33
82, Lightsail $24 200, Lightsail $44 367. Add a single operator hour per month at $50 and
CX33 moves from 82 to **499 runs/mo**. Against GitHub-hosted minutes beyond the free
allowance ($0.072/run), CX33 breaks even at 137 runs/mo and Lightsail $44 at 611.

Size the runner for your build, not for your forge. A build that was OOM-killed on a
managed builder will not fit a 2 GB VM either; the 8 GB tiers are the honest starting point,
which is why this kit defaults Jenkins to 4 GB and tells you to measure.

One runner offers 43,800 min/mo. 24,000 of those is 55% utilisation, which means queueing in
bursts — a real cost that does not appear on any price sheet.

## Price inputs

| Input | Value | Source |
|---|---|---|
| GitHub Team / Enterprise | $4 / $21 per user-month | github.com/pricing |
| Actions minutes included | Free 2,000 / Team 3,000 / Enterprise 50,000 | github.com/pricing |
| Private-repo branch protection | Free: public repos only. Team, Enterprise: included | github.com/pricing |
| SAML SSO | Enterprise only | github.com/pricing |
| GitHub-hosted Linux 2-core x64 | $0.006/min | docs.github.com Actions runner pricing |
| Lightsail Linux bundles | $5: 0.5 GB/20 GB/1 TB · $12: 2 GB/60 GB/3 TB · $24: 4 GB/80 GB/4 TB · $44: 8 GB/160 GB/5 TB | aws.amazon.com/lightsail/pricing |
| Lightsail block storage / snapshots | $0.10 / $0.05 per GB-mo | aws.amazon.com/lightsail/pricing |
| S3 us-east-1 Standard | $0.023/GB-mo (first 50 TB) | AWS price list, us-east-1 |
| S3 us-east-1 Glacier Instant Retrieval | $0.004/GB-mo; retrieval $0.03/GB | AWS price list |
| S3 requests, Standard | PUT/COPY/POST/LIST $0.005/1,000; GET $0.004/10,000 | AWS price list |
| S3 requests, Glacier IR | PUT $0.02/1,000; GET $0.01/10,000 | AWS price list |
| AWS transfer out to internet | $0.09/GB, first 10 TB, beyond the free tier | AWS price list |
| Backblaze B2 | $6.95/TB-mo; egress free to 3× average stored, then $0.01/GB | backblaze.com pricing |
| Azure VM, Linux PAYG, East US | B2s $0.0416/hr = $30.37/mo · B1ms $0.0207/hr = $15.11/mo | Azure Retail Prices API |
| Azure Blob, East US | Cool $0.0152/GB-mo · Archive $0.00099/GB-mo · Hot $0.0208/GB-mo | Azure Retail Prices API |
| Azure internet egress | first 100 GB $0, then $0.08/GB | Azure Retail Prices API |
| Hetzner CX23 (2 vCPU/4 GB/40 GB/20 TB) | EUR 5.99/mo excl. VAT = $6.55 | hetzner.com/cloud/cost-optimized |
| Hetzner CX33 (4/8/80/20 TB) | EUR 8.99 = $9.83 | hetzner.com/cloud/cost-optimized |
| Hetzner CX43 (8/16/160/20 TB) | EUR 16.49 = $18.04 | hetzner.com/cloud/cost-optimized |
| Hetzner CPX11, US regions only (2/2/40/1 TB) | EUR 17.99 = $19.68 | hetzner.com/cloud/regular-performance |
| EUR→USD | 1.0939 | frankfurter.dev, 2026-11-23 |

Azure monthly figures use a 730-hour month (8,760/12), which is a convention, not a billing
rule. **Hetzner caveats:** every plan read as "currently unavailable" when the page was
fetched; the cheap CX line is EU-only, and the US equivalent (CPX11) is nearly 3× CX23 with
a twentieth of the traffic allowance; the traffic-overage unit ("EUR 1.00 per hour" per
additional TB) could not be confirmed, so no overage figure is used anywhere above.

## Three architectures, ranked by monthly cash

| Rank | Architecture | Monthly cash | What it costs you instead |
|---:|---|---:|---|
| 1 | Vendor free tier + off-site backup | ~$0.04 (~$0.02 on Glacier IR) | Loses private-repo branch protection. Depends on a vendor whose outages are not yours to fix. |
| 2 | Hardware you already own + cheap object storage | ~$0.04 (~$0.02 on Glacier IR) | Operator hours. Residential-link risk if that is your uplink, softened by Git itself: a clone works offline and catches up when the link returns. Hardware amortisation and power, both unquantified. |
| 3 | One small cloud VM + object storage | Hetzner CX23 $6.59 · Lightsail $12.04 · Azure B1ms ~$15.20 | Real uptime and a public IP, for real money. |

Backup storage for a 5 GB dataset is noise in every option: S3 Standard $0.115/mo, S3
Glacier IR $0.02, B2 $0.035, Azure Cool $0.076, Azure Archive $0.005.

**A full restore is not free, and at scale the vendor choice flips.** Restoring 2.5 GB from
S3 costs about $0.30 ($0.03/GB retrieval + $0.09/GB egress). Per TB per year, S3 Glacier IR
is $48 of storage plus $120 for one full restore = $168; B2 is $83.40 with that restore free
inside the 3× allowance. If you test restores — and this kit tells you to — B2 wins above
roughly a terabyte.

**$5/mo is not a real floor on AWS.** The $5 Lightsail bundle is 0.5 GB of RAM. We have not
tried a forge on it, but with Forgejo, a database and a runner we do not expect it to be usable. $12 is the
number we would plan on. If you are comparing a migration against "about
five dollars," you are comparing against a tier that cannot do the job.

## Where the vendor service is genuinely cheaper

Pay per run or per gigabyte when:

1. **Volume is low or bursty** — below the break-even above, paying per run beats paying for
   an idle host.
2. **Someone else's money is covering it** — credits make marginal cash $0, and that is
   always time-limited.
3. **Operator hours are your scarce input** — one hour a month at $50 moves a CI break-even
   from 82 runs to 499.
4. **The data is cold and rarely read** — $0.004/GB-mo, and you never patch it.
5. **You need clean, elastic, isolated builds** without owning peak capacity.

It stops being cheaper when volume is high and steady, when the credits end, when egress is
large, when the price scales with a headcount you do not need, or when you already own idle
capacity. And a price sheet never shows vendor risk: a CI system that stops creating runs
and cannot be fixed from your side is a cost too.

## Not confirmed

Do not quote these as facts:

- S3 Glacier Deep Archive's storage rate per GB-month (retrieval is confirmed at $0.02
  standard / $0.0025 bulk).
- The size of the AWS free data-transfer-out tier.
- Any GitHub self-hosted-runner platform charge, the Linux multiplier on included minutes,
  GitHub Team's minimum seat count, and whether an annual discount exists.
- Hetzner availability, US-region CX pricing, the traffic-overage unit, and VAT or card FX
  treatment for a non-EU buyer.
- RAM for Azure B2s and B1ms (not fetched; prices are list PAYG).
- Forgejo's and Jenkins's minimum and recommended resources; whether Forgejo's SSO and audit
  logging are equivalent to GitHub Enterprise's; CVE counts and patch cadence for either.
- Lightsail 2 GB and 4 GB suitability for a forge — an assumption, not a benchmark.
- Lightsail snapshot sizes.
- The operator hours and hourly rates above, which are illustrative throughout.

## What drives the bill in this kit

| Driver | Where it comes from | Knob |
|---|---|---|
| The VM | AWS: Lightsail bundle (`bundle_id`). Azure: VM size (`vm_size`) plus OS disk (`os_disk_gb`) and the public IP | CI path decides the default: 2 GB for Forgejo Actions, 4 GB for Jenkins |
| Data transfer | AWS: included in the Lightsail bundle up to its allowance. Azure: billed egress | Clone and CI traffic |
| Backup storage | Gigabytes held in `daily/` (newest `remote_keep_daily` sets, each full) plus `weekly/` for `weekly_expire_days` | `remote_keep_daily`, `weekly_transition_days`, `weekly_expire_days` |
| Storage class | Glacier Instant Retrieval (AWS), Cool and Archive (Azure) for `weekly/` | Tiering days. Both carry minimum storage durations and retrieval charges |
| Versions | Deleted and overwritten backups are kept for `noncurrent_expire_days` | That variable. Each retained version is stored and billed |
| Requests and retrieval | Uploads, read-back verification, restore drills | `VERIFY_FULL=1` re-downloads every object and adds transfer |
| Static IP | AWS: free while attached. Azure: billed Standard public IP | |
| Snapshots | Optional cloud snapshots you take yourself | Not created by the kit |
| Operator time | Upgrades, drills, incidents | Not a cloud line item, and the cost people forget |
