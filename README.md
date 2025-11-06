dnsBench.ps1

A small PowerShell script to benchmark:
- DNS resolver speed to a specific host
- HTTPS end-to-end timings (HTTP/2) and HTTP/3 (if supported by curl)
- Packet loss and jitter via ICMP
- Optional upload throughput test (effective upload time for a given file size)

Usage

Open PowerShell (pwsh) and run:

pwsh -NoProfile -File .\dnsBench.ps1

Parameters can be changed by editing the top of the script or by dot-sourcing and changing the variables before calling functions.

Optional configuration

- $HostName: hostname to test (default in script)
- $Trials: number of trials to average (default 5)
- $Resolvers: array of DNS resolver IPs to test
- $UploadUrl: (optional) HTTP(S) endpoint that accepts POST file uploads. If empty, upload test is skipped.
- $UploadFileSizeMB: size in megabytes of the generated test file to upload

Upload time estimate without UploadUrl

If $UploadUrl is not set, the script will attempt to estimate upload time using an installed speed test CLI and report the estimated seconds for $UploadFileSizeMB:
- Tries in order: Ookla speedtest (speedtest), speedtest-cli (python), librespeed-cli
- If none are found, it will tell you to install one.

Install options (Windows examples):
- Ookla Speedtest: https://www.speedtest.net/apps/cli or via winget: winget install Ookla.Speedtest
- speedtest-cli (Python): pip install speedtest-cli
- librespeed-cli: https://github.com/librespeed/speedtest-go

Notes

- The script uses system curl for HTTPS timing and Invoke-RestMethod for upload tests.
- If ICMP is blocked, ping results will be 'Ping blocked or unreachable'.
- The upload test generates a temporary file of random bytes and deletes it after the test.

Examples

# quick run with defaults
pwsh -NoProfile -File .\dnsBench.ps1

# edit the script variables to set an upload URL and file size, then run
# set $UploadUrl = 'https://example.com/upload' and $UploadFileSizeMB = 10

# without an upload URL, rely on installed speedtest CLI to estimate time
pwsh -NoProfile -File .\dnsBench.ps1

Security

Only run this script against servers you own or have permission to test. Uploading files to third-party endpoints may be disallowed by their terms of service.

Python alternative (simpler for non-technical)

1) Install Python (if needed):
	- Download from https://www.python.org/downloads/ and check "Add Python to PATH" during install.
2) Open PowerShell in this folder and install dependencies:
	- pip install -r requirements.txt
3) Run the Python benchmark:
	- python .\dns_bench.py
4) What it prints:
	- DNS resolver speeds, HTTPS total time (HTTP/2), HTTP/3 (if curl supports it), ping loss/jitter, and upload time estimate from speedtest-cli (no upload endpoint needed).
# PowerShell