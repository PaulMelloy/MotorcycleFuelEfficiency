# Deploying to shinyapps.io

## One-time setup

Install the `rsconnect` package and authenticate with your shinyapps.io account:

```r
install.packages("rsconnect")
rsconnect::setAccountInfo(
  name   = "<your-shinyapps-username>",
  token  = "<your-token>",
  secret = "<your-secret>"
)
```

Get your token and secret from: https://www.shinyapps.io/admin/#/tokens

## Required packages

The app requires these packages to be installed before deployment:

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

## Deploy

From R, with the `FZ6_fueleff` folder as your working directory (or from the project root):

```r
rsconnect::deployApp(
  appDir  = "FZ6_fueleff",
  appName = "fz6n-fuel-efficiency"
)
```

Or use the **Publish** button in RStudio when `FZ6_fueleff/app.R` is open.

## Google Sheet permissions

The Google Sheet must be set to **"Anyone with the link can view"**. The app uses
`gs4_deauth()` (no authentication) so the sheet must be publicly readable.

Sheet URL used by the app:
https://docs.google.com/spreadsheets/d/1yEOMwOPqYLhcliRsHKjOXYl3GJNIsdgHYhQwObVAioU/edit?usp=sharing

## Auto-refresh

The app automatically re-fetches the Google Sheet every **30 minutes** while it is
open. Users can also click **Refresh Data** in the sidebar to pull data immediately.
New Google Form submissions will appear in the dashboard within 30 minutes of being
submitted, with no manual action required.

## Linking from your website

Once deployed, your app will be at:
`https://<your-shinyapps-username>.shinyapps.io/fz6n-fuel-efficiency/`

Embed it in an iframe or link directly from your site.
