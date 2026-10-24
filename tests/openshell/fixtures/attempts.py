"""One request of each kind OpenShell's supervisor answers (DR-248): one
it allows, one its L7 rules deny, one to a host no rule names, and one to
the cloud metadata address. Each outcome is printed; none is an error."""
import urllib.request

ATTEMPTS = [
    ("GET", "https://api.github.com/zen"),        # allowed: read-only rest
    ("POST", "https://api.github.com/markdown"),  # L7: read-only denies POST
    ("GET", "https://example.org/"),              # L4: no rule names the host
    ("GET", "http://169.254.169.254/"),           # metadata: no rule can allow it
]
for method, url in ATTEMPTS:
    req = urllib.request.Request(url, method=method, data=b"{}" if method == "POST" else None)
    try:
        with urllib.request.urlopen(req, timeout=10) as reply:
            print(f"{method} {url} -> {reply.status}", flush=True)
    except Exception as exc:  # the outcome is the point, not the error
        print(f"{method} {url} -> {type(exc).__name__}: {exc}", flush=True)
