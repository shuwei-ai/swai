#!/usr/bin/env python3
"""
Render pristine, bright (white/light) high-contrast SWAI Brand Icons for HarmonyOS NEXT.
Addresses user requirement:
- Light / White background (不要使用深色的)
- Crystal clear and vivid (清晰的)
- Embodying the SWAI brand logo (体现是SWAI这个logo图标)
"""
import os
import subprocess
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT_DIR = "/tmp/swai_icon_gen"
os.makedirs(OUT_DIR, exist_ok=True)

# 1. Background HTML/SVG (Pure Crisp Light / Ceramic White)
HTML_BG = """<!DOCTYPE html>
<html>
<head>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    width: 1024px;
    height: 1024px;
    background: radial-gradient(circle at 50% 30%, #FFFFFF 0%, #F8FAFC 70%, #EEF2F6 100%);
    overflow: hidden;
    position: relative;
  }
  svg {
    position: absolute;
    top: 0; left: 0;
    width: 1024px; height: 1024px;
  }
</style>
</head>
<body>
<svg viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <!-- Subtle pristine concentric circular tracks -->
  <circle cx="512" cy="512" r="390" stroke="rgba(203, 213, 225, 0.45)" stroke-width="2" stroke-dasharray="6 10" />
  <circle cx="512" cy="512" r="445" stroke="rgba(226, 232, 240, 0.6)" stroke-width="1.5" />
  
  <!-- Subtle ambient glow in light theme -->
  <circle cx="512" cy="460" r="260" fill="url(#lightAmbientGlow)" />
  
  <defs>
    <radialGradient id="lightAmbientGlow" cx="512" cy="460" r="260" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#E0F2FE" stop-opacity="0.5" />
      <stop offset="60%" stop-color="#EDE9FE" stop-opacity="0.3" />
      <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0" />
    </radialGradient>
  </defs>
</svg>
</body>
</html>
"""

# 2. Foreground HTML/SVG (Transparent Background, Vibrant & Ultra-Clear SWAI Emblem)
HTML_FG = """<!DOCTYPE html>
<html>
<head>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    width: 1024px;
    height: 1024px;
    background: transparent;
    overflow: hidden;
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  svg {
    width: 1024px; height: 1024px;
  }
</style>
</head>
<body>
<svg viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <!-- Vibrant SWAI High-Contrast Gradient -->
    <linearGradient id="swaiPrimaryGrad" x1="680" y1="180" x2="340" y2="760" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#0088FF" />
      <stop offset="25%" stop-color="#0EA5E9" />
      <stop offset="50%" stop-color="#6366F1" />
      <stop offset="75%" stop-color="#9333EA" />
      <stop offset="100%" stop-color="#E11D48" />
    </linearGradient>

    <!-- Glossy Highlight Gradient for 3D Volume -->
    <linearGradient id="glossGrad" x1="680" y1="180" x2="340" y2="760" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#FFFFFF" stop-opacity="0.9" />
      <stop offset="40%" stop-color="#FFFFFF" stop-opacity="0.4" />
      <stop offset="70%" stop-color="#FFFFFF" stop-opacity="0.1" />
      <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0.6" />
    </linearGradient>

    <!-- Outer Ring Gradient for Light Background -->
    <linearGradient id="outerRingGrad" x1="200" y1="200" x2="824" y2="824" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#0284C7" stop-opacity="0.6" />
      <stop offset="50%" stop-color="#8B5CF6" stop-opacity="0.3" />
      <stop offset="100%" stop-color="#E11D48" stop-opacity="0.6" />
    </linearGradient>

    <!-- Refined Soft Shadows for Light Background -->
    <filter id="lightDropShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="16" stdDeviation="20" flood-color="#1E293B" flood-opacity="0.18" />
      <feDropShadow dx="0" dy="4" stdDeviation="8" flood-color="#0F172A" flood-opacity="0.12" />
    </filter>

    <filter id="sparkGlow" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="8" result="blur" />
      <feComposite in="SourceGraphic" in2="blur" operator="over" />
    </filter>

    <radialGradient id="sparkCenter" cx="512" cy="460" r="180" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#FFFFFF" />
      <stop offset="30%" stop-color="#BAE6FD" />
      <stop offset="70%" stop-color="#38BDF8" stop-opacity="0.3" />
      <stop offset="100%" stop-color="#38BDF8" stop-opacity="0" />
    </radialGradient>
  </defs>

  <!-- 1. Outer Orbital Ring & Constellation Nodes (Light & Elegant) -->
  <circle cx="512" cy="460" r="330" stroke="url(#outerRingGrad)" stroke-width="3.5" opacity="0.8" />
  
  <!-- Orbital Nodes -->
  <circle cx="745" cy="227" r="12" fill="#0284C7" />
  <circle cx="745" cy="227" r="6" fill="#FFFFFF" />

  <circle cx="279" cy="693" r="12" fill="#E11D48" />
  <circle cx="279" cy="693" r="6" fill="#FFFFFF" />

  <!-- 2. The Main Sculpted SWAI "S" Emblem (Shifted slightly up for typographic balance) -->
  <g filter="url(#lightDropShadow)">
    <!-- Main Smooth S Flow Ribbon -->
    <path d="M 660 270
             C 660 160, 350 160, 350 330
             C 350 460, 674 445, 674 580
             C 674 745, 360 745, 360 635"
          stroke="url(#swaiPrimaryGrad)"
          stroke-width="112"
          stroke-linecap="round"
          stroke-linejoin="round"
          fill="none" />

    <!-- 3D Bevel / Specular Inner Ridge -->
    <path d="M 650 260
             C 640 185, 370 185, 370 330
             C 370 445, 654 465, 654 580
             C 654 720, 380 720, 380 645"
          stroke="url(#glossGrad)"
          stroke-width="14"
          stroke-linecap="round"
          stroke-linejoin="round"
          fill="none" />
  </g>

  <!-- 3. Central AI Intelligence Nexus Spark Core -->
  <circle cx="512" cy="455" r="140" fill="url(#sparkCenter)" />

  <g filter="url(#sparkGlow)">
    <!-- 4-Point Radiant Diamond AI Spark Core -->
    <path d="M 512 345
             Q 512 440, 534 455
             Q 512 470, 512 565
             Q 512 470, 490 455
             Q 512 440, 512 345 Z"
          fill="#FFFFFF" />

    <path d="M 402 455
             Q 497 455, 512 433
             Q 527 455, 622 455
             Q 527 455, 512 477
             Q 497 455, 402 455 Z"
          fill="#FFFFFF" />

    <!-- Core Center Dot -->
    <circle cx="512" cy="455" r="20" fill="#FFFFFF" />
    <circle cx="512" cy="455" r="10" fill="#0088FF" />
  </g>

  <!-- 4. Crisp "SWAI" Typography Brand Label at Bottom -->
  <g filter="url(#lightDropShadow)">
    <text x="512" y="870"
          text-anchor="middle"
          font-family="system-ui, -apple-system, 'SF Pro Display', 'HarmonyOS Sans', sans-serif"
          font-size="92"
          font-weight="900"
          letter-spacing="14"
          fill="url(#swaiPrimaryGrad)">SWAI</text>
  </g>
</svg>
</body>
</html>
"""

def render_html(html_content, output_png):
    html_path = os.path.join(OUT_DIR, "temp.html")
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html_content)
    
    cmd = [
        CHROME,
        "--headless",
        "--disable-gpu",
        "--hide-scrollbars",
        "--window-size=1024,1024",
        "--default-background-color=00000000",
        f"--screenshot={output_png}",
        f"file://{html_path}"
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def main():
    print("Rendering Clear White SWAI Brand Icons via Chrome headless...")
    bg_png = os.path.join(OUT_DIR, "background.png")
    fg_png = os.path.join(OUT_DIR, "foreground.png")
    
    render_html(HTML_BG, bg_png)
    render_html(HTML_FG, fg_png)
    
    # Open rendered images
    bg_img = Image.open(bg_png).convert("RGBA")
    fg_img = Image.open(fg_png).convert("RGBA")
    
    # Start icon composite
    composite = Image.alpha_composite(bg_img, fg_img)
    start_icon = composite.resize((144, 144), Image.Resampling.LANCZOS)
    
    # Copy to target directories
    targets = [
        (bg_img, f"{ROOT}/AppScope/resources/base/media/background.png"),
        (fg_img, f"{ROOT}/AppScope/resources/base/media/foreground.png"),
        (bg_img, f"{ROOT}/entry/src/main/resources/base/media/background.png"),
        (fg_img, f"{ROOT}/entry/src/main/resources/base/media/foreground.png"),
    ]
    for img, path in targets:
        img.save(path, "PNG")
        print(f"Saved: {path}")
        
    start_path = f"{ROOT}/entry/src/main/resources/base/media/startIcon.png"
    start_icon.save(start_path, "PNG")
    print(f"Saved: {start_path}")
    
    # Also save preview to /tmp for inspection
    preview_path = os.path.join(OUT_DIR, "swai_white_icon_preview.png")
    composite.resize((512, 512), Image.Resampling.LANCZOS).save(preview_path, "PNG")
    print(f"Preview saved: {preview_path}")

if __name__ == "__main__":
    main()
