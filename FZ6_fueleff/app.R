# ============================================================
# FZ6N Fuel Efficiency Dashboard
# Author: P. Melloy
# Data source: Google Form → Google Sheets (auto-updated)
# Deploy: shinyapps.io
# ============================================================

library(shiny)
library(bslib)
library(googlesheets4)
library(dplyr)
library(ggplot2)
library(plotly)
library(DT)
library(lubridate)

# ── Constants ────────────────────────────────────────────────────────────────
SHEET_URL           <- "https://docs.google.com/spreadsheets/d/1yEOMwOPqYLhcliRsHKjOXYl3GJNIsdgHYhQwObVAioU/edit?usp=sharing"
REFRESH_INTERVAL_MS <- 30 * 60 * 1000   # Auto-refresh every 30 minutes

# Okabe-Ito colour-blind-safe palette (4 octane grades)
# Distinguishable under deuteranopia, protanopia, and tritanopia
CB_COLS <- c(
  "91" = "#E69F00",   # orange
  "94" = "#56B4E9",   # sky blue
  "95" = "#009E73",   # bluish green
  "98" = "#0072B2"    # blue
)

# ── Data Loading ─────────────────────────────────────────────────────────────
load_raw <- function() {
  tryCatch({
    gs4_deauth()
    suppressMessages(
      read_sheet(SHEET_URL, col_types = paste(rep("c", 13), collapse = ""))
    )
  }, error = function(e) {
    message("Google Sheets unavailable, using local CSV cache: ", e$message)
    read.csv("../data/fuel_dat.csv", stringsAsFactors = FALSE)
  })
}

# ── Robust date parser ────────────────────────────────────────────────────────
# Handles: Date, POSIXct, ISO strings, space-separated datetimes,
# Australian DD/MM/YYYY, and the numeric day-count strings googlesheets4 emits.
parse_col_date <- function(x) {
  if (inherits(x, "Date"))   return(as.Date(x))
  if (inherits(x, "POSIXt")) return(as.Date(x))
  if (is.list(x)) {
    x <- vapply(x, function(v) {
      if (is.null(v)) return(NA_character_)
      if (inherits(v, "Date") || inherits(v, "POSIXt"))
        return(format(as.Date(v), "%Y-%m-%d"))
      as.character(v)
    }, character(1))
  }
  x <- as.character(x)
  x <- trimws(sub("(T| ).*", "", trimws(x)))   # strip time component
  suppressWarnings(
    as.Date(lubridate::parse_date_time(x,
      orders = c("Ymd", "dmY", "mdY"),
      quiet  = TRUE
    ))
  )
}

# ── Data Cleaning & Type Validation ──────────────────────────────────────────
clean_data <- function(df) {
  # Keep only the first 13 columns (sheet may have extra trailing columns)
  df <- df[, seq_len(min(ncol(df), 13)), drop = FALSE]
  colnames(df) <- c("timestamp", "date", "octane", "refuel_L", "price",
                    "km", "pct_hwy", "station",
                    "price_e10", "price_91", "price_95", "price_98", "notes")

  df <- df %>%
    mutate(
      # ── Dates ─────────────────────────────────────────────────────────────
      date      = parse_col_date(date),

      # ── Numerics (cast from character; warnings suppressed) ────────────────
      octane    = suppressWarnings(as.integer(as.numeric(as.character(octane)))),
      refuel_L  = suppressWarnings(as.numeric(as.character(refuel_L))),
      price     = suppressWarnings(as.numeric(as.character(price))),
      km        = suppressWarnings(as.numeric(as.character(km))),
      pct_hwy   = suppressWarnings(as.numeric(as.character(pct_hwy))),

      # ── Strings ───────────────────────────────────────────────────────────
      station   = tolower(trimws(as.character(station))),
      notes     = as.character(notes)
    ) %>%

    # ── Range / sanity validation ──────────────────────────────────────────
    mutate(
      # Fix data entry error: octane entered as 9.4e+11 instead of 94
      octane   = ifelse(!is.na(octane) & octane > 100L, 94L, octane),
      # Fuel volume: motorcycle tank is ~17 L; allow up to 30 for partial rows
      refuel_L = ifelse(!is.na(refuel_L) & refuel_L > 0 & refuel_L <= 30,
                        refuel_L, NA_real_),
      # Price: 50–400 cents/litre is a plausible real-world range
      price    = ifelse(!is.na(price) & price > 50 & price < 400,
                        price, NA_real_),
      # km: positive and < 2000 (impossible on one tank otherwise)
      km       = ifelse(!is.na(km) & km > 0 & km < 2000, km, NA_real_),
      # Highway %: must be 0–100
      pct_hwy  = ifelse(!is.na(pct_hwy) & pct_hwy >= 0 & pct_hwy <= 100,
                        pct_hwy, NA_real_)
    ) %>%

    filter(!is.na(date)) %>%
    arrange(date) %>%

    # Shift octane & price by one row: the km driven for fill i used the
    # fuel that was put in at fill i-1.
    mutate(
      octane_used = lag(octane),
      price_used  = lag(price)
    ) %>%

    # Explicit types for lagged columns
    mutate(
      octane_used = as.integer(octane_used),
      price_used  = as.numeric(price_used)
    ) %>%

    # ── Derived metrics ────────────────────────────────────────────────────
    mutate(
      L_per_100km = ifelse(!is.na(km) & km > 0,
                           (refuel_L / km) * 100, NA_real_),
      cost_per_km = ifelse(!is.na(km) & km > 0 & !is.na(price_used),
                           (refuel_L * price_used / 100) / km, NA_real_),
      total_cost  = ifelse(!is.na(price_used),
                           refuel_L * price_used / 100, NA_real_),
      year        = year(date),
      month_start = floor_date(date, "month")
    ) %>%

    # ── Standardise station names ──────────────────────────────────────────
    mutate(station = case_when(
      grepl("^bp$|^b\\.?p\\.?$|^bp ", station)       ~ "BP",
      grepl("caltex|ampol", station)                  ~ "Ampol/Caltex",
      grepl("mobil", station)                         ~ "Mobil",
      grepl("shell", station)                         ~ "Shell",
      grepl("puma", station)                          ~ "Puma",
      grepl("711|7-11|7\\.11|seven.eleven", station)  ~ "7-Eleven",
      grepl("freedom", station)                       ~ "Freedom",
      grepl("eg.?fuel", station)                      ~ "EG Fuel",
      station %in% c("na", "n/a", "", "null")         ~ NA_character_,
      TRUE ~ tools::toTitleCase(station)
    ))
}

# ── Outlier filter ────────────────────────────────────────────────────────────
filter_valid_fills <- function(df, exclude_outliers = TRUE) {
  df <- df %>% filter(!is.na(km), !is.na(L_per_100km))
  if (exclude_outliers) {
    df <- df %>% filter(km >= 80, km <= 500, L_per_100km > 3, L_per_100km < 12)
  }
  df
}

# ── Theme ─────────────────────────────────────────────────────────────────────
app_theme <- bs_theme(
  version    = 5,
  bootswatch = "flatly",
  primary    = "#0072B2"   # matches the "98 octane" Okabe-Ito blue
)

# ── UI ────────────────────────────────────────────────────────────────────────
ui <- page_navbar(
  title        = "FZ6N Fuel Efficiency",
  theme        = app_theme,
  window_title = "FZ6N Fuel Efficiency",

  # ── Dashboard tab ──────────────────────────────────────────────────────────
  nav_panel(
    title = "Dashboard",
    icon  = icon("gauge-high"),

    layout_sidebar(
      # Sidebar: open by default, distinct background so it stands out
      sidebar = sidebar(
        width  = 270,
        open   = "open",
        bg     = "#dce8f5",
        title  = "Filters",

        # Quick-select presets — update the date range input below
        radioButtons(
          "date_preset", "Quick select",
          choices  = c("This year", "Last 12 months", "Last 2 years",
                       "Last 5 years", "All entries"),
          selected = "Last 2 years"
        ),

        dateRangeInput(
          "date_range", "Custom date range",
          start = "2022-01-01",
          end   = Sys.Date(),
          min   = "2016-01-01",
          max   = Sys.Date()
        ),

        hr(),

        checkboxGroupInput(
          "fuel_types", "Octane rating",
          choices  = c("91", "94", "95", "98"),
          selected = c("91", "94", "95", "98")
        ),

        # Brand choices are populated dynamically once data loads
        checkboxGroupInput(
          "brands", "Fuel brand",
          choices  = character(0),
          selected = character(0)
        ),

        checkboxInput(
          "exclude_outliers",
          "Exclude trips with likely odometer reset (>500 km or <80 km)",
          value = TRUE
        ),

        hr(),

        actionButton("refresh", "Refresh Data", icon = icon("rotate"),
                     class = "btn-outline-primary btn-sm w-100"),
        div(
          class = "text-muted mt-2",
          style = "font-size: 0.75rem;",
          textOutput("last_updated_txt")
        )
      ),

      # ── KPI boxes ────────────────────────────────────────────────────────
      layout_columns(
        col_widths = c(3, 3, 3, 3),
        value_box(
          title    = "Fill-ups recorded",
          value    = textOutput("kpi_n"),
          showcase = icon("fill-drip"),
          theme    = "primary"
        ),
        value_box(
          title    = "Total distance",
          value    = textOutput("kpi_km"),
          showcase = icon("road"),
          theme    = "success"
        ),
        value_box(
          title    = "Avg fuel economy",
          value    = textOutput("kpi_eff"),
          showcase = icon("leaf"),
          theme    = "info"
        ),
        value_box(
          title    = "Avg cost per km",
          value    = textOutput("kpi_cost"),
          showcase = icon("dollar-sign"),
          theme    = "warning"
        )
      ),

      # ── Getting-started banner ─────────────────────────────────────────────
      card(
        class = "border-info mb-2",
        card_body(
          class = "py-2",
          style = "background:#e8f4f8;",
          tags$div(
            style = "display:flex; align-items:flex-start; gap:0.75rem;",
            tags$span(style = "font-size:1.3rem; line-height:1.4;", "\U2139\UFE0F"),
            tags$div(
              tags$strong("Getting started: "),
              "Use the ", tags$strong("Date Range"), " and ",
              tags$strong("Octane Rating"), " filters in the sidebar to explore the data. ",
              "Showing the most recent 2 years by default — expand the date range to see the full history back to 2016. ",
              "Hover over any chart point for details. ",
              tags$strong("Outlier trips"), " (>500\U00A0km between fills) are hidden by default ",
              "as they usually indicate the tripmeter was not reset."
            )
          )
        )
      ),

      # ── Chart tabs ────────────────────────────────────────────────────────
      navset_card_tab(
        height = 480,

        nav_panel(
          "Efficiency Over Time",
          icon = icon("chart-line"),
          plotlyOutput("plot_eff_time", height = "410px")
        ),

        nav_panel(
          "Fuel Type Comparison",
          icon = icon("vials"),
          layout_columns(
            col_widths = c(6, 6),
            plotlyOutput("plot_eff_octane",  height = "410px"),
            plotlyOutput("plot_cost_octane", height = "410px")
          )
        ),

        nav_panel(
          "Station Comparison",
          icon = icon("gas-pump"),
          plotlyOutput("plot_station", height = "410px")
        ),

        nav_panel(
          "Fuel Prices",
          icon = icon("tags"),
          plotlyOutput("plot_prices", height = "410px")
        ),

        nav_panel(
          "Highway vs City",
          icon = icon("road"),
          plotlyOutput("plot_hwy", height = "410px")
        ),

        nav_panel(
          "Data Table",
          icon = icon("table"),
          DTOutput("tbl_data")
        )
      )
    )
  ),

  # ── About tab ──────────────────────────────────────────────────────────────
  nav_panel(
    title = "About",
    icon  = icon("circle-info"),
    card(
      max_height = 600,
      card_header("About This Dashboard"),
      card_body(
        p("This dashboard tracks every fuel fill-up for a Yamaha FZ6N motorcycle.
           Data is collected via a Google Form and synced live from Google Sheets —
           each new entry appears automatically within 30 minutes."),
        tags$h6("How metrics are calculated"),
        tags$ul(
          tags$li(strong("L/100km"), " — litres used / km driven × 100. Lower is better."),
          tags$li(strong("Cost per km"), " — (litres × fuel price) / km driven.
                  Uses the price from the ", em("previous"), " fill, since that is the
                  fuel that was actually burned on that trip."),
          tags$li(strong("Outliers"), " — trips flagged as >500 km or <80 km are likely
                  cases where the trip meter was not reset. Toggle them on/off in the sidebar.")
        ),
        tags$h6("Fuel grades"),
        p("91, 94, 95, and 98 refer to the RON octane rating."),
        tags$h6("Colours"),
        p("All charts use the Okabe-Ito palette, which is distinguishable under
           deuteranopia, protanopia, and tritanopia."),
        hr(),
        p("Source code: ",
          tags$a("github.com/PaulMelloy/MotorcycleFuelEfficiency",
                 href = "https://github.com/PaulMelloy/MotorcycleFuelEfficiency",
                 target = "_blank"))
      )
    )
  ),

  nav_spacer(),
  nav_item(
    tags$span(class = "text-muted navbar-text",
              style = "font-size:0.8rem; padding-right:1rem;",
              "Yamaha FZ6N • Paul Melloy")
  )
)

# ── Server ────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {

  last_updated <- reactiveVal(Sys.time())

  # ── Data (auto-refreshes every 30 min or on button click) ──────────────────
  raw_data <- reactive({
    input$refresh
    invalidateLater(REFRESH_INTERVAL_MS, session)
    last_updated(Sys.time())
    withProgress(message = "Loading data from Google Sheets...", value = 0.5, {
      clean_data(load_raw())
    })
  })

  # First load: set selection to last 2 years AND set calendar bounds
  observeEvent(raw_data(), {
    df <- raw_data()
    req(nrow(df) > 0)
    min_d   <- min(df$date, na.rm = TRUE)
    max_d   <- max(df$date, na.rm = TRUE)
    start_d <- max(min_d, max_d - years(2))
    updateDateRangeInput(session, "date_range",
                         start = start_d, end = max_d,
                         min   = min_d,   max = max_d)
  }, once = TRUE)

  # Subsequent refreshes: update calendar bounds only, preserve user's selection
  observe({
    df <- raw_data()
    req(nrow(df) > 0)
    updateDateRangeInput(session, "date_range",
                         min = min(df$date, na.rm = TRUE),
                         max = max(df$date, na.rm = TRUE))
  })

  # Populate brand checkboxes from cleaned data on first load
  observeEvent(raw_data(), {
    df     <- raw_data()
    brands <- sort(unique(na.omit(df$station)))
    updateCheckboxGroupInput(session, "brands",
                             choices  = brands,
                             selected = brands)
  }, once = TRUE)

  # Date preset shortcuts — update the date range input
  observeEvent(input$date_preset, {
    df <- raw_data()
    req(nrow(df) > 0)
    min_d   <- min(df$date, na.rm = TRUE)
    max_d   <- max(df$date, na.rm = TRUE)
    start_d <- switch(input$date_preset,
      "This year"      = floor_date(Sys.Date(), "year"),
      "Last 12 months" = Sys.Date() - days(365),
      "Last 2 years"   = max_d - years(2),
      "Last 5 years"   = max_d - years(5),
      "All entries"    = min_d,
      min_d
    )
    updateDateRangeInput(session, "date_range",
                         start = max(as.Date(start_d), min_d),
                         end   = max_d)
  }, ignoreInit = TRUE)

  output$last_updated_txt <- renderText({
    paste("Last updated:", format(last_updated(), "%H:%M:%S"))
  })

  # ── Filtered data ──────────────────────────────────────────────────────────
  fdata <- reactive({
    req(input$date_range)
    df <- raw_data() %>%
      filter(date >= input$date_range[1], date <= input$date_range[2])
    df <- filter_valid_fills(df, input$exclude_outliers)
    # Only filter by octane when a strict subset is selected, so that rows
    # with octane_used = NA (first fill ever) are kept when all types checked.
    selected_oct <- as.integer(input$fuel_types)
    all_oct      <- c(91L, 94L, 95L, 98L)
    if (length(selected_oct) > 0 && !setequal(selected_oct, all_oct)) {
      df <- df %>% filter(octane_used %in% selected_oct)
    }
    # Brand filter — only apply once choices have been populated
    all_brands <- sort(unique(na.omit(raw_data()$station)))
    if (length(input$brands) > 0 && !setequal(input$brands, all_brands)) {
      df <- df %>% filter(is.na(station) | station %in% input$brands)
    }
    df
  })

  # ── KPIs ───────────────────────────────────────────────────────────────────
  output$kpi_n    <- renderText(format(nrow(fdata()), big.mark = ","))
  output$kpi_km   <- renderText(paste0(format(round(sum(fdata()$km,          na.rm=TRUE)), big.mark=","), " km"))
  output$kpi_eff  <- renderText(paste0(round(mean(fdata()$L_per_100km,       na.rm=TRUE), 2), " L/100km"))
  output$kpi_cost <- renderText(paste0("$", round(mean(fdata()$cost_per_km,  na.rm=TRUE), 3), " /km"))

  # ── Helper: n-labelled factor for octane boxplots ──────────────────────────
  octane_with_n <- function(df) {
    counts <- df %>%
      filter(!is.na(octane_used)) %>%
      count(octane_used) %>%
      mutate(
        oct_chr   = as.character(octane_used),
        oct_label = paste0(oct_chr, " oct  (n=", n, ")")
      )
    # Build ordered label map
    lmap <- setNames(counts$oct_label, counts$oct_chr)
    df %>%
      filter(!is.na(octane_used)) %>%
      mutate(
        oct_chr   = as.character(octane_used),
        oct_label = factor(lmap[oct_chr], levels = unname(lmap))
      )
  }

  # ── Efficiency over time ───────────────────────────────────────────────────
  output$plot_eff_time <- renderPlotly({
    df <- fdata() %>%
      arrange(date) %>%
      mutate(oct_chr = as.character(octane_used))

    validate(need(nrow(df) > 2, "Not enough data for the selected filters."))

    p <- ggplot(df, aes(x = date, y = L_per_100km,
                        colour = oct_chr,
                        text   = paste0(
                          "Date: ",     date, "\n",
                          "Economy: ",  round(L_per_100km, 2), " L/100km\n",
                          "Octane: ",   octane_used, "\n",
                          "Distance: ", km, " km\n",
                          "Station: ",  station
                        ))) +
      geom_point(alpha = 0.65, size = 2.2) +
      geom_smooth(aes(group = 1), method = "loess", span = 0.35,
                  colour = "#333333", se = TRUE, linewidth = 1,
                  fill = "#bbbbbb", alpha = 0.25) +
      scale_colour_manual(values = CB_COLS, name = "Octane",
                          na.value = "grey60") +
      scale_x_date(date_breaks = "1 year", date_labels = "%Y") +
      labs(x = NULL, y = "L / 100 km",
           title = "Fuel Economy Over Time  (lower = better)") +
      theme_minimal(base_size = 13) +
      theme(legend.position = "top", plot.title = element_text(size = 13))

    ggplotly(p, tooltip = "text") %>%
      layout(legend = list(orientation = "h", x = 0, y = 1.12))
  })

  # ── Economy by octane — horizontal boxplot with N ─────────────────────────
  output$plot_eff_octane <- renderPlotly({
    df <- octane_with_n(fdata())
    validate(need(nrow(df) > 0, "No data."))

    # Use coord_flip() — ggplotly handles this orientation far more reliably
    # than native horizontal boxplots (aes(y = factor, x = continuous)).
    # Drop the text aesthetic so plotly shows its own box-statistics tooltip
    # (median, Q1/Q3, fences) which is more informative than per-row values.
    p <- ggplot(df, aes(x = oct_label, y = L_per_100km, fill = oct_chr)) +
      geom_boxplot(alpha = 0.8, outlier.shape = 21, outlier.alpha = 0.6,
                   outlier.size = 1.8) +
      scale_fill_manual(values = CB_COLS, guide = "none", na.value = "grey70") +
      scale_x_discrete(limits = rev) +   # 91 at top, 98 at bottom after flip
      coord_flip() +
      labs(x = NULL, y = "L / 100 km",
           title = "Economy by Fuel Type  (lower = better)") +
      theme_minimal(base_size = 13) +
      theme(plot.title = element_text(size = 13))

    ggplotly(p)
  })

  # ── Cost per km by octane — horizontal boxplot with N ─────────────────────
  output$plot_cost_octane <- renderPlotly({
    df <- octane_with_n(fdata()) %>%
      filter(!is.na(cost_per_km)) %>%
      mutate(cpm = cost_per_km * 100)

    validate(need(nrow(df) > 0, "No data."))

    p <- ggplot(df, aes(x = oct_label, y = cpm, fill = oct_chr)) +
      geom_boxplot(alpha = 0.8, outlier.shape = 21, outlier.alpha = 0.6,
                   outlier.size = 1.8) +
      scale_fill_manual(values = CB_COLS, guide = "none", na.value = "grey70") +
      scale_x_discrete(limits = rev) +
      coord_flip() +
      labs(x = NULL, y = "Cents per km",
           title = "Cost per km by Fuel Type") +
      theme_minimal(base_size = 13) +
      theme(plot.title = element_text(size = 13))

    ggplotly(p)
  })

  # ── Station comparison ─────────────────────────────────────────────────────
  output$plot_station <- renderPlotly({
    df <- fdata() %>%
      filter(!is.na(station)) %>%
      group_by(station) %>%
      summarise(
        avg_eff  = mean(L_per_100km, na.rm = TRUE),
        avg_cost = mean(cost_per_km * 100, na.rm = TRUE),
        n        = n(),
        .groups  = "drop"
      ) %>%
      filter(n >= 3) %>%
      arrange(avg_eff) %>%
      mutate(
        station_label = paste0(station, "  (n=", n, ")")
      )

    validate(need(nrow(df) > 0, "Not enough data (need 3+ fills per station)."))

    p <- ggplot(df, aes(y = reorder(station_label, -avg_eff), x = avg_eff,
                        fill = avg_eff,
                        text = paste0(
                          station, "\n",
                          "Avg economy: ", round(avg_eff, 2), " L/100km\n",
                          "Avg cost: ",    round(avg_cost, 2), " c/km\n",
                          "Fills: ", n
                        ))) +
      geom_col(alpha = 0.85) +
      geom_text(aes(label = round(avg_eff, 2)), hjust = -0.15, size = 3.5) +
      # Viridis is colour-blind safe and has clear directionality
      scale_fill_viridis_c(option = "plasma", direction = -1, guide = "none") +
      scale_x_continuous(expand = expansion(mult = c(0, 0.14))) +
      labs(y = NULL, x = "Avg L / 100 km",
           title = "Average Fuel Economy by Station  (lower = better)") +
      theme_minimal(base_size = 13) +
      theme(plot.title = element_text(size = 13))

    ggplotly(p, tooltip = "text")
  })

  # ── Fuel prices over time ─────────────────────────────────────────────────
  output$plot_prices <- renderPlotly({
    df <- raw_data() %>%
      filter(date >= input$date_range[1], date <= input$date_range[2],
             !is.na(price), !is.na(octane)) %>%
      filter(octane %in% as.integer(input$fuel_types)) %>%
      mutate(oct_chr = factor(as.character(octane),
                              levels = c("91", "94", "95", "98")))

    validate(need(nrow(df) > 2, "Not enough price data for selected period."))

    p <- ggplot(df, aes(x = date, y = price, colour = oct_chr,
                        text = paste0(
                          "Date: ",    date, "\n",
                          "Octane: ",  octane, "\n",
                          "Price: ",   price, " c/L\n",
                          "Station: ", station
                        ))) +
      geom_point(alpha = 0.5, size = 1.8) +
      geom_smooth(aes(group = oct_chr), method = "loess", span = 0.4,
                  se = FALSE, linewidth = 1) +
      scale_colour_manual(values = CB_COLS, name = "Octane",
                          na.value = "grey60") +
      scale_x_date(date_breaks = "1 year", date_labels = "%Y") +
      labs(x = NULL, y = "Price (cents / L)",
           title = "Fuel Prices Over Time") +
      theme_minimal(base_size = 13) +
      theme(legend.position = "top", plot.title = element_text(size = 13))

    ggplotly(p, tooltip = "text") %>%
      layout(legend = list(orientation = "h", x = 0, y = 1.12))
  })

  # ── Highway % vs efficiency scatter ───────────────────────────────────────
  output$plot_hwy <- renderPlotly({
    df <- fdata() %>%
      filter(!is.na(pct_hwy), !is.na(octane_used)) %>%
      mutate(oct_chr = as.character(octane_used))

    validate(need(nrow(df) > 5, "Not enough data."))

    p <- ggplot(df, aes(x = pct_hwy, y = L_per_100km,
                        colour = oct_chr,
                        text   = paste0(
                          "Highway: ", pct_hwy, "%\n",
                          "Economy: ", round(L_per_100km, 2), " L/100km\n",
                          "Octane: ",  octane_used, "\n",
                          "Date: ",    date
                        ))) +
      geom_point(alpha = 0.65, size = 2.2) +
      geom_smooth(aes(group = 1), method = "lm", se = TRUE,
                  colour = "#333333", linewidth = 1,
                  fill = "#bbbbbb", alpha = 0.25) +
      scale_colour_manual(values = CB_COLS, name = "Octane",
                          na.value = "grey60") +
      scale_x_continuous(labels = function(x) paste0(x, "%")) +
      labs(x = "Highway travel (%)", y = "L / 100 km",
           title = "Fuel Economy vs Highway Proportion",
           subtitle = "More highway riding → lower consumption") +
      theme_minimal(base_size = 13) +
      theme(legend.position = "top", plot.title = element_text(size = 13))

    ggplotly(p, tooltip = "text") %>%
      layout(legend = list(orientation = "h", x = 0, y = 1.15))
  })

  # ── Data table ─────────────────────────────────────────────────────────────
  output$tbl_data <- renderDT({
    fdata() %>%
      arrange(desc(date)) %>%
      transmute(
        Date          = as.character(date),
        `Octane used` = as.integer(octane_used),
        `Litres`      = round(refuel_L, 2),
        `Price (c/L)` = as.numeric(price_used),
        `km`          = round(km, 1),
        `% Hwy`       = as.integer(pct_hwy),
        Station       = as.character(station),
        `L/100km`     = round(L_per_100km, 2),
        `c/km`        = round(cost_per_km * 100, 2),
        Notes         = coalesce(as.character(notes), "")
      )
  },
  options = list(pageLength = 20, scrollX = TRUE, dom = "lfrtip"),
  class    = "table table-striped table-hover table-sm",
  rownames = FALSE
  )
}

# ── Launch ────────────────────────────────────────────────────────────────────
shinyApp(ui = ui, server = server)
