# Quick Usage Guide - SVG Background Patterns

## Fastest Implementation (Copy-Paste Ready)

### Option 1: Simple CSS Background (Recommended for Login Page)

```css
/* Add to your app.css or page-specific CSS */
.login-page {
  position: relative;
  min-height: 100vh;
  background: linear-gradient(135deg, #0f172a 0%, #1e293b 50%, #0f172a 100%);
}

.login-page::before {
  content: '';
  position: absolute;
  inset: 0;
  background-image: url('/images/patterns/composite-hero-pattern.svg');
  background-size: cover;
  background-position: center;
  background-repeat: no-repeat;
  opacity: 0.6;
  z-index: 0;
}

.login-page > * {
  position: relative;
  z-index: 1;
}
```

### Option 2: Tiled Pattern Background

```css
/* For repeating patterns across the page */
.dashboard {
  background-color: #0f172a;
  background-image: url('/images/patterns/neural-network-pattern-static.svg');
  background-repeat: repeat;
  background-size: 400px 400px;
  background-position: center;
}
```

### Option 3: Layered Patterns (Advanced)

```css
.hero-section {
  position: relative;
  background: #0f172a;
}

/* Base pattern layer */
.hero-section::before {
  content: '';
  position: absolute;
  inset: 0;
  background-image: url('/images/patterns/medical-tech-pattern-static.svg');
  background-repeat: repeat;
  background-size: 400px 346px;
  opacity: 0.3;
  z-index: 0;
}

/* Overlay pattern layer */
.hero-section::after {
  content: '';
  position: absolute;
  inset: 0;
  background-image: url('/images/patterns/data-viz-pattern-static.svg');
  background-repeat: repeat;
  background-size: 500px 400px;
  opacity: 0.15;
  mix-blend-mode: screen;
  z-index: 1;
}

.hero-section > * {
  position: relative;
  z-index: 2;
}
```

---

## Phoenix/Elixir Integration

### HeEx Template Example

```elixir
# lib/medlum_web/controllers/page_html/login.html.heex

<div class="relative min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900">
  <!-- Background pattern -->
  <div class="absolute inset-0 opacity-60 pointer-events-none"
       style={"background-image: url('#{~p"/images/patterns/composite-hero-pattern.svg"}'); background-size: cover; background-position: center;"}>
  </div>

  <!-- Login content -->
  <div class="relative z-10 flex items-center justify-center min-h-screen">
    <div class="w-full max-w-md">
      <%= render_slot(@inner_block) %>
    </div>
  </div>
</div>
```

### Using Tailwind CSS Classes

```elixir
<div class="relative min-h-screen bg-slate-900">
  <!-- Pattern background -->
  <div class="absolute inset-0 bg-neural-network opacity-40"></div>

  <!-- Content -->
  <div class="relative z-10">
    <!-- Your content here -->
  </div>
</div>
```

Add to your `app.css`:

```css
@layer utilities {
  .bg-neural-network {
    background-image: url('/images/patterns/neural-network-pattern-static.svg');
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

  .bg-hero-composite {
    background-image: url('/images/patterns/composite-hero-pattern.svg');
    background-size: cover;
    background-position: center;
  }
}
```

---

## Pattern Selection Guide

### Login/Landing Page
**Use:** `composite-hero-pattern.svg`
- Full-screen impact
- Combines all themes
- Professional first impression

```css
background-image: url('/images/patterns/composite-hero-pattern.svg');
background-size: cover;
opacity: 0.5-0.7;
```

### Dashboard Background
**Use:** `data-viz-pattern-static.svg`
- Reinforces data-driven theme
- Subtle and unobtrusive
- Better performance (static)

```css
background-image: url('/images/patterns/data-viz-pattern-static.svg');
background-repeat: repeat;
background-size: 500px 400px;
opacity: 0.2-0.3;
```

### Model/AI Pages
**Use:** `neural-network-pattern.svg` (animated) or `-static.svg`
- Emphasizes AI/ML theme
- Can use animated for engagement
- Static for better performance

```css
background-image: url('/images/patterns/neural-network-pattern-static.svg');
background-repeat: repeat;
background-size: 400px 400px;
opacity: 0.3-0.4;
```

### Explainability/Traceability Pages
**Use:** `traceable-pathways-pattern.svg`
- Visualizes decision trees
- Perfect for transparency theme
- Animated version adds flow

```css
background-image: url('/images/patterns/traceable-pathways-pattern.svg');
background-repeat: repeat;
background-size: 600px 400px;
opacity: 0.25-0.35;
```

### Medical/Clinical Interfaces
**Use:** `medical-tech-pattern-static.svg`
- Scientific, precise feel
- Hexagonal grid = molecular/cellular
- Professional medical aesthetic

```css
background-image: url('/images/patterns/medical-tech-pattern-static.svg');
background-repeat: repeat;
background-size: 400px 346px;
opacity: 0.25-0.35;
```

---

## Performance Optimization

### Responsive Backgrounds

```css
/* Mobile: Use static, simpler patterns */
@media (max-width: 768px) {
  .bg-pattern {
    background-image: url('/images/patterns/neural-network-pattern-static.svg');
    background-size: 300px 300px;
    opacity: 0.2;
  }
}

/* Tablet */
@media (min-width: 769px) and (max-width: 1024px) {
  .bg-pattern {
    background-image: url('/images/patterns/neural-network-pattern-static.svg');
    background-size: 400px 400px;
    opacity: 0.3;
  }
}

/* Desktop: Can use animated versions */
@media (min-width: 1025px) {
  .bg-pattern {
    background-image: url('/images/patterns/neural-network-pattern.svg');
    background-size: 400px 400px;
    opacity: 0.4;
  }
}
```

### Reduced Motion Support

```css
/* Respect user's motion preferences */
@media (prefers-reduced-motion: reduce) {
  .bg-pattern-animated {
    background-image: url('/images/patterns/neural-network-pattern-static.svg');
  }
}

@media (prefers-reduced-motion: no-preference) {
  .bg-pattern-animated {
    background-image: url('/images/patterns/neural-network-pattern.svg');
  }
}
```

### Lazy Loading (JavaScript)

```javascript
// Lazy load background patterns
document.addEventListener('DOMContentLoaded', () => {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        const pattern = entry.target.dataset.pattern;
        entry.target.style.backgroundImage = `url('/images/patterns/${pattern}.svg')`;
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.1 });

  document.querySelectorAll('[data-pattern]').forEach(el => {
    observer.observe(el);
  });
});
```

```html
<div class="dashboard" data-pattern="data-viz-pattern-static">
  <!-- Content -->
</div>
```

---

## Common Combinations

### Professional Medical Dashboard
```css
.dashboard {
  background: linear-gradient(to bottom, #0f172a, #1e293b);
  position: relative;
}

.dashboard::before {
  content: '';
  position: absolute;
  inset: 0;
  background-image:
    url('/images/patterns/medical-tech-pattern-static.svg'),
    url('/images/patterns/data-viz-pattern-static.svg');
  background-size: 400px 346px, 500px 400px;
  background-blend-mode: screen;
  opacity: 0.25;
}
```

### AI Model Page with Flow
```css
.model-page {
  background: #0f172a;
  position: relative;
}

.model-page::before {
  content: '';
  position: absolute;
  inset: 0;
  background-image: url('/images/patterns/neural-network-pattern.svg');
  background-size: 400px 400px;
  opacity: 0.3;
}

.model-page::after {
  content: '';
  position: absolute;
  inset: 0;
  background-image: url('/images/patterns/traceable-pathways-pattern-static.svg');
  background-size: 600px 400px;
  opacity: 0.15;
  mix-blend-mode: lighten;
}
```

---

## Troubleshooting

### Pattern Not Showing
1. Check file path: `/images/patterns/` should work in Phoenix
2. Verify opacity isn't set to 0
3. Ensure z-index layering is correct
4. Check that parent has positioning (`relative`, `absolute`, or `fixed`)

### Pattern Too Visible
- Reduce opacity to 0.2-0.4
- Use static version instead of animated
- Increase background-size to make pattern larger (appears less dense)

### Performance Issues
- Use static versions on mobile
- Reduce number of layered patterns
- Use `will-change: background-image` for animated patterns
- Consider PNG fallbacks for very old browsers

### Pattern Not Tiling Correctly
- Ensure `background-repeat: repeat` is set
- Check that background-size matches pattern's natural dimensions
- For seamless tiling, use exact multiples of pattern size

---

## Quick Reference Table

| Pattern | Best For | Size | Animated? | Opacity Range |
|---------|----------|------|-----------|---------------|
| **composite-hero** | Login/Landing | 1200x800 | Yes | 0.5-0.7 |
| **neural-network** | AI/ML pages | 400x400 | Yes/No | 0.3-0.4 |
| **traceable-pathways** | Explainability | 600x400 | Yes/No | 0.25-0.35 |
| **medical-tech** | Clinical UI | 400x346 | Yes/No | 0.25-0.35 |
| **data-viz** | Dashboards | 500x400 | Yes/No | 0.2-0.3 |

---

## File Size Reference

- **Animated versions:** 8-14 KB
- **Static versions:** 4-9 KB
- **Composite hero:** 11 KB

All files are optimized and production-ready.

---

## Need Help?

1. Check README.md for detailed documentation
2. Review examples in this guide
3. Test different opacity values (0.1 increments)
4. Mix and match patterns for unique effects
5. Always test on mobile devices

**Pro Tip:** Start with low opacity (0.2) and increase gradually until you find the sweet spot for your design.
