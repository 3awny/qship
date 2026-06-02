# Video Evidence + Bug Investigation

## Video Evidence (optional — use when the AC is "show this flow works end-to-end")

Take screenshots at each step into `uat/frames/frame_NNNNN.png`, then combine.

```python
# Preferred: imageio with letterbox padding (no stretching)
# pip install imageio imageio-ffmpeg Pillow numpy
import imageio.v2 as imageio, glob, numpy as np
from PIL import Image
files = sorted(glob.glob('uat/frames/*.png'))
sizes = [Image.open(f).size for f in files]
TW = ((max(w for w,h in sizes) + 15) // 16) * 16
TH = ((max(h for w,h in sizes) + 15) // 16) * 16
writer = imageio.get_writer('uat/e2e-test.mp4', fps=0.5, macro_block_size=1)
for f in files:
    img = Image.open(f)
    scale = min(TW / img.width, TH / img.height, 1.0)
    if scale < 1:
        img = img.resize((int(img.width*scale), int(img.height*scale)), Image.LANCZOS)
    canvas = Image.new('RGB', (TW, TH), (0, 0, 0))
    canvas.paste(img, ((TW - img.width) // 2, (TH - img.height) // 2))
    writer.append_data(np.array(canvas))
writer.close()
```

Rules:
- Take screenshots AFTER waiting for visual confirmation (success notification, data change), not after fixed timers.
- Scroll modals to bottom before capturing to show all sections.
- Screenshot dropdowns while open.
- Screenshot before AND after Save/Delete actions.

## Bug Investigation (mandatory when bugs are found)

Always perform this analysis BEFORE applying a fix.

### 1. Determine origin

```bash
git blame -L <start>,<end> <file>
git log --oneline -5 -- <file>
git show HEAD~1:<file> | grep -A10 "<buggy_pattern>"
```

### 2. Classify

| Origin | Action |
|---|---|
| Our changes | Fix it — we introduced it |
| Preexisting (used) | Fix it — latent bug in production code |
| Preexisting (unused) | Fix it — dead code path we're now activating |
| Copied from buggy pattern | Fix BOTH — our code AND the source we copied from |

### 3. Root cause (if preexisting)

Investigate why it wasn't caught:
```bash
git log --all -p -S "<function_name>" -- "*.py"
grep -r "<pattern>" --include="*.py"
grep -r "def test_.*<function>" tests/
```

### 4. Bug report shape

```
## Bug Found: [Short Description]

### Location
- File: [path:line_number]
- Function: [function_name]

### Origin Analysis
- Introduced by: [Our changes / Preexisting]
- Commit: [hash if preexisting]
- Why not caught before: [Code path unused / Tests mocked DB / etc.]

### Similar Patterns
- [List any other occurrences of the same bug pattern]

### Fix Applied
- [Description]
- [Files modified]
```

### 5. Search for similar bugs

```bash
grep -r "<buggy_pattern>" --include="*.py"
grep -r "<correct_pattern>" --include="*.py"
```

If you copied from existing code that turned out to be buggy, fix BOTH locations. Memory: `feedback_complete_pattern_match`.
