# scans/

Trivy + Grype reports.

- `baseline-trivy.txt`, `baseline-grype.txt` — `nginx:1.25-bookworm` upstream.
- `fixed-trivy.txt`, `fixed-grype.txt` — this repo's image.
- `diff-*.txt` — readable diff of fixed vs baseline.

Reminder: scanners match by package name + upstream version, so backported
fixes will still show up here. The honest signal for backports is the VEX
attestation, not the scanner output.
