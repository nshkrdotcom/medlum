# SVG Background Patterns for Medical AI Platform

Sophisticated SVG background patterns designed for the Lumainus medical AI platform login page, embodying the theme of **Traceable AI Intelligence** - where medical precision meets neural networks and data flows through transparent systems.

## Pattern Collection

### 1. Neural Network Grid Pattern
**Files:**
- `neural-network-pattern.svg` (Animated, 8.5KB)
- `neural-network-pattern-static.svg` (Static, 4.2KB)

**Description:**
Subtle interconnected nodes representing neural pathways with animated data pulses traveling through the network. Features a 5x5 grid of nodes with horizontal, vertical, and diagonal connections.

**Theme Elements:**
- Pulsing nodes with staggered animations
- Data flowing through network paths
- Gradient-enhanced connections
- Subtle glow effects at key nodes

**Best Used For:**
- Main login page background
- AI model selection screens
- Neural network visualization contexts

---

### 2. Traceable Pathways Pattern
**Files:**
- `traceable-pathways-pattern.svg` (Animated, 10.9KB)
- `traceable-pathways-pattern-static.svg` (Static, 6.0KB)

**Description:**
Abstract representation of AI decision trees with flowing, branching lines at different opacity levels. Visualizes how data flows through decision points to reach outcomes.

**Theme Elements:**
- Branching decision paths
- Animated flow indicators
- Multi-level depth representation
- Decision point glows and pulses

**Best Used For:**
- Decision-making interface backgrounds
- Model explainability pages
- Traceability dashboards

---

### 3. Medical Tech Pattern
**Files:**
- `medical-tech-pattern.svg` (Animated, 10.6KB)
- `medical-tech-pattern-static.svg` (Static, 5.0KB)

**Description:**
Hexagonal molecular/cellular grid with scientific precision. Features electron orbits, molecular bonds, and breathing animations reminiscent of cellular structures.

**Theme Elements:**
- Hexagonal tessellation
- Molecular center points
- Electron orbit animations
- Precision cross-hairs
- Subtle breathing effect

**Best Used For:**
- Medical data entry forms
- Clinical interface backgrounds
- Scientific accuracy contexts

---

### 4. Data Visualization Pattern
**Files:**
- `data-viz-pattern.svg` (Animated, 13.6KB)
- `data-viz-pattern-static.svg` (Static, 8.7KB)

**Description:**
Abstract statistical elements including bar charts, confidence intervals, scatter plots, and trend indicators. Creates a subliminal data-driven atmosphere.

**Theme Elements:**
- Animated bar charts
- Confidence interval bands
- Scatter plot data points
- Line charts and trends
- Error bars and box plots
- Statistical annotations

**Best Used For:**
- Analytics dashboards
- Model performance displays
- Statistical report backgrounds

---

## Usage Examples

### CSS Background Integration

#### Basic Usage (Static Version)
```css
.login-page {
  background-image: url('/images/patterns/neural-network-pattern-static.svg');
  background-repeat: repeat;
  background-size: 400px 400px;
  background-position: center;
}
```

#### With Overlay and Gradient
```css
.hero-section {
  position: relative;
  background-color: #0f172a;
}

.hero-section::before {
  content: '';
  position: absolute;
  inset: 0;
  background-image: url('/images/patterns/traceable-pathways-pattern.svg');
  background-repeat: repeat;
  background-size: 600px 400px;
  opacity: 0.6;
  z-index: 1;
}

.hero-section::after {
  content: '';
  position: absolute;
  inset: 0;
  background: linear-gradient(135deg,
    rgba(59, 130, 246, 0.1) 0%,
    rgba(139, 92, 246, 0.05) 100%);
  z-index: 2;
}

.hero-section > * {
  position: relative;
  z-index: 3;
}
```

#### Multiple Patterns Layered
```css
.dashboard {
  background-color: #0f172a;
  position: relative;
}

/* Base pattern */
.dashboard::before {
  content: '';
  position: absolute;
  inset: 0;
  background-image: url('/images/patterns/medical-tech-pattern-static.svg');
  background-repeat: repeat;
  background-size: 400px 346px;
  opacity: 0.3;
}

/* Overlay pattern */
.dashboard::after {
  content: '';
  position: absolute;
  inset: 0;
  background-image: url('/images/patterns/data-viz-pattern-static.svg');
  background-repeat: repeat;
  background-size: 500px 400px;
  opacity: 0.2;
  mix-blend-mode: screen;
}
```

### Direct SVG Element Usage

#### Inline SVG Background
```html
<div class="pattern-container">
  <svg class="background-pattern" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <pattern id="neuralPattern"
               patternUnits="userSpaceOnUse"
               width="400"
               height="400">
        <image href="/images/patterns/neural-network-pattern.svg"
               width="400"
               height="400" />
      </pattern>
    </defs>
    <rect width="100%" height="100%" fill="url(#neuralPattern)" opacity="0.4"/>
  </svg>
  <div class="content">
    <!-- Your content here -->
  </div>
</div>

<style>
.pattern-container {
  position: relative;
  min-height: 100vh;
}

.background-pattern {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  z-index: 0;
}

.content {
  position: relative;
  z-index: 1;
}
</style>
```

### Phoenix/Elixir Integration

#### HeEx Template
```elixir
<div class="login-container" style={"background-image: url('#{~p"/images/patterns/neural-network-pattern.svg"}')"}>
  <div class="login-form">
    <!-- Login form content -->
  </div>
</div>
```

#### CSS Module (app.css)
```css
/* patterns.css */
.bg-neural-network {
  background-image: url('/images/patterns/neural-network-pattern-static.svg');
  background-repeat: repeat;
  background-size: 400px 400px;
}

.bg-neural-network-animated {
  background-image: url('/images/patterns/neural-network-pattern.svg');
  background-repeat: repeat;
  background-size: 400px 400px;
}

.bg-traceable-paths {
  background-image: url('/images/patterns/traceable-pathways-pattern-static.svg');
  background-repeat: repeat;
  background-size: 600px 400px;
}

.bg-medical-tech {
  background-image: url('/images/patterns/medical-tech-pattern-static.svg');
  background-repeat: repeat;
  background-size: 400px 346px;
}

.bg-data-viz {
  background-image: url('/images/patterns/data-viz-pattern-static.svg');
  background-repeat: repeat;
  background-size: 500px 400px;
}

/* Utility classes for opacity control */
.pattern-subtle { opacity: 0.3; }
.pattern-medium { opacity: 0.5; }
.pattern-prominent { opacity: 0.7; }
```

---

## Performance Considerations

### When to Use Animated vs Static

**Use Animated Versions:**
- Hero sections and landing pages
- Interactive dashboards where motion adds value
- Modern browsers with good SVG animation support
- When user engagement is priority

**Use Static Versions:**
- Mobile devices (better performance)
- Background patterns behind heavy content
- When page performance is critical
- Older browsers or accessibility concerns

### Optimization Tips

1. **Preload Critical Patterns:**
```html
<link rel="preload"
      href="/images/patterns/neural-network-pattern-static.svg"
      as="image"
      type="image/svg+xml">
```

2. **Use Static for Repeated Tiles:**
Static versions are ~50% smaller and render faster when tiled extensively.

3. **Reduce Opacity:**
Lower opacity values reduce visual complexity and improve perceived performance.

4. **Lazy Load Non-Critical Patterns:**
```javascript
// Lazy load pattern when section comes into view
const observer = new IntersectionObserver((entries) => {
  entries.forEach(entry => {
    if (entry.isIntersecting) {
      entry.target.style.backgroundImage =
        "url('/images/patterns/data-viz-pattern.svg')";
      observer.unobserve(entry.target);
    }
  });
});
```

---

## Design Specifications

### Color Palette
All patterns use a consistent color scheme:

- **Primary Blue:** `#3b82f6` (opacity: 0.15-0.4)
- **Light Blue:** `#60a5fa` (opacity: 0.1-0.6)
- **Indigo:** `#6366f1` (opacity: 0.2-0.35)
- **Purple:** `#8b5cf6` (opacity: 0.15-0.4)
- **Dark Blue:** `#1e40af` (opacity: 0-0.3)
- **Background:** `#0f172a` (slate-900, opacity: 0.01-0.02)

### Dimensions

| Pattern | Width | Height | Aspect Ratio |
|---------|-------|--------|--------------|
| Neural Network | 400px | 400px | 1:1 |
| Traceable Pathways | 600px | 400px | 3:2 |
| Medical Tech | 400px | 346.41px | Hexagonal |
| Data Visualization | 500px | 400px | 5:4 |

All patterns are designed to tile seamlessly both horizontally and vertically.

---

## Accessibility

All patterns are designed with accessibility in mind:

1. **Low Opacity:** Patterns use subtle opacities (0.08-0.4) to avoid overwhelming users
2. **No Critical Information:** Patterns are decorative only, no essential content
3. **Prefers Reduced Motion:** Consider disabling animated versions for users with motion sensitivity:

```css
@media (prefers-reduced-motion: reduce) {
  .bg-neural-network-animated {
    background-image: url('/images/patterns/neural-network-pattern-static.svg');
  }
}
```

4. **Color Contrast:** Patterns maintain sufficient contrast with foreground content when used at recommended opacity levels

---

## Customization

### Adjusting Colors

To change the color scheme, edit the gradient definitions in each SVG file:

```svg
<defs>
  <linearGradient id="connectionGradient" x1="0%" y1="0%" x2="100%" y2="0%">
    <stop offset="0%" style="stop-color:#YOUR_COLOR;stop-opacity:0.1"/>
    <stop offset="50%" style="stop-color:#YOUR_COLOR;stop-opacity:0.25"/>
    <stop offset="100%" style="stop-color:#YOUR_COLOR;stop-opacity:0.1"/>
  </linearGradient>
</defs>
```

### Adjusting Animation Speed

Find `<animate>` tags and modify the `dur` attribute:

```svg
<animate attributeName="opacity"
         values="0.4;0.8;0.4"
         dur="3s"  <!-- Change this value -->
         repeatCount="indefinite"/>
```

### Creating Hybrid Versions

You can selectively enable/disable animation by removing specific `<animate>` tags while keeping others, creating a partially animated effect.

---

## Browser Support

- **Modern Browsers:** Full support with animations
- **Chrome/Edge 88+:** Excellent
- **Firefox 85+:** Excellent
- **Safari 14+:** Excellent
- **Mobile Safari:** Use static versions for better performance
- **IE11:** Not supported (use static PNGs as fallback)

---

## File Structure

```
priv/static/images/patterns/
├── neural-network-pattern.svg (animated)
├── neural-network-pattern-static.svg
├── traceable-pathways-pattern.svg (animated)
├── traceable-pathways-pattern-static.svg
├── medical-tech-pattern.svg (animated)
├── medical-tech-pattern-static.svg
├── data-viz-pattern.svg (animated)
├── data-viz-pattern-static.svg
└── README.md (this file)
```

---

## Examples in Context

### Login Page Recommendation
```css
.login-page {
  background: linear-gradient(135deg, #0f172a 0%, #1e293b 100%);
  position: relative;
}

.login-page::before {
  content: '';
  position: absolute;
  inset: 0;
  background-image: url('/images/patterns/neural-network-pattern.svg');
  background-size: 400px 400px;
  opacity: 0.4;
}
```

### Dashboard Recommendation
```css
.dashboard {
  background: #0f172a;
  position: relative;
}

.dashboard::before {
  background-image: url('/images/patterns/data-viz-pattern-static.svg');
  background-size: 500px 400px;
  opacity: 0.25;
}
```

### Model Explainability Page
```css
.explainability-view {
  background: #0f172a;
  position: relative;
}

.explainability-view::before {
  background-image: url('/images/patterns/traceable-pathways-pattern.svg');
  background-size: 600px 400px;
  opacity: 0.3;
}
```

---

## Credits

Created for **Lumainus Medical AI Platform**
Theme: Traceable AI Intelligence
Generated: November 2025

All patterns are optimized for web use and designed to convey:
- Medical precision
- Neural network intelligence
- Data transparency
- Professional, cutting-edge aesthetic
- Calm, trustworthy atmosphere
