# Motorcycle Fuel Efficiency — Yamaha FZ6N

A live R Shiny dashboard tracking fuel usage, economy, and cost for a Yamaha FZ6N motorcycle. Data is collected at every fill-up via a Google Form and feeds directly into the dashboard through Google Sheets — no manual exports required.

## Dashboard

> **Live app:** `https://paulmelloy.shinyapps.io/Fuel_efficiency_FZ6N/`

![R](https://img.shields.io/badge/R-Shiny-blue?logo=r)
![License](https://img.shields.io/github/license/PaulMelloy/MotorcycleFuelEfficiency)

---

## Features

- **Live data** — pulls from Google Sheets on load and auto-refreshes every 30 minutes; new form submissions appear within 30 minutes with no action required
- **Interactive charts** — hover tooltips, zoom, and pan on all plots via Plotly
- **Fuel economy over time** — scatter plot with LOESS trend line
- **Fuel type comparison** — side-by-side boxplots comparing L/100km and cost per km across 91, 94, 95, and 98 RON octane grades, including observation counts (n)
- **Station comparison** — average fuel economy ranked by servo brand
- **Fuel prices over time** — price trends per octane grade
- **Highway vs city** — scatter plot of economy against percentage highway riding
- **Flexible filters** — quick-select date presets (this year, last 12 months, last 2 years, last 5 years, all entries), custom date range, octane grade, fuel brand, and outlier toggle
- **Colour-blind safe** — all charts use the Okabe-Ito palette

---

## How it works

Data flows from a Google Form → Google Sheet → Shiny app:

1. Fill up the bike, open the Google Form on your phone
2. Enter octane grade, volume (L), price (c/L), kilometres since last fill, % highway riding, and servo brand
3. The form appends a row to the Google Sheet automatically
4. The dashboard reads the sheet live via `googlesheets4::read_sheet()` with `gs4_deauth()` (no auth token needed — the sheet is publicly readable)

### Metrics

| Metric | Calculation |
|---|---|
| **L/100km** | `(litres ÷ km) × 100` — lower is better |
| **Cost per km** | `(litres × price_prev_fill ÷ 100) ÷ km` |

Note: octane grade and price are shifted by one row before calculating efficiency. This is because the kilometres driven between fills were covered on the *previous* fill's fuel, not the current one.

---

## Repository structure

```
MotorcycleFuelEfficiency/
├── FZ6_fueleff/
│   └── app.R          # Shiny dashboard (single-file app)
├── data/
│   └── fuel_dat.csv   # Local CSV cache (fallback if Sheets is unreachable)
├── fuel_eff.Rmd       # Exploratory analysis notebook
├── Dockerfile         # Container image (rocker/r2u, multi-arch: amd64 + arm64)
├── docker-compose.yml # App + Caddy path-prefix proxy stack
├── Caddyfile          # Serves the app under /shiny/MotorcycleFuelEfficiency/
└── README.md
```

---

## Running locally

### Prerequisites

```r
install.packages(c(
  "shiny",
  "bslib",
  "googlesheets4",
  "dplyr",
  "ggplot2",
  "plotly",
  "DT",
  "lubridate"
))
```

### Run

Open `FZ6_fueleff/app.R` in RStudio and click **Run App**, or from the console:

```r
shiny::runApp("FZ6_fueleff")
```

The app reads live from Google Sheets by default. If the sheet is unreachable it falls back to `data/fuel_dat.csv`.

---

## Docker deployment

One command builds and runs the dashboard with a path-prefix proxy in front:

```bash
docker compose up -d --build
# -> http://localhost:3838/shiny/MotorcycleFuelEfficiency/
```

| Piece | Role |
|---|---|
| `Dockerfile` | R + Shiny image based on `rocker/r2u` (binary apt packages, **multi-arch**: runs on x86 servers and ARM Raspberry Pi; `rocker/shiny` is amd64-only) |
| `proxy` (Caddy) | Publishes port 3838 and strips the `/shiny/MotorcycleFuelEfficiency` prefix before forwarding to Shiny. Needed because Shiny itself cannot mount an app on a subpath — but it emits *relative* asset URLs and derives its websocket path from the page URL, so a strip-prefix proxy works cleanly |
| `./data` mount | `data/fuel_dat.csv` is bind-mounted read-only into the container, so the fallback cache can be refreshed on the host without rebuilding the image |

Plain HTTP only: TLS is expected to terminate at a reverse proxy or Cloudflare Tunnel in front of it.

Example Cloudflare Tunnel ingress rule (forward the full path; Caddy strips it):

```yaml
ingress:
  - hostname: apps.example.com
    path: ^/shiny/MotorcycleFuelEfficiency
    service: http://localhost:3838
```

Code changes require a rebuild (`docker compose up -d --build`) because the app source is baked into the image.

---

## Data

The Google Sheet must be shared as **"Anyone with the link can view"** for the app to read it without authentication.

**Sheet:** <https://docs.google.com/spreadsheets/d/1yEOMwOPqYLhcliRsHKjOXYl3GJNIsdgHYhQwObVAioU/edit?usp=sharing>

| Column | Description |
|---|---|
| Timestamp | Form submission time (auto) |
| Refuel Date | Date of fill-up |
| Fuel type (octane) | RON rating: 91, 94, 95, or 98 |
| Refuel Volume (L) | Litres added |
| Refuel cost per litre (cents) | Price paid in cents/L |
| Kilometres since last refuel | Trip distance |
| Percentage of highway travel | 0–100% estimate |
| Servo Brand | Station name |
| Fuel Price — e10/91/95/98 (cents) | Board prices at the servo |
| Additional Notes | Free text |

---

## License

MIT — see [LICENSE](LICENSE).
