import os
import urllib.parse

# Folder to scan and where index.html will be placed
TARGET_DIR = "/mnt/data/webfiles"
OUTPUT_FILE = os.path.join(TARGET_DIR, "index.html")

# Skip generation if index.html already exists
if os.path.exists(OUTPUT_FILE):
    print("index.html already exists, skipping.")
    exit(0)

if not os.path.exists(TARGET_DIR):
    os.mkdir(TARGET_DIR)

# HTML template parts
TEMPLATE_HEADER = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Files</title>
  <style>
    body { font-family: sans-serif; padding: 1em; background: #f9f9f9; }
    h1 { text-align: center; }
    ul { list-style: none; padding: 0; }
    li { background: #fff; padding: 0.8em; margin: 0.5em 0; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
    a { text-decoration: none; color: #007bff; }
    .size { font-size: 0.8em; color: #666; display: block; margin-top: 0.3em; }
    .row { display: flex; justify-content: center; align-items: center; height: 100px; }
    .big-btn { display: inline-block; padding: 15px 40px; background-color: #007bff; color: white; text-decoration: none; font-size: 18px; border-radius: 8px; text-align: center; transition: background 0.3s; }
    .big-btn:hover { background-color: #0056b3; }

  </style>
</head>
<body>
<div class="row"><a href="/webquiz/" class="big-btn">Start Testing</a></div>

<h1>Files</h1>
<ul>
"""

TEMPLATE_FOOTER = """</ul>
</body>
</html>
"""

# Gather file entries
entries = []
for fname in sorted(os.listdir(TARGET_DIR)):
    fpath = os.path.join(TARGET_DIR, fname)
    if os.path.isfile(fpath) and not fname.startswith("."):
        size_kb = os.path.getsize(fpath) / 1024
        safe_url = urllib.parse.quote(fname)
        entries.append(f'<li><a href="/{safe_url}">{fname}</a><span class="size">{size_kb:.1f} KB</span></li>')

# Write HTML if there are entries
with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
    f.write(TEMPLATE_HEADER)
    f.write("\n".join(entries))
    f.write(TEMPLATE_FOOTER)

print(f"✅ index.html generated at {OUTPUT_FILE}")
