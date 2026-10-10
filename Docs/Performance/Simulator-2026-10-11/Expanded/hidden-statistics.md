| Interval | Samples | Median ms | p95 ms | Max ms |
|---|---:|---:|---:|---:|
| CompositionRewrite | 86 | 0.0867 | 0.2513 | 1.0787 |
| CorrectionPreparation | 1 | 111.0041 | 111.0041 | 111.0041 |
| DeleteHandling | 8 | 0.0798 | 2.0684 | 2.0684 |
| EnglishModelPreparation | 1 | 1.0820 | 1.0820 | 1.0820 |
| HitGeometry | 1 | 2.6724 | 2.6724 | 2.6724 |
| HostDelete | 76 | 0.0288 | 0.0504 | 0.1898 |
| HostInsert | 96 | 0.0259 | 0.0427 | 1.2451 |
| HostReadBefore | 202 | 0.0054 | 0.0099 | 0.4298 |
| HostReadSelection | 34 | 0.0024 | 0.0051 | 0.0166 |
| KeyHandling | 137 | 0.3045 | 1.9740 | 5.3330 |
| SinhalaPersistence | 2 | 310.9867 | 595.8029 | 595.8029 |
| WorkerQueueDelay | 103 | 0.0296 | 0.0504 | 0.4840 |
| KeyHandling excluding nested host calls | 137 | 0.2644 | 1.9157 | 3.9628 |
| KeyHandling (delete tap) | 8 | 0.0899 | 0.6048 | 0.6048 |
| KeyHandling (letter tap) | 103 | 0.2985 | 0.5968 | 5.3330 |
| KeyHandling (space tap) | 26 | 0.3802 | 3.8973 | 4.0523 |
Excluded unmatched starts: {'mode=%{public}ld': 103}
Excluded unmatched ends: {'': 103}
