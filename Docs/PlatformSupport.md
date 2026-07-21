# Platform support policy

This file describes the publication rule, not a claim that every listed network has been implemented.

| Platform | Release requirement | Production exposure rule |
| --- | --- | --- |
| TikTok | Required | `passing` live contract only |
| Instagram | Required | `passing` live contract only |
| X / Twitter | Required | `passing` live contract only |
| Pinterest | Required | `passing` live contract only |
| Snapchat public links | Required | `passing` live contract only |
| Kick | Required | `passing` live contract only |
| Threads | Required | `passing` live contract only |
| Tumblr | Required | `passing` live contract only |
| Imgur | Required | `passing` live contract only |
| YouTube | Conditional | Hidden unless it independently passes |
| Direct public media | Supported separately | Deterministic direct-media tests plus integrity validation |

The machine-generated current matrix lives at `Artifacts/PlatformSupport.md`, emitted from `Artifacts/PlatformSupportReport.json` by the live `PlatformContractTests` suite. Its status and evidence override this policy table. A user interface must derive capability exposure from the generated registry, not from an independently hard-coded marketing list or logo set.

Live tests run nightly and on the release workflow. They use only public/authorized fixtures; resolver logs are redacted before artifact upload. A platform that becomes blocked, fails, changes behavior, omits expected ordered media, or returns unusable media is not release-ready.
