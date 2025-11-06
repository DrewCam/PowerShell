import sys, time, statistics, subprocess, re, socket
from typing import List, Optional, Tuple

# Config (can be edited inline). Non-technical users: just run as-is.
HOST_NAME = "www.google.com"  # target host
TRIALS = 5
RESOLVERS = [
    # Cloudflare
    "1.1.1.1", "1.0.0.1",
    # Google
    "8.8.8.8", "8.8.4.4",
    # Quad9
    "9.9.9.9", "149.112.112.112",
]
INCLUDE_SYSTEM_RESOLVERS = True
INCLUDE_IPV6_RESOLVERS = False
ONLY_PUBLIC_IPV4 = True
UPLOAD_FILE_SIZE_MB = 5


def try_imports():
    mods = {}
    for name in ("dns.resolver", "httpx", "speedtest"):
        try:
            mods[name] = __import__(name.split('.')[0]) if '.' not in name else __import__(name, fromlist=['*'])
        except Exception:
            mods[name] = None
    # aioquic is optional for HTTP/3
    try:
        mods["aioquic"] = __import__("aioquic")
    except Exception:
        mods["aioquic"] = None
    return mods


def is_ipv4(addr: str) -> bool:
    try:
        socket.inet_aton(addr)
        return True
    except OSError:
        return False


def is_private_ipv4(addr: str) -> bool:
    if not is_ipv4(addr):
        return True
    parts = list(map(int, addr.split('.')))
    a, b = parts[0], parts[1]
    if a == 10:
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    if a == 192 and b == 168:
        return True
    if a == 127:
        return True
    if a == 169 and b == 254:
        return True
    if a == 100 and 64 <= b <= 127:  # CGNAT
        return True
    if a >= 224:  # multicast/reserved
        return True
    return False


def get_system_resolvers_windows() -> List[str]:
    try:
        out = subprocess.check_output(["ipconfig", "/all"], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return []
    servers: List[str] = []
    lines = out.splitlines()
    capture = False
    for i, line in enumerate(lines):
        if "DNS Servers" in line:
            # First address on same line
            m = re.search(r"DNS Servers.*?:\s*([^\s]+)", line)
            if m:
                servers.append(m.group(1))
            # Subsequent addresses are typically on following indented lines
            j = i + 1
            while j < len(lines) and (lines[j].startswith(" ") or lines[j].startswith("\t")):
                addr = lines[j].strip()
                if addr:
                    servers.append(addr)
                j += 1
    # Dedup preserve order
    seen = set()
    uniq = []
    for s in servers:
        if s not in seen:
            seen.add(s)
            uniq.append(s)
    return uniq


def measure_dns_one(mods, host: str, server: str, trials: int) -> Optional[float]:
    if mods.get("dns.resolver") is None:
        return None
    resolver = mods["dns.resolver"].resolver.Resolver(configure=False)
    resolver.nameservers = [server]
    resolver.lifetime = 2.0
    times: List[float] = []
    for _ in range(trials):
        t0 = time.perf_counter()
        try:
            resolver.resolve(host, "A")
            dt = (time.perf_counter() - t0) * 1000.0
            times.append(dt)
        except Exception:
            pass
        time.sleep(0.1)
    if not times:
        return None
    return round(sum(times)/len(times), 1)


def measure_dns_all(mods, host: str, resolvers: List[str], trials: int):
    results = []
    for r in resolvers:
        avg = measure_dns_one(mods, host, r, trials)
        if avg is not None:
            results.append({"resolver": r, "avg_ms": avg})
    results.sort(key=lambda x: x["avg_ms"])
    return results


def measure_http_total_httpx(mods, url: str, trials: int, http2: bool) -> Optional[float]:
    if mods.get("httpx") is None:
        return None
    import httpx  # type: ignore
    times: List[float] = []
    try:
        with httpx.Client(http2=http2, timeout=15.0, verify=True) as client:
            for _ in range(trials):
                t0 = time.perf_counter()
                try:
                    r = client.get(url)
                    _ = r.content  # consume
                    dt = time.perf_counter() - t0
                    times.append(dt)
                except Exception:
                    pass
                time.sleep(0.15)
    except Exception:
        return None
    if not times:
        return None
    return round(sum(times)/len(times), 3)


def measure_http3_total(url: str, trials: int) -> Optional[float]:
    # Lightweight placeholder: prefer curl --http3 if available
    try:
        subprocess.check_output(["curl", "--version"], stderr=subprocess.DEVNULL)
    except Exception:
        return None
    times: List[float] = []
    fmt = "total=%{time_total}\\n"
    for _ in range(trials):
        try:
            out = subprocess.check_output(["curl", "--http3", "-sS", "-o", "NUL", "-w", fmt, url], text=True, stderr=subprocess.DEVNULL)
            m = re.search(r"total=([0-9.]+)", out)
            if m:
                times.append(float(m.group(1)))
        except Exception:
            pass
        time.sleep(0.15)
    if not times:
        return None
    return round(sum(times)/len(times), 3)


def ping_stats(host: str, count: int = 20) -> Optional[Tuple[float, float, float]]:
    # Returns (loss_percent, avg_ms, jitter_ms)
    try:
        out = subprocess.check_output(["ping", "-n", str(count), "-w", "2000", host], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return None
    latencies = [int(m.group(1)) for m in re.finditer(r"time[=<]([0-9]+)ms", out, re.IGNORECASE)]
    # Loss
    loss = None
    m = re.search(r"Lost = (\d+)", out)
    if m:
        lost = int(m.group(1))
        loss = 100.0 * (lost / float(count))
    if not latencies:
        return None
    avg = statistics.mean(latencies)
    # jitter as population stddev (approx)
    if len(latencies) > 1:
        jitter = statistics.pstdev(latencies)
    else:
        jitter = 0.0
    return (round(loss or 0.0, 1), round(avg, 1), round(jitter, 1))


def speedtest_upload_mbps(mods) -> Optional[float]:
    if mods.get("speedtest") is None:
        return None
    try:
        st = mods["speedtest"].Speedtest()
        st.get_best_server()
        bps = st.upload(pre_allocate=False)
        mbps = bps / 1e6
        return round(mbps, 2)
    except Exception:
        return None


def main():
    mods = try_imports()

    # Build resolver list
    resolvers = []
    if INCLUDE_SYSTEM_RESOLVERS and sys.platform.startswith("win"):
        resolvers += get_system_resolvers_windows()
    resolvers += RESOLVERS
    # De-dup and filter
    seen = set()
    uniq = []
    for r in resolvers:
        if r not in seen:
            seen.add(r)
            uniq.append(r)
    resolvers = uniq
    if not INCLUDE_IPV6_RESOLVERS:
        resolvers = [r for r in resolvers if is_ipv4(r)]
        if ONLY_PUBLIC_IPV4:
            resolvers = [r for r in resolvers if not is_private_ipv4(r)]

    print("DNS resolver speed (lower is better):")
    dns_results = []
    if mods.get("dns.resolver") is None:
        print("  dnspython not installed; skip DNS resolver benchmark (pip install dnspython)")
    else:
        dns_results = measure_dns_all(mods, HOST_NAME, resolvers, TRIALS)
        for r in dns_results:
            print(f"  {r['resolver']}: {r['avg_ms']} ms")

    url = f"https://{HOST_NAME}/"
    print("\nh2/HTTPS total time (seconds):")
    h2 = measure_http_total_httpx(mods, url, TRIALS, http2=True)
    if h2 is None:
        print("  httpx not installed or request failed (pip install httpx)")
    else:
        print(f"  avg_total: {h2}")

    print("\nh3/HTTP3 total time (seconds) if supported:")
    h3 = measure_http3_total(url, TRIALS)
    if h3 is None:
        print("  curl --http3 not available; skipping")
    else:
        print(f"  avg_total: {h3}")

    print("\nICMP snapshot to host (loss and jitter hint):")
    p = ping_stats(HOST_NAME, 20)
    if p is None:
        print("  Ping blocked or unreachable")
    else:
        loss, avg, jitter = p
        print(f"  Loss%: {loss}  Avg(ms): {avg}  Jitter(ms): {jitter}")

    print("\nUpload time estimate (no endpoint required):")
    up = speedtest_upload_mbps(mods)
    if up is None:
        print("  speedtest-cli not installed or failed (pip install speedtest-cli)")
    else:
        seconds = round((UPLOAD_FILE_SIZE_MB * 8.0) / up, 2)
        mins = round(seconds / 60.0, 2)
        print(f"  Upload Mbps: {up}  File: {UPLOAD_FILE_SIZE_MB} MB  Est. time: {seconds}s (~{mins} min)")


if __name__ == "__main__":
    main()
