window.BENCHMARK_DATA = {
  "lastUpdate": 1765651960206,
  "repoUrl": "https://github.com/noxan/diskly",
  "entries": {
    "Benchmark": [
      {
        "commit": {
          "author": {
            "email": "richard@stromer.org",
            "name": "Richard",
            "username": "noxan"
          },
          "committer": {
            "email": "richard@stromer.org",
            "name": "Richard",
            "username": "noxan"
          },
          "distinct": true,
          "id": "5e61daa88822d3a18510be129fcd32942accd907",
          "message": "format output for benchmarks",
          "timestamp": "2025-12-13T19:41:53+01:00",
          "tree_id": "05dc6cf84f0645046c01a10ec59d3626d938f433",
          "url": "https://github.com/noxan/diskly/commit/5e61daa88822d3a18510be129fcd32942accd907"
        },
        "date": 1765651959736,
        "tool": "cargo",
        "benches": [
          {
            "name": "scanner/small_100_files_3_levels",
            "value": 354198,
            "range": "± 14227",
            "unit": "ns/iter"
          },
          {
            "name": "scanner/medium_1000_files_5_levels",
            "value": 2661904,
            "range": "± 50654",
            "unit": "ns/iter"
          },
          {
            "name": "scanner/large_10000_files_7_levels",
            "value": 7664698,
            "range": "± 155468",
            "unit": "ns/iter"
          },
          {
            "name": "scanner/wide_flat_5000_files",
            "value": 5813340,
            "range": "± 92507",
            "unit": "ns/iter"
          },
          {
            "name": "scanner/deep_narrow_100_levels",
            "value": 2927205,
            "range": "± 40474",
            "unit": "ns/iter"
          }
        ]
      }
    ]
  }
}