# rocker/r2u: multi-arch (amd64 + arm64) R with apt-installable binary packages.
# Classic rocker/shiny would work here too but is amd64-only — won't run on a Pi.
FROM rocker/r2u:24.04

# All packages the app libraries() — as prebuilt binaries, no source compiling.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        r-cran-shiny \
        r-cran-bslib \
        r-cran-googlesheets4 \
        r-cran-dplyr \
        r-cran-ggplot2 \
        r-cran-plotly \
        r-cran-dt \
        r-cran-lubridate \
        curl && \
    rm -rf /var/lib/apt/lists/*

# Mirror the repo layout: app.R resolves ../data/fuel_dat.csv from its own dir,
# so the CSV cache must sit as a SIBLING of the app folder, not inside it.
COPY FZ6_fueleff/ /srv/shiny/FZ6_fueleff/
COPY data/       /srv/shiny/data/

EXPOSE 3838

CMD ["R", "-e", "shiny::runApp('/srv/shiny/FZ6_fueleff', port=3838, host='0.0.0.0', launch.browser=FALSE)"]
